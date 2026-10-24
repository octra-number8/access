// Pilot workflow 1, first half (Q231): a venue invites a contractor, the contractor
// accepts, submits insurance, the venue reviews it, and the engagement is approved once
// its evidence is in place.
//
// Malware scanning is held off (D-014): the main journey runs that way. The scanner
// journey (D-013) stays covered and runs with E2E_SCANNER=1, which needs local clamd
// (services/scanner: docker compose up -d clamd) and the scanner built.

import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { openSync } from "node:fs";
import postgres from "postgres";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { loadLocalEnv } from "./env";

loadLocalEnv();
const { buildVenue, makeUser, signIn, key, must, version, DB_URL } = await import("./world");
const { uploadDocument, downloadLink } = await import("@/lib/documents");
const { documentsBucket } = await import("@/lib/supabase/storage");
const { sendMail } = await import("@/lib/mail");

const sql = postgres(DB_URL, { max: 2 });
const pdf = (label: string) => Buffer.from(`%PDF-1.7\n% ${label}\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n`);
const sha = (b: Buffer) => createHash("sha256").update(b).digest("hex");

let venue: Awaited<ReturnType<typeof buildVenue>>;
let scanner: ChildProcess | null = null;
const state: Record<string, string> = {};
const cara = () => signIn({ email: state.caraEmail!, password: state.caraPassword!, userId: state.caraUser! });

beforeAll(async () => {
  venue = await buildVenue();
});

afterAll(async () => {
  scanner?.kill("SIGTERM");
  await sql.end();
});

describe("contractor onboarding, end to end (scanning held off, D-014)", () => {
  it("the venue invites an organisation and the invitation email is delivered", async () => {
    const a1 = await signIn(venue.admin1);
    const [me] = await sql`select person_id from core.user_account where auth_user_id = ${venue.admin1.userId}`;
    state.caraEmail = `cara+${venue.tag}@contractor.local`;
    const inv = await must(a1, "create_organisation_invitation", {
      p_idempotency_key: key(), p_venue_id: venue.venueId, p_capacity_code: "performing_contractor",
      p_invitee_given_name: "Cara", p_invitee_family_name: "Contractor", p_invitee_email: state.caraEmail,
      p_owner_person_id: me!.person_id, p_expires_at: new Date(Date.now() + 7 * 86_400_000).toISOString(),
      p_engagement_valid_from: new Date().toISOString(),
      p_engagement_valid_to: new Date(Date.now() + 90 * 86_400_000).toISOString(),
    });
    state.token = inv.token as string;

    const sent = await sendMail(state.caraEmail, "You have been invited", `Accept: http://localhost:3000/invitations/${state.token}`);
    expect(sent.ok).toBe(true);
    const search = await fetch(`http://127.0.0.1:55624/api/v1/search?query=${encodeURIComponent(`to:"${state.caraEmail}"`)}`);
    expect(((await search.json()) as { messages: unknown[] }).messages.length).toBeGreaterThan(0);
  });

  it("the contractor accepts against the privacy notice and gets a proposed engagement", async () => {
    const login = await makeUser(state.caraEmail!);
    state.caraUser = login.userId;
    state.caraPassword = login.password;
    const db = await signIn(login);
    const preview = await must(db, "invitation_preview", { p_token: state.token });
    expect(preview.privacy_notice.id).toBe(venue.noticeId);
    const accepted = await must(db, "accept_invitation", {
      p_idempotency_key: key(), p_token: state.token, p_privacy_notice_version_id: venue.noticeId,
      p_legal_name: "Cara Electrical Ltd", p_trading_name: null, p_company_number: null,
      p_given_name: "Cara", p_family_name: "Contractor", p_relationship_kind: "employee",
    });
    state.orgId = accepted.organisation_id;
    state.engagementId = accepted.engagement_id;
    const [e] = await sql`select status from core.engagement where id = ${state.engagementId!}`;
    expect(e!.status).toBe("proposed");
  });

  it("an upload is stored, recorded as not scanned, and released at once as an attachment link", async () => {
    const db = await cara();
    const r = await uploadDocument(db as never, {
      bytes: pdf("certificate"), ownerKind: "organisation", organisationId: state.orgId!, personId: null,
      documentTypeId: venue.insTypeId, title: "Public liability certificate",
      expiresOn: new Date(Date.now() + 365 * 86_400_000).toISOString().slice(0, 10), idempotencyKey: key(),
    });
    expect(r).toMatchObject({ ok: true, scan_status: "not_scanned" });
    state.goodVersion = (r as { id: string }).id;

    const link = await downloadLink(db as never, state.goodVersion);
    expect(link.ok).toBe(true);
    const body = Buffer.from(await (await fetch((link as { url: string }).url)).arrayBuffer());
    expect(sha(body)).toBe(sha(pdf("certificate")));
    const [a] = await sql`select count(*)::int as n from audit.audit_event where action = 'document.accessed' and target_id = ${state.goodVersion!}`;
    expect(a!.n).toBe(1);

    const disguised = await uploadDocument(db as never, {
      bytes: Buffer.from("GIF89a not really a pdf"), ownerKind: "organisation", organisationId: state.orgId!,
      personId: null, documentTypeId: venue.insTypeId, title: "Wrong type", idempotencyKey: key(),
    });
    expect(disguised).toMatchObject({ ok: false, code: "file_type" });
  });

  it("the engagement cannot be approved until the insurance is reviewed, then it can", async () => {
    const ae = await signIn(venue.ae);
    const blocked = (await ae.rpc("approve_engagement", {
      p_idempotency_key: key(), p_engagement_id: state.engagementId,
      p_expected_version: await version("engagement", state.engagementId!),
    })).data;
    expect(blocked).toMatchObject({ ok: false, code: "evidence_incomplete" });
    expect(blocked.evidence[0].state).toBe("not_reviewed");

    await must(ae, "review_document", {
      p_idempotency_key: key(), p_version_id: state.goodVersion, p_criteria_version_id: venue.insCriteriaId,
      p_outcome: "reviewed_no_further_comments", p_criteria_results: { readable: true, current: true, relevant: true },
      p_scope_wording: "Public liability cover for electrical installation work at the venue", p_conditions: null,
    });
    await must(ae, "approve_engagement", {
      p_idempotency_key: key(), p_engagement_id: state.engagementId,
      p_expected_version: await version("engagement", state.engagementId!),
    });
    const [e] = await sql`select status from core.engagement where id = ${state.engagementId!}`;
    expect(e!.status).toBe("active");
  });
});

