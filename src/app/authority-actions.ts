"use server";

// People and authority (S1a, D-026): staff logins, tenant administrators, root appointments,
// acknowledgement, appointments and delegations. Each action calls one database function as the
// signed-in user; the database decides (D-003). Forms only collect what the function needs.

import type { ActionResult } from "@/components/ActionForm";
import { failure, optional, run, text } from "@/lib/action-helpers";
import { scopesFrom } from "@/lib/authority";
import { write } from "@/lib/authz";
import { serverEnv } from "@/lib/env";
import { sendMail } from "@/lib/mail";
import { fromVenueLocal } from "@/lib/permits";
import { supabaseServer } from "@/lib/supabase/server";
import { revalidatePath } from "next/cache";

const key = (f: FormData) => text(f, "key");
const version = (f: FormData) => Number(text(f, "row_version"));
const at = (f: FormData, name: string) => { const v = text(f, name); return v ? fromVenueLocal(v, text(f, "tz")) : null; };
const ids = (f: FormData, name: string) => f.getAll(name).map(String).filter(Boolean);
const backwards = (from: string, to: string | null): ActionResult =>
  to && to <= from ? { ok: false, code: "dates", reason: "The end must be after the start.", missing: "An end after the start", resolvable_by: "You" } : null;

// People and logins -------------------------------------------------------------------------
export async function createPerson(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_person", { p_idempotency_key: key(f), p_customer_id: text(f, "customer_id"),
    p_given_name: text(f, "given_name"), p_family_name: text(f, "family_name") }, "Person added");
}

export async function inviteStaff(_: ActionResult, f: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const r = await write(db, "create_staff_invitation", { p_idempotency_key: key(f), p_person_id: text(f, "person_id"),
      p_invitee_email: text(f, "email"), p_expires_at: new Date(Date.now() + 14 * 86_400_000).toISOString() });
    if (!r.ok) return r as ActionResult;
    revalidatePath("/", "layout");
    if (r.replayed) return { ok: true, message: "This invitation was already sent." };
    const to = String(r.email);
    const sent = await sendMail(to, "You have been invited to sign in to Octra Access",
      `You have been invited to sign in to Octra Access as a member of the venue's staff.\n\nOpen this link to accept:\n${serverEnv().siteUrl}/invitations/${r.token}\n\nSigning in gives you no authority by itself: what you can do comes only from appointments made to you.\n\nIf you were not expecting it, ignore this email.`);
    return sent.ok
      ? { ok: true, message: `Invitation emailed to ${to}.` }
      : { ok: false, code: "delivery_failed", reason: `The invitation was created but the email could not be sent: ${sent.error}`,
          missing: "A delivered email", resolvable_by: "You: cancel it and invite again, or contact Octra support" };
  } catch (e) {
    return failure(e);
  }
}

export async function cancelStaffInvitation(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("cancel_invitation", { p_idempotency_key: key(f), p_invitation_id: text(f, "invitation_id"),
    p_expected_version: version(f) }, "Invitation cancelled");
}

export async function disableLogin(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("disable_user_account", { p_idempotency_key: key(f), p_person_id: text(f, "person_id") }, "Login disabled");
}

// Tenant administrators ------------------------------------------------------------------------
export async function grantTenantAdmin(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("grant_tenant_admin", { p_idempotency_key: key(f), p_customer_id: text(f, "customer_id"),
    p_person_id: text(f, "person_id") }, "Tenant administrator added");
}

export async function revokeTenantAdmin(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("revoke_tenant_admin", { p_idempotency_key: key(f), p_tenant_admin_id: text(f, "tenant_admin_id"),
    p_expected_version: version(f), p_reason: text(f, "reason") }, "Administration ended");
}

// Root appointments (D-002) --------------------------------------------------------------------
export async function recordRoot(_: ActionResult, f: FormData): Promise<ActionResult> {
  const from = at(f, "valid_from");
  if (!from) return { ok: false, code: "missing", reason: "Say when the appointment starts.", missing: "A start date and time", resolvable_by: "You" };
  const bad = backwards(from, at(f, "valid_to"));
  if (bad) return bad;
  return run("record_root_appointment", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"),
    p_appointee_person_id: text(f, "appointee"), p_duty_holder_person_id: text(f, "duty_holder"),
    p_type_version_id: text(f, "type_version_id"), p_permit_class_ids: ids(f, "class"), p_scopes: scopesFrom(f),
    p_valid_from: from, p_valid_to: at(f, "valid_to"), p_review_due_on: optional(f, "review_due_on"),
    p_limitations_text: optional(f, "limitations"), p_root_evidence_ref: text(f, "letter"),
    p_competence_evidence_ref: optional(f, "competence") }, "Root appointment recorded; a second tenant administrator must now confirm it");
}

