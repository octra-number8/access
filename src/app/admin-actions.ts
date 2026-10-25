"use server";

// Server actions for the phase 2 records (E3): administrators, relationships,
// competencies, restrictions, appointment types and invitations. Each calls one
// database function as the signed-in user; the database decides (D-003).

import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/components/ActionForm";
import { failure, optional, run, text } from "@/lib/action-helpers";
import { write } from "@/lib/authz";
import { supabaseServer } from "@/lib/supabase/server";

const key = (f: FormData) => text(f, "key");
const version = (f: FormData) => Number(text(f, "row_version"));

// ---- Organisation administrators (Q28) ------------------------------------------------

export async function appointDeputy(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("appoint_deputy_admin", { p_idempotency_key: key(f), p_organisation_id: text(f, "organisation_id"),
    p_person_id: text(f, "person_id") }, "Deputy administrator named");
}

export async function revokeDeputy(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("revoke_deputy_admin", { p_idempotency_key: key(f), p_organisation_id: text(f, "organisation_id") },
    "Deputy administrator removed");
}

export async function transferAccountable(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("transfer_accountable_admin", { p_idempotency_key: key(f), p_organisation_id: text(f, "organisation_id"),
    p_person_id: text(f, "person_id") }, "Accountable administrator role handed over");
}

export async function setAccountable(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("set_accountable_admin", { p_idempotency_key: key(f), p_organisation_id: text(f, "organisation_id"),
    p_person_id: text(f, "person_id") }, "Accountable administrator set");
}

// ---- Relationships (P2-8, Q40) --------------------------------------------------------

export async function decideRelationship(_: ActionResult, f: FormData): Promise<ActionResult> {
  const accept = text(f, "decision") === "accept";
  return run(accept ? "accept_relationship" : "decline_relationship",
    { p_idempotency_key: key(f), p_relationship_id: text(f, "relationship_id"), p_expected_version: version(f) },
    accept ? "Accepted" : "Declined");
}

export async function confirmFacilitated(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("confirm_relationship_facilitated", { p_idempotency_key: key(f), p_relationship_id: text(f, "relationship_id"),
    p_expected_version: version(f), p_note: text(f, "note") }, "Acceptance recorded");
}

/** Who is ending it decides which decision is recorded: the person, their organisation, or the venue. */
const END_FUNCTION: Record<string, string> = {
  own: "end_own_relationship",
  organisation: "end_relationship",
  venue: "end_relationship_by_admin",
};

export async function endRelationship(_: ActionResult, f: FormData): Promise<ActionResult> {
  const fn = END_FUNCTION[text(f, "by")];
  if (!fn) return { ok: false, code: "error", reason: "Unknown request.", missing: "A valid request", resolvable_by: "You" };
  return run(fn, { p_idempotency_key: key(f), p_relationship_id: text(f, "relationship_id"),
    p_expected_version: version(f), p_reason: text(f, "reason") }, "Relationship ended");
}

// ---- Competencies (Q38) ---------------------------------------------------------------

export async function createCompetencyType(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_competency_type", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"),
    p_code: text(f, "code"), p_label: text(f, "label") }, "Competency type added");
}

export async function declareCompetency(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("declare_competency", {
    p_idempotency_key: key(f),
    p_person_id: text(f, "person_id"),
    p_competency_type_id: text(f, "competency_type_id"),
    p_issuer: text(f, "issuer"),
    p_number: text(f, "number"),
    p_expires_on: optional(f, "expires_on"),
    p_document_version_id: optional(f, "document_version_id"),
    p_via_organisation_id: optional(f, "organisation_id"),
  }, "Competency declared");
}

export async function verifyCompetency(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("verify_competency", {
    p_idempotency_key: key(f),
    p_competency_id: text(f, "competency_id"),
    p_method: text(f, "method"),
    p_source_checked: text(f, "source_checked"),
    p_holder_match: text(f, "holder_match") === "yes",
    p_scope: text(f, "scope"),
    p_valid_until: optional(f, "valid_until"),
    p_outcome: text(f, "outcome"),
    p_notes: optional(f, "notes"),
  }, "Verification recorded");
}

// ---- Restrictions (Q18, D-010) --------------------------------------------------------

export async function imposeRestriction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const [kind, id] = text(f, "subject").split(":");
  return run("impose_restriction", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"),
    p_subject_kind: kind, p_subject_id: id, p_reason: text(f, "reason") }, "Restriction recorded");
}

export async function liftRestriction(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("lift_restriction", { p_idempotency_key: key(f), p_restriction_id: text(f, "restriction_id"),
    p_expected_version: version(f), p_reason: text(f, "reason") }, "Restriction lifted");
}

// ---- Appointment types (D-011) --------------------------------------------------------

export async function createAppointmentType(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_appointment_type", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"),
    p_code: text(f, "code"), p_name: text(f, "name") }, "Appointment type created");
}

