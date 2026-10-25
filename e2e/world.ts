// Builds a venue through the real API on the local stack, the same way people would.
// The only direct SQL is the two runbook steps: registering the platform administrator
// and the scanner service account.

import { randomBytes, randomUUID } from "node:crypto";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import postgres from "postgres";

export const DB_URL = "postgresql://postgres:postgres@127.0.0.1:55622/postgres";

const url = () => process.env.NEXT_PUBLIC_SUPABASE_URL!;
const anon = () => process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

export function adminAuth() {
  return createClient(url(), process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } }).auth.admin;
}

export interface Login { email: string; password: string; userId: string }

/** A confirmed user with a random password (test credentials only). */
export async function makeUser(email: string): Promise<Login> {
  const password = randomBytes(18).toString("base64url");
  const { data, error } = await adminAuth().createUser({ email, password, email_confirm: true });
  if (error) throw new Error(`createUser ${email}: ${error.message}`);
  return { email, password, userId: data.user.id };
}

export async function signIn(login: Login): Promise<SupabaseClient> {
  const db = createClient(url(), anon(), { auth: { persistSession: false }, db: { schema: "api" } });
  const { error } = await db.auth.signInWithPassword({ email: login.email, password: login.password });
  if (error) throw new Error(`signIn ${login.email}: ${error.message}`);
  return db as unknown as SupabaseClient;
}

export const key = () => randomUUID();

export async function must(db: SupabaseClient, fn: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  if (!data?.ok) throw new Error(`${fn} refused: ${JSON.stringify(data)}`);
  return data;
}

export async function version(table: string, id: string): Promise<number> {
  const sql = postgres(DB_URL, { max: 1 });
  try {
    const rows = await sql.unsafe(`select row_version from core.${table} where id = $1`, [id]);
    return rows[0]!.row_version as number;
  } finally {
    await sql.end();
  }
}

export interface Venue {
  tag: string;
  admin1: Login; admin2: Login; ae: Login; scanner: Login;
  customerId: string; venueId: string; ap: string;
  noticeId: string; insTypeId: string; insCriteriaId: string;
}

