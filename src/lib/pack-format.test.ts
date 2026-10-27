import { readFileSync } from "node:fs";
import { unzipSync } from "fflate";
import { PDFDocument } from "pdf-lib";
import { describe, expect, it } from "vitest";
import { assemblePack, type PackContent, readable, renderPackPdf, sha256Hex } from "./pack-format";

const font = new Uint8Array(readFileSync("node_modules/next/dist/compiled/@vercel/og/Geist-Regular.ttf"));
const IVY = "11111111-1111-4111-8111-111111111111";
const APPT = "22222222-2222-4222-8222-222222222222";

function content(): PackContent {
  return {
    format: "octra-permit-pack/1", export_id: "33333333-3333-4333-8333-333333333333", reference: "PK-J-0001-01",
    venue: { id: "v", name: "Exhibition Centre", timezone: "Europe/London" },
    made_at: "2026-10-27T10:00:00+00:00", made_by: { person_id: IVY, capacity: "Evidence Officer" },
    purpose: "Claim", recipient: "Acme Insurance", profile: "external",
    statement: "This pack reproduces records frozen in Octra.", profile_rules: ["Telephone numbers are removed."], never_removed: "Who decided.",
    omissions: [{ item: "answers:x", what: "Answers to the Work Approval questions", reason: "Not relevant" }],
    redactions: { fields: 0, email_addresses: 1, phone_numbers: 1 },
    job: { reference: "J-0001", title: "Lamps over the aisle — Zoë’s crew", scope: "Replace lamps", areas: [{ id: "a", name: "Hall 1" }] },
    permits: [{
      id: "p", class: "Work Approval", kind: "work_approval", state_when_made: "closed", closed: true,
      issue_snapshots: [{ id: "s", issued_at: "2026-10-26T09:00:00Z", sha256: "a".repeat(64), content: {
        version: { no: 1, answers: "[Omitted by the exporter: Not relevant]", window_from: "2026-10-26T08:00:00Z", window_to: "2026-10-27T08:00:00Z",
                   declared_by: IVY, documents: [] },
        class_version: { no: 2, sha256: "b".repeat(64) },
        steps: [{ key: "r", name: "Venue review", kind: "review", decision: { outcome: "no_further_comments", reason: "Fine", scope_wording: "As stated",
                                                                             decider: IVY, at: "2026-10-26T08:30:00Z", conditions: [] } }],
        team: [{ person_id: IVY, name: "Ivy Authority", role: "supervisor" }],
        issuer: { person_id: IVY, appointment_id: APPT, delegation_id: null }, issued_at: "2026-10-26T09:00:00Z" } }],
      close_out: { id: "c", at: "2026-10-26T17:00:00Z", sha256: "c".repeat(64), content: { hand_backs: [{ area_state: "Swept, call [phone number removed]" }] } },
    }],
    not_issued: [], files: [], corrections: [], contacts: null,
    chronology: Array.from({ length: 120 }, (_, i) => ({ at: "2026-10-26T09:00:00Z", action: "permit.issue", what: "Issue a permit (Q98)", who: "Ivy Authority",
      capacity: "Permit Issuer", reason: i % 2 ? "漢字 reason" : null, changes: [{ record: "permit", from: "approved_for_issue", to: "issued_awaiting_acceptance" }],
      seq: i + 1, hash: "d".repeat(64) })),
    verification: { checked_at: "2026-10-27T10:00:00Z", events_in_chain: 500, events_in_pack: 120, problems: [] },
    names: { people: { [IVY]: "Ivy Authority" }, appointments: { [APPT]: { type: "Permit Issuer", holder: "Ivy Authority" } }, areas: {}, organisations: {}, permits: {} },
  };
}

describe("permit pack format", () => {
  it("names identifiers from the pack's dictionaries and reads times in venue time", () => {
    const c = content();
    expect(readable(IVY, c)).toBe("Ivy Authority");
    expect(readable(APPT, c)).toBe("Permit Issuer (Ivy Authority)");
    expect(readable("2026-07-01T09:00:00Z", c)).toContain("10:00");
    expect(readable("closed", c)).toBe("Closed");
    expect(readable("99999999-9999-4999-8999-999999999999", c)).toBe("record 99999999");
  });

  it("renders a readable, multi-page PDF, even with characters the font lacks", async () => {
    const pdf = await renderPackPdf(content(), "e".repeat(64), font);
    expect(new TextDecoder().decode(pdf.slice(0, 5))).toBe("%PDF-");
    const doc = await PDFDocument.load(pdf);
    expect(doc.getPageCount()).toBeGreaterThan(4);
    expect(doc.getTitle()).toBe("Permit pack PK-J-0001-01");
  });

  it("packs the content exactly as hashed, with a manifest of every file's SHA-256", async () => {
    const c = content();
    const text = JSON.stringify(c);
    const sha = sha256Hex(new TextEncoder().encode(text));
    const pdf = await renderPackPdf(c, sha, font);
    const evidence = [{ name: "evidence/01-insurance.pdf", bytes: new Uint8Array([37, 80, 68, 70, 1, 2, 3]) }];
    const built = assemblePack(c.reference, text, sha, pdf, evidence, new Date(c.made_at));
    const files = unzipSync(built.zip);
    expect(Object.keys(files).sort()).toEqual(["evidence/01-insurance.pdf", "manifest.json", "pack.json", "pack.pdf"]);
    expect(new TextDecoder().decode(files["pack.json"])).toBe(text);
    expect(sha256Hex(files["pack.json"]!)).toBe(sha);
    const manifest = JSON.parse(new TextDecoder().decode(files["manifest.json"])) as { content_sha256: string; files: Array<{ name: string; sha256: string }> };
    expect(manifest.content_sha256).toBe(sha);
    for (const f of manifest.files) expect(sha256Hex(files[f.name]!)).toBe(f.sha256);
    expect(built.files.map((f) => f.name)).toContain("manifest.json");
    expect(built.sha256).toBe(sha256Hex(built.zip));
  });
});
