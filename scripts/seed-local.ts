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
const { buildVenue, makeUser, signIn, key, must, version, DB_URL } = await import("../e2e/world.ts");
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
const docVersionId = randomUUID();
const doc = await must(cara, "submit_document", {
  p_idempotency_key: key(), p_document_id: randomUUID(), p_version_id: docVersionId, p_owner_kind: "organisation",
  p_organisation_id: accepted.organisation_id, p_person_id: null, p_document_type_id: v.insTypeId,
  p_title: "Public liability certificate 2026-27", p_sha256_hex: createHash("sha256").update(file).digest("hex"),
  p_media_type: "application/pdf", p_size_bytes: file.length, p_issuer: "Demo Insurer plc", p_reference: "PL-0001",
  p_valid_from: null, p_expires_on: new Date(Date.now() + 365 * 86_400_000).toISOString().slice(0, 10),
});
const stored = await createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } })
  .storage.from("documents").upload(doc.storage_path, file, { contentType: "application/pdf" });
if (stored.error) throw new Error(stored.error.message);
// Phase 4: Cara's engagement approved through the real route (her insurance reviewed by
// the AE), areas, the suggested permit classes, work types, and a Technical Authority
// (Tara) appointed through the root ceremony, whose appointment covers those classes.
const { SUGGESTED_CLASSES } = await import("../src/lib/screening/starter.ts");
const ae = await signIn(v.ae);
await must(ae, "review_document", {
  p_idempotency_key: key(), p_version_id: docVersionId, p_criteria_version_id: v.insCriteriaId,
  p_outcome: "reviewed_no_further_comments", p_criteria_results: { readable: true, current: true, relevant: true },
  p_scope_wording: "Public liability cover for electrical work at the venue", p_conditions: null,
});
const db2 = postgres(DB_URL, { max: 1 });
const [eng] = await db2`select id, row_version from core.engagement where organisation_id = ${accepted.organisation_id}`;
const [root] = await db2`select id from core.area where venue_id = ${v.venueId} and parent_id is null`;
const [a1p] = await db2`select person_id from core.user_account where auth_user_id = ${v.admin1.userId}`;
await db2.end();
await must(ae, "approve_engagement", { p_idempotency_key: key(), p_engagement_id: eng!.id, p_expected_version: eng!.row_version });

const hallKind = await must(a1, "create_area_kind", { p_idempotency_key: key(), p_venue_id: v.venueId, p_code: "HALL", p_label: "Hall" });
for (const [code, name] of [["HALL1", "Hall 1"], ["HALL2", "Hall 2"], ["PLANT1", "Plant room 1"]]) {
  await must(a1, "create_area", { p_idempotency_key: key(), p_parent_area_id: root!.id, p_area_kind_id: hallKind.id, p_code: code, p_name: name });
}
const classIds: string[] = [];
const waClass = await must(a1, "create_work_approval_class", { p_idempotency_key: key(), p_venue_id: v.venueId, p_code: "WA", p_name: "Work Approval" });
classIds.push(waClass.id);
const classByCode: Record<string, string> = { WA: waClass.id };
for (const c of SUGGESTED_CLASSES) {
  const fn = c.handling === "external_reference" ? "create_external_class" : "create_permit_class";
  const created = await must(a1, fn, { p_idempotency_key: key(), p_venue_id: v.venueId, p_code: c.code, p_name: c.name });
  classIds.push(created.id);
  classByCode[c.code] = created.id;
}
for (const [code, label] of [["MAINT", "Routine maintenance"], ["SURVEY", "Access or survey"], ["INSPECT", "Inspection"], ["FITOUT", "Fit-out"], ["EVENT", "Event build"]]) {
  await must(a1, "create_work_type", { p_idempotency_key: key(), p_venue_id: v.venueId, p_code: code, p_label: label });
}
const taType = await must(a1, "create_appointment_type", { p_idempotency_key: key(), p_venue_id: v.venueId, p_code: "TA", p_name: "Technical Authority" });
const taVersion = await must(a1, "propose_appointment_type_version", {
  p_idempotency_key: key(), p_appointment_type_id: taType.id,
  p_allowed_action_codes: ["screening_set.approve", "screening_set.reject", "screening.decide", "external_reference.decide",
    "permit_class_version.approve", "permit_class_version.reject", "permit_step.decide", "permit_step.decide_landlord",
    "permit_step.record_external", "work_package.require_class"],
  p_eligible_permit_class_ids: classIds, p_eligible_system_type_ids: [], p_grantable_type_ids: [],
  p_is_root_eligible: true, p_requires_competence_evidence: false, p_owner_person_id: a1p!.person_id,
  p_effective_from: new Date(Date.now() - 60_000).toISOString(), p_change_reason: "Technical authority for activity screening",
});
await must(ae, "decide_appointment_type_version", { p_idempotency_key: key(), p_version_id: taVersion.id,
  p_expected_version: await version("appointment_type_version", taVersion.id), p_decision: "approve", p_reason: "Agreed" });