export async function confirmRoot(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("confirm_root_appointment", { p_idempotency_key: key(f), p_appointment_id: text(f, "appointment_id"),
    p_expected_version: version(f) }, "Confirmed; the appointee must now acknowledge it");
}

export async function revokeRoot(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("revoke_root_appointment", { p_idempotency_key: key(f), p_appointment_id: text(f, "appointment_id"),
    p_expected_version: version(f), p_reason: text(f, "reason"), p_evidence_ref: text(f, "evidence") }, "Root appointment revoked");
}

// Appointments ---------------------------------------------------------------------------------
export async function acknowledgeAppointment(_: ActionResult, f: FormData): Promise<ActionResult> {
  if (f.get("declaration") !== "on") {
    return { ok: false, code: "declaration", reason: "Confirm the declaration to acknowledge this appointment.",
             missing: "Your confirmation", resolvable_by: "You" };
  }
  return run("acknowledge_appointment", { p_idempotency_key: key(f), p_appointment_id: text(f, "appointment_id"),
    p_expected_version: version(f) }, "Appointment acknowledged");
}

export async function grantAppointment(_: ActionResult, f: FormData): Promise<ActionResult> {
  const from = at(f, "valid_from"); const to = at(f, "valid_to");
  // S1-6: appointments made on screen have an end date; the database allows open-ended ones only for roots.
  if (!from || !to) return { ok: false, code: "missing", reason: "An appointment made here needs a start and an end (S1-6).",
                             missing: "Both dates", resolvable_by: "You" };
  const bad = backwards(from, to);
  if (bad) return bad;
  return run("grant_appointment", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"),
    p_appointee_person_id: text(f, "appointee"), p_type_version_id: text(f, "type_version_id"),
    p_permit_class_ids: ids(f, "class"), p_scopes: scopesFrom(f), p_valid_from: from, p_valid_to: to,
    p_review_due_on: optional(f, "review_due_on"), p_limitations_text: optional(f, "limitations"),
    p_competence_evidence_ref: optional(f, "competence"), p_acting_appointment_id: text(f, "acting_appointment_id") },
    "Appointment made; the appointee must now acknowledge it");
}

export async function revokeAppointment(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("revoke_appointment", { p_idempotency_key: key(f), p_appointment_id: text(f, "appointment_id"),
    p_expected_version: version(f), p_reason: text(f, "reason") }, "Appointment revoked");
}

// Delegations (invariant 7) --------------------------------------------------------------------
export async function grantDelegation(_: ActionResult, f: FormData): Promise<ActionResult> {
  const from = at(f, "valid_from"); const to = at(f, "valid_to");
  if (!from || !to) return { ok: false, code: "missing", reason: "A delegation needs a start and an end.", missing: "Both dates", resolvable_by: "You" };
  const bad = backwards(from, to);
  if (bad) return bad;
  const mine = JSON.parse(text(f, "my_scope") || "[]") as Array<Record<string, unknown>>;
  const scopes = ids(f, "scope").map((i) => mine[Number(i)]).filter(Boolean);
  return run("grant_delegation", { p_idempotency_key: key(f), p_delegator_appointment_id: text(f, "appointment_id"),
    p_delegate_appointment_id: text(f, "delegate_appointment_id"), p_action_codes: ids(f, "action"),
    p_permit_class_ids: ids(f, "class"), p_scopes: scopes, p_valid_from: from, p_valid_to: to, p_reason: text(f, "reason") },
    "Delegation made");
}

export async function revokeDelegation(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("revoke_delegation", { p_idempotency_key: key(f), p_delegation_id: text(f, "delegation_id"),
    p_expected_version: version(f), p_reason: text(f, "reason") }, "Delegation withdrawn");
}