/** A customer with one venue, its root appointment, privacy notice and insurance rule. */
export async function buildVenue(tag = randomUUID().slice(0, 8)): Promise<Venue> {
  const platform = await makeUser(`platform+${tag}@octra.local`);
  const admin1 = await makeUser(`admin1+${tag}@venue.local`);
  const admin2 = await makeUser(`admin2+${tag}@venue.local`);
  const ae = await makeUser(`ae+${tag}@venue.local`);
  const scanner = await makeUser(`scanner+${tag}@octra.local`);

  const sql = postgres(DB_URL, { max: 1 });
  try {
    await sql`insert into core.platform_admin (auth_user_id) values (${platform.userId})`;
    await sql`insert into core.service_account (auth_user_id, purpose) values (${scanner.userId}, 'malware_scanner')`;
  } finally {
    await sql.end();
  }

  const p = await signIn(platform);
  const customer = await must(p, "create_customer", {
    p_idempotency_key: key(), p_name: `Estate ${tag}`, p_admin_given_name: "Avery",
    p_admin_family_name: "Admin", p_admin_auth_user_id: admin1.userId,
  });
  const customerId = customer.id as string;
  const a1Person = customer.admin_person_id as string;

  const a1 = await signIn(admin1);
  const a2Person = (await must(a1, "create_person", { p_idempotency_key: key(), p_customer_id: customerId, p_given_name: "Blair", p_family_name: "Admin" })).id;
  await must(a1, "link_user_account", { p_idempotency_key: key(), p_person_id: a2Person, p_auth_user_id: admin2.userId });
  await must(a1, "grant_tenant_admin", { p_idempotency_key: key(), p_customer_id: customerId, p_person_id: a2Person });
  const aePerson = (await must(a1, "create_person", { p_idempotency_key: key(), p_customer_id: customerId, p_given_name: "Ash", p_family_name: "Engineer" })).id;
  await must(a1, "link_user_account", { p_idempotency_key: key(), p_person_id: aePerson, p_auth_user_id: ae.userId });
  const duty = (await must(a1, "create_person", { p_idempotency_key: key(), p_customer_id: customerId, p_given_name: "Dale", p_family_name: "Dutyholder" })).id;

  const venue = await must(a1, "create_venue", { p_idempotency_key: key(), p_customer_id: customerId, p_code: "V1", p_name: `Exhibition Centre ${tag}`, p_timezone: "Europe/London" });
  const venueId = venue.id as string;
  const site = venue.root_area_id as string;

  const tRoot = (await must(a1, "create_appointment_type", { p_idempotency_key: key(), p_venue_id: venueId, p_code: "AE", p_name: "Authorising Engineer" })).id;
  const tvRoot = (await must(a1, "publish_appointment_type_version", {
    p_idempotency_key: key(), p_appointment_type_id: tRoot,
    p_allowed_action_codes: ["appointment.grant", "appointment.revoke", "delegation.grant", "engagement.approve",
      "engagement.suspend", "engagement.reinstate", "document.review", "competency.verify",
      "person.restrict", "person.lift_restriction", "organisation.restrict", "organisation.lift_restriction",
      "appointment_type.approve", "appointment_type.reject", "course_version.publish", "course_version.return",
      "course_version.withdraw", "induction.facilitate", "induction.invalidate"],
    p_eligible_permit_class_ids: [], p_eligible_system_type_ids: [], p_grantable_type_ids: [],
    p_is_root_eligible: true, p_requires_competence_evidence: false, p_owner_person_id: a1Person,
    p_effective_from: new Date(Date.now() - 86_400_000).toISOString(), p_change_reason: "Initial set-up",
  })).id;

  const ap = (await must(a1, "record_root_appointment", {
    p_idempotency_key: key(), p_venue_id: venueId, p_appointee_person_id: aePerson, p_duty_holder_person_id: duty,
    p_type_version_id: tvRoot, p_permit_class_ids: [], p_scopes: [{ area_id: site }],
    p_valid_from: new Date(Date.now() - 3_600_000).toISOString(), p_valid_to: null, p_review_due_on: null,
    p_limitations_text: null, p_root_evidence_ref: "Letter of appointment E2E",
  })).id as string;
  const a2 = await signIn(admin2);
  await must(a2, "confirm_root_appointment", { p_idempotency_key: key(), p_appointment_id: ap, p_expected_version: await version("appointment", ap) });
  const aeDb = await signIn(ae);
  await must(aeDb, "acknowledge_appointment", { p_idempotency_key: key(), p_appointment_id: ap, p_expected_version: await version("appointment", ap) });

  const noticeId = (await must(a1, "publish_privacy_notice", {
    p_idempotency_key: key(), p_customer_id: customerId, p_title: "Privacy notice (TEST WORDING)",
    p_content_ref: "privacy-notice/test", p_owner_person_id: a1Person,
    p_effective_from: new Date(Date.now() - 86_400_000).toISOString(), p_change_reason: "Test",
  })).id as string;
  const insTypeId = (await must(a1, "create_document_type", { p_idempotency_key: key(), p_venue_id: venueId, p_code: "INS", p_label: "Public liability insurance", p_owner_level: "organisation" })).id as string;
  const insCriteriaId = (await must(a1, "publish_review_criteria", {
    p_idempotency_key: key(), p_document_type_id: insTypeId,
    p_criteria: [{ code: "readable", label: "Received and readable" }, { code: "current", label: "Current for the stated dates" }, { code: "relevant", label: "Relevant to the stated scope" }],
    p_owner_person_id: a1Person, p_effective_from: new Date(Date.now() - 86_400_000).toISOString(), p_change_reason: "Initial",
  })).id as string;
  const req = (await must(a1, "create_evidence_requirement", {
    p_idempotency_key: key(), p_venue_id: venueId, p_code: "PL", p_label: "Public liability insurance",
    p_applies_to_kind: "engagement_capacity", p_capacity_code: "performing_contractor", p_appointment_type_id: null,
    p_requires_kind: "document_type", p_document_type_id: insTypeId, p_competency_type_id: null,
  })).id;
  await must(a1, "publish_evidence_requirement_version", {
    p_idempotency_key: key(), p_requirement_id: req, p_in_force: true, p_owner_person_id: a1Person,
    p_effective_from: new Date(Date.now() - 60_000).toISOString(), p_change_reason: "Required by the venue",
  });

  return { tag, admin1, admin2, ae, scanner, customerId, venueId, ap, noticeId, insTypeId, insCriteriaId };
}
