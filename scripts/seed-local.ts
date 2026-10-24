// Seeds the local stack with one venue for trying the app by hand:
//   npx supabase db reset && scripts/local-env.sh && node scripts/seed-local.ts
// Sign in with the printed addresses; codes arrive in Mailpit (http://127.0.0.1:55624).
// The scanner's test credentials are written to .env.scanner.local (git-ignored).
import { createHash, randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";
import postgres from "postgres";
import { loadLocalEnv } from "../e2e/env.ts";

loadLocalEnv();
const { buildVenue, makeUser, signIn, key, must, DB_URL } = await import("../e2e/world.ts");
const v = await buildVenue("demo");

// A contractor onboarded through the real API, with one uploaded document.
const sql = postgres(DB_URL, { max: 1 });
const [me] = await sql`select person_id from core.user_account where auth_user_id = ${v.admin1.userId}`;
await sql.end();
const a1 = await signIn(v.admin1);
const invite = await must(a1, "create_organisation_invitation", {
  p_idempotency_key: key(), p_venue_id: v.venueId, p_capacity_code: "performing_contractor",
  p_invitee_given_name: "Cara", p_invitee_family_name: "Contractor", p_invitee_email: "cara+demo@contractor.local",
  p_owner_person_id: me!.person_id, p_expires_at: new Date(Date.now() + 7 * 86_400_000).toISOString(),
  p_engagement_valid_from: new Date().toISOString(), p_engagement_valid_to: new Date(Date.now() + 90 * 86_400_000).toISOString(),
});
const cara = await signIn(await makeUser("cara+demo@contractor.local"));
const accepted = await must(cara, "accept_invitation", {
  p_idempotency_key: key(), p_token: invite.token, p_privacy_notice_version_id: v.noticeId,
  p_legal_name: "Cara Electrical Ltd", p_trading_name: null, p_company_number: null,
  p_given_name: "Cara", p_family_name: "Contractor", p_relationship_kind: "employee",
});
const file = Buffer.from("%PDF-1.7\n% Demo public liability certificate\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n");
const doc = await must(cara, "submit_document", {
  p_idempotency_key: key(), p_document_id: randomUUID(), p_version_id: randomUUID(), p_owner_kind: "organisation",
  p_organisation_id: accepted.organisation_id, p_person_id: null, p_document_type_id: v.insTypeId,
  p_title: "Public liability certificate 2026-27", p_sha256_hex: createHash("sha256").update(file).digest("hex"),
  p_media_type: "application/pdf", p_size_bytes: file.length, p_issuer: "Demo Insurer plc", p_reference: "PL-0001",
  p_valid_from: null, p_expires_on: new Date(Date.now() + 365 * 86_400_000).toISOString().slice(0, 10),
});
const stored = await createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } })
  .storage.from("documents").upload(doc.storage_path, file, { contentType: "application/pdf" });
if (stored.error) throw new Error(stored.error.message);
writeFileSync(
  new URL("../.env.scanner.local", import.meta.url),
  [`SUPABASE_URL=${process.env.NEXT_PUBLIC_SUPABASE_URL}`, `SUPABASE_ANON_KEY=${process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY}`,
   `SCANNER_EMAIL=${v.scanner.email}`, `SCANNER_PASSWORD=${v.scanner.password}`, "CLAMD_PORT=55310", ""].join("\n"),
);
console.log(JSON.stringify({
  venue: `Exhibition Centre ${v.tag}`,
  venue_admin: v.admin1.email,
  second_admin: v.admin2.email,
  authorising_engineer: v.ae.email,
  contractor_admin: "cara+demo@contractor.local",
  scanner_env: ".env.scanner.local",
}, null, 2));
