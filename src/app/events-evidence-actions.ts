"use server";

// Events and evidence settings (S1c, D-026): events and their phases, document types, review
// criteria, competency types and evidence requirements. Each action calls one database function
// as the signed-in user; the database decides (D-003).

import type { ActionResult } from "@/components/ActionForm";
import { run, text } from "@/lib/action-helpers";
import { fromVenueLocal } from "@/lib/permits";

const key = (f: FormData) => text(f, "key");
const at = (f: FormData, name: string) => { const v = text(f, name); return v ? fromVenueLocal(v, text(f, "tz")) : null; };
const refuse = (reason: string, missing: string): ActionResult => ({ ok: false, code: "missing", reason, missing, resolvable_by: "You" });
// A published version takes effect when the form says, or straight away when left empty.
const effective = (f: FormData) => at(f, "effective_from") ?? new Date().toISOString();

// Events -----------------------------------------------------------------------------------------
function span(f: FormData): { starts: string; ends: string } | { error: ActionResult } {
  const starts = at(f, "starts");
  const ends = at(f, "ends");
  if (!starts || !ends) return { error: refuse("Say when it starts and ends.", "A start and an end") };
  if (ends <= starts) return { error: refuse("The end must be after the start.", "An end after the start") };
  return { starts, ends };
}

export async function createEvent(_: ActionResult, f: FormData): Promise<ActionResult> {
  const w = span(f);
  if ("error" in w) return w.error;
  return run("create_event", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"), p_code: text(f, "code"),
    p_name: text(f, "name"), p_starts: w.starts, p_ends: w.ends }, "Event created");
}

export async function addEventPhase(_: ActionResult, f: FormData): Promise<ActionResult> {
  const w = span(f);
  if ("error" in w) return w.error;
  return run("add_event_phase", { p_idempotency_key: key(f), p_event_id: text(f, "event_id"), p_phase: text(f, "phase"),
    p_starts: w.starts, p_ends: w.ends }, "Phase added");
}

// Document types and review criteria ---------------------------------------------------------------
export async function createDocumentType(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_document_type", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"), p_code: text(f, "code"),
    p_label: text(f, "label"), p_owner_level: text(f, "owner_level") }, "Document type added");
}

// One criterion per line. Its code is made from its wording, so a reviewer's result for each
// line is recorded against that line; two lines with the same wording are refused.
export async function publishReviewCriteria(_: ActionResult, f: FormData): Promise<ActionResult> {
  const lines = text(f, "criteria").split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length === 0) return refuse("Write at least one criterion.", "One criterion per line");
  const criteria = lines.map((label) => ({
    code: label.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 40) || "criterion",
    label,
  }));
  if (new Set(criteria.map((c) => c.code)).size !== criteria.length) {
    return refuse("Two criteria have the same wording. Make each one different.", "Distinct criteria");
  }
  return run("publish_review_criteria", { p_idempotency_key: key(f), p_document_type_id: text(f, "document_type_id"),
    p_criteria: criteria, p_owner_person_id: text(f, "owner_person_id"), p_effective_from: effective(f),
    p_change_reason: text(f, "reason") }, "Review criteria published");
}

// Evidence requirements ----------------------------------------------------------------------------
// One choice says who it applies to ("capacity:<code>" or "appointment:<id>"), another what it
// asks for ("document:<id>" or "competency:<id>").
export async function createEvidenceRequirement(_: ActionResult, f: FormData): Promise<ActionResult> {
  const [appliesKind, appliesTo] = text(f, "applies_to").split(":");
  const [requiresKind, requires] = text(f, "requires").split(":");
  if (!appliesTo || !requires) return refuse("Say who it applies to and what it asks for.", "Both choices");
  return run("create_evidence_requirement", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"),
    p_code: text(f, "code"), p_label: text(f, "label"),
    p_applies_to_kind: appliesKind === "capacity" ? "engagement_capacity" : "appointment_type",
    p_capacity_code: appliesKind === "capacity" ? appliesTo : null,
    p_appointment_type_id: appliesKind === "appointment" ? appliesTo : null,
    p_requires_kind: requiresKind === "document" ? "document_type" : "competency_type",
    p_document_type_id: requiresKind === "document" ? requires : null,
    p_competency_type_id: requiresKind === "competency" ? requires : null }, "Evidence requirement defined");
}

export async function publishRequirementVersion(_: ActionResult, f: FormData): Promise<ActionResult> {
  const inForce = text(f, "in_force");
  if (inForce !== "yes" && inForce !== "no") return refuse("Say whether it is in force.", "In force or not");
  return run("publish_evidence_requirement_version", { p_idempotency_key: key(f), p_requirement_id: text(f, "requirement_id"),
    p_in_force: inForce === "yes", p_owner_person_id: text(f, "owner_person_id"), p_effective_from: effective(f),
    p_change_reason: text(f, "reason") }, "Version published");
}