describe.skipIf(!process.env.E2E_SCANNER)("malware scanning required (D-013, dormant)", () => {
  beforeAll(async () => {
    await sql`insert into core.platform_setting (key, value, decision_ref) values ('malware_scanning', 'required', 'e2e: scanner path')`;
  });
  afterAll(async () => {
    await sql`insert into core.platform_setting (key, value, decision_ref) values ('malware_scanning', 'off', 'e2e: restore D-014')`;
  });

  async function waitForScan(versionId: string): Promise<string> {
    for (let i = 0; i < 120; i++) {
      const [row] = await sql`select scan_status from core.document_version where id = ${versionId}`;
      if (row && row.scan_status !== "pending") return row.scan_status as string;
      await new Promise((r) => setTimeout(r, 500));
    }
    throw new Error(`version ${versionId} was not scanned in time`);
  }

  it("nothing is released until the real scanner has checked it; a tampered file is rejected", async () => {
    const db = await cara();
    const tampered = await uploadDocument(db as never, {
      bytes: pdf("original"), ownerKind: "organisation", organisationId: state.orgId!, personId: null,
      documentTypeId: venue.insTypeId, title: "Insurance (to be tampered with)", idempotencyKey: key(),
    });
    expect(tampered).toMatchObject({ ok: true, scan_status: "pending" });
    await documentsBucket().update(String((tampered as unknown as { storage_path: string }).storage_path), pdf("swapped"),
      { contentType: "application/pdf" });
    const good = await uploadDocument(db as never, {
      bytes: pdf("renewal"), ownerKind: "organisation", organisationId: state.orgId!, personId: null,
      documentTypeId: venue.insTypeId, title: "Renewed certificate", idempotencyKey: key(),
    });
    const goodId = (good as { id: string }).id;
    expect(await downloadLink(db as never, goodId)).toMatchObject({ ok: false, code: "scan_pending" });

    scanner = spawn("node", ["services/scanner/dist/main.js"], {
      env: {
        ...process.env,
        SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL, SUPABASE_ANON_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
        SCANNER_EMAIL: venue.scanner.email, SCANNER_PASSWORD: venue.scanner.password,
        CLAMD_HOST: "127.0.0.1", CLAMD_PORT: "55310", POLL_MS: "300", HEARTBEAT_MS: "1000",
      },
      // The scanner log (version ids and outcomes only) is kept for diagnosis.
      stdio: ["ignore", openSync("e2e/.scanner.log", "w"), "inherit"],
    });
    expect(await waitForScan(goodId)).toBe("clean");
    const tamperedId = (tampered as { id: string }).id;
    expect(await waitForScan(tamperedId)).toBe("rejected");
    const [t] = await sql`select scan_detail from core.document_version where id = ${tamperedId}`;
    // Caught by size or hash, whichever differs first: either way it is not what was registered.
    expect(t!.scan_detail).toMatch(/does not match/);
    expect(await downloadLink(db as never, goodId)).toMatchObject({ ok: true });
    expect(await downloadLink(db as never, tamperedId)).toMatchObject({ ok: false, code: "rejected" });
  });
});