/** Proposes a version for a root appointee's approval, or publishes it while the venue has no root appointment. */
export async function proposeTypeVersion(_: ActionResult, f: FormData): Promise<ActionResult> {
  const publish = text(f, "mode") === "publish";
  return run(publish ? "publish_appointment_type_version" : "propose_appointment_type_version", {
    p_idempotency_key: key(f),
    p_appointment_type_id: text(f, "appointment_type_id"),
    p_allowed_action_codes: f.getAll("actions").map(String),
    p_eligible_permit_class_ids: [],
    p_eligible_system_type_ids: [],
    p_grantable_type_ids: f.getAll("grantable").map(String),
    p_is_root_eligible: text(f, "root_eligible") === "yes",
    p_requires_competence_evidence: text(f, "requires_evidence") === "yes",
    p_owner_person_id: text(f, "owner_person_id"),
    p_effective_from: new Date(text(f, "effective_from")).toISOString(),
    p_change_reason: text(f, "reason"),
  }, publish ? "Version published" : "Version proposed for approval");
}

export async function decideTypeVersion(_: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = text(f, "decision") === "approve";
  return run("decide_appointment_type_version", { p_idempotency_key: key(f), p_version_id: text(f, "version_id"),
    p_expected_version: version(f), p_decision: approve ? "approve" : "reject", p_reason: text(f, "reason") },
    approve ? "Version approved" : "Version rejected");
}

// ---- Invitations (Q26, Q32) -----------------------------------------------------------

export async function cancelInvitation(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("cancel_invitation", { p_idempotency_key: key(f), p_invitation_id: text(f, "invitation_id"),
    p_expected_version: version(f) }, "Invitation cancelled");
}

export async function resolveMatch(_: ActionResult, f: FormData): Promise<ActionResult> {
  const linked = text(f, "resolution") === "linked";
  return run("resolve_invitation_match", { p_idempotency_key: key(f), p_invitation_id: text(f, "invitation_id"),
    p_expected_version: version(f), p_resolution: linked ? "linked" : "separate" },
    linked ? "Linked to the existing organisation" : "Set up as a separate organisation");
}

// ---- People without logins (Q33, Q34) -------------------------------------------------

/** Records a person and their relationship to the organisation, which then waits for their (facilitated) acceptance. */
export async function recordPersonWithoutLogin(_: ActionResult, f: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const person = await write(db, "create_person", { p_idempotency_key: text(f, "key"), p_customer_id: text(f, "customer_id"),
      p_given_name: text(f, "given_name"), p_family_name: text(f, "family_name"), p_email: optional(f, "email") });
    if (!person.ok) return person as ActionResult;
    const rel = await write(db, "record_person_organisation", { p_idempotency_key: text(f, "key2"), p_person_id: person.id,
      p_organisation_id: text(f, "organisation_id"), p_kind: text(f, "kind"), p_valid_from: new Date().toISOString() });
    revalidatePath("/", "layout");
    if (!rel.ok) {
      return { ...rel, reason: `The person was recorded, but not linked to the organisation: ${rel.reason}` } as ActionResult;
    }
    return { ok: true, message: "Recorded.", detail: "Their relationship waits for their acceptance; record it under People once you have it." };
  } catch (e) {
    return failure(e);
  }
}

// ---- Activity screening decisions (Q55-Q59, D-017) -------------------------------------

export async function decideScreeningVersion(_: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = text(f, "decision") === "approve";
  return run("decide_screening_version", { p_idempotency_key: key(f), p_version_id: text(f, "version_id"),
    p_expected_version: version(f), p_decision: approve ? "approve" : "reject", p_reason: text(f, "reason") },
    approve ? "Screening approved; jobs submitted from now on use it" : "Screening version rejected");
}

export async function decideChallenge(_: ActionResult, f: FormData): Promise<ActionResult> {
  const notRequired = text(f, "outcome") === "not_required";
  return run("decide_challenge", { p_idempotency_key: key(f), p_recommendation_id: text(f, "recommendation_id"),
    p_expected_version: version(f), p_outcome: notRequired ? "not_required" : "upheld", p_reason: text(f, "reason"),
    p_scope_wording: optional(f, "scope_wording") },
    notRequired ? "Recorded: no permit required for the stated scope" : "Recorded: the permit is required");
}

export async function recordNoPermitRequired(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("record_no_permit_required", { p_idempotency_key: key(f), p_work_package_id: text(f, "work_package_id"),
    p_expected_version: version(f), p_scope_wording: text(f, "scope_wording"), p_reason: text(f, "reason") },
    "Recorded: no permit required for the stated scope");
}

export async function decideHold(_: ActionResult, f: FormData): Promise<ActionResult> {
  const accepted = text(f, "outcome") === "accepted";
  return run("decide_external_reference", { p_idempotency_key: key(f), p_hold_id: text(f, "hold_id"),
    p_expected_version: version(f), p_outcome: accepted ? "accepted" : "refused", p_reason: text(f, "reason") },
    accepted ? "External evidence accepted" : "External evidence refused");
}