const taraLogin = await makeUser("tara+demo@venue.local");
const tara = await must(a1, "create_person", { p_idempotency_key: key(), p_customer_id: v.customerId, p_given_name: "Tara", p_family_name: "Authority" });
await must(a1, "link_user_account", { p_idempotency_key: key(), p_person_id: tara.id, p_auth_user_id: taraLogin.userId });
const [duty] = await (async () => { const q = postgres(DB_URL, { max: 1 }); const r = await q`select id from core.person where customer_id = ${v.customerId} and given_name = 'Dale'`; await q.end(); return r; })();
const taAppt = await must(a1, "record_root_appointment", {
  p_idempotency_key: key(), p_venue_id: v.venueId, p_appointee_person_id: tara.id, p_duty_holder_person_id: duty!.id,
  p_type_version_id: taVersion.id, p_permit_class_ids: classIds, p_scopes: [{ area_id: root!.id }],
  p_valid_from: new Date(Date.now() - 60_000).toISOString(), p_valid_to: null, p_review_due_on: null,
  p_limitations_text: null, p_root_evidence_ref: "Letter of appointment TA-DEMO",
});
await must(await signIn(v.admin2), "confirm_root_appointment", { p_idempotency_key: key(), p_appointment_id: taAppt.id,
  p_expected_version: await version("appointment", taAppt.id) });
await must(await signIn(taraLogin), "acknowledge_appointment", { p_idempotency_key: key(), p_appointment_id: taAppt.id,
  p_expected_version: await version("appointment", taAppt.id) });

// Phase 5: a permit issuer (Ian), separate from the reviewer (four-eyes, P5-10), a working
// calendar, and permit class configurations. DEMO CONTENT FOR LOCAL TESTING ONLY: the
// routes, declarations and notice are not validated by any technical authority.
const isType = await must(a1, "create_appointment_type", { p_idempotency_key: key(), p_venue_id: v.venueId, p_code: "IS", p_name: "Permit Issuer" });
const isVersion = await must(a1, "propose_appointment_type_version", {
  p_idempotency_key: key(), p_appointment_type_id: isType.id, p_allowed_action_codes: ["permit.issue", "permit.exception_decide",
    // Phase 6a live control.
    "permit.stop_as_authority", "permit.lift_suspension", "permit.extend", "permit.approve_worker",
    "permit.exclude_worker_as_authority", "permit.change_supervisor"],
  p_eligible_permit_class_ids: classIds, p_eligible_system_type_ids: [], p_grantable_type_ids: [],
  p_is_root_eligible: true, p_requires_competence_evidence: false, p_owner_person_id: a1p!.person_id,
  p_effective_from: new Date(Date.now() - 60_000).toISOString(), p_change_reason: "Permit issue",
});
await must(ae, "decide_appointment_type_version", { p_idempotency_key: key(), p_version_id: isVersion.id,
  p_expected_version: await version("appointment_type_version", isVersion.id), p_decision: "approve", p_reason: "Agreed" });
const ianLogin = await makeUser("ian+demo@venue.local");
const ian = await must(a1, "create_person", { p_idempotency_key: key(), p_customer_id: v.customerId, p_given_name: "Ian", p_family_name: "Issuer" });
await must(a1, "link_user_account", { p_idempotency_key: key(), p_person_id: ian.id, p_auth_user_id: ianLogin.userId });
const ianAppt = await must(a1, "record_root_appointment", {
  p_idempotency_key: key(), p_venue_id: v.venueId, p_appointee_person_id: ian.id, p_duty_holder_person_id: duty!.id,
  p_type_version_id: isVersion.id, p_permit_class_ids: classIds, p_scopes: [{ area_id: root!.id }],
  p_valid_from: new Date(Date.now() - 60_000).toISOString(), p_valid_to: null, p_review_due_on: null,
  p_limitations_text: null, p_root_evidence_ref: "Letter of appointment IS-DEMO",
});
await must(await signIn(v.admin2), "confirm_root_appointment", { p_idempotency_key: key(), p_appointment_id: ianAppt.id,
  p_expected_version: await version("appointment", ianAppt.id) });
await must(await signIn(ianLogin), "acknowledge_appointment", { p_idempotency_key: key(), p_appointment_id: ianAppt.id,
  p_expected_version: await version("appointment", ianAppt.id) });

await must(a1, "publish_venue_calendar", { p_idempotency_key: key(), p_venue_id: v.venueId, p_working_weekdays: [1, 2, 3, 4, 5],
  p_closures: [], p_cutoff_time: "16:00", p_effective_from: new Date(Date.now() - 86_400_000).toISOString(),
  p_change_reason: "Demo calendar for local testing" });
const demoConfig = (route: unknown[], notice: number, controls: boolean, questions: unknown[] = []) => ({
  questions, route,
  submission_declaration: ["The information in this request is accurate and complete.", "We will tell the venue before anything in it changes."],
  acceptance_declaration: ["I have briefed the team on the scope, limits and conditions of this permit.", "I will stop the work if conditions change."],
  requires_physical_controls: controls, override_prohibited: false,
  notice: { amount: notice, unit: "working_days", cutoff_applies: true, restart_on_resubmission: false },
  evidence: { induction_course_ids: [], team_competency_type_ids: [], supervisor_competency_type_ids: [] },
  // Demo live rules only: the venue must choose its own (P6-5 to P6-7).
  extension: { max_count: 1, max_total_hours: 4 }, worker_add: "issuer_approval", revalidation: { mode: "none" },
});
const tara2 = await signIn(taraLogin);
// The starter screening set (P4-2), approved for local testing only.
const { starterFor, STARTER_SOURCE } = await import("../src/lib/screening/starter.ts");
const screening = await must(a1, "create_screening_draft", { p_idempotency_key: key(), p_venue_id: v.venueId });
const { data: venueClasses } = await a1.from("permit_class").select("id, code, handling, retired_at").eq("venue_id", v.venueId);
await must(a1, "save_screening_draft", { p_idempotency_key: key(), p_version_id: screening.id,
  p_expected_version: await version("screening_set_version", screening.id), p_content: starterFor(venueClasses ?? []).content,
  p_source_ref: `${STARTER_SOURCE}. DEMO APPROVAL for local testing only` });
await must(a1, "propose_screening_version", { p_idempotency_key: key(), p_version_id: screening.id,
  p_expected_version: await version("screening_set_version", screening.id) });
await must(tara2, "decide_screening_version", { p_idempotency_key: key(), p_version_id: screening.id,
  p_expected_version: await version("screening_set_version", screening.id), p_decision: "approve", p_reason: "Demo approval for local testing" });
const configs: Array<[string, unknown]> = [
  ["WA", demoConfig([{ key: "venue-review", name: "Venue review of the job", kind: "review", group: 1 }], 0, false)],
  ["WAH", demoConfig([{ key: "method", name: "Method and access review", kind: "review", group: 1 },
                      { key: "final", name: "Final review", kind: "review", group: 2 }], 1, false,
                     [{ key: "access", text: "How will people reach the work?", type: "choose_one",
                        options: [{ key: "mewp", text: "Mobile elevating work platform" }, { key: "tower", text: "Mobile tower" }] }])],
  ["HW", demoConfig([{ key: "hot-review", name: "Hot works review", kind: "review", group: 1 }], 2, true)],
  ["ISO", demoConfig([{ key: "iso-review", name: "Isolation review", kind: "review", group: 1 }], 2, true)],
  ["LSI", demoConfig([{ key: "lsi-review", name: "Impairment review", kind: "review", group: 1 }], 2, true)],
];
for (const [code, content] of configs) {
  const draftVersion = await must(a1, "create_class_draft", { p_idempotency_key: key(), p_permit_class_id: classByCode[code] });
  await must(a1, "save_class_draft", { p_idempotency_key: key(), p_version_id: draftVersion.id,
    p_expected_version: await version("permit_class_version", draftVersion.id), p_content: content,
    p_source_ref: "DEMO CONTENT for local testing only: not validated by a technical authority" });
  await must(a1, "propose_class_version", { p_idempotency_key: key(), p_version_id: draftVersion.id,
    p_expected_version: await version("permit_class_version", draftVersion.id) });
  await must(tara2, "decide_class_version", { p_idempotency_key: key(), p_version_id: draftVersion.id,
    p_expected_version: await version("permit_class_version", draftVersion.id), p_decision: "approve",
    p_reason: "Demo approval for local testing" });
}

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
  technical_authority: "tara+demo@venue.local",
  permit_issuer: "ian+demo@venue.local",
  scanner_env: ".env.scanner.local",
}, null, 2));
