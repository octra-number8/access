"use server";

// Places and systems (S1b, D-026): area kinds and areas, system types and systems, the areas a
// system serves, and the ownership register. Each action calls one database function as the
// signed-in user; the database decides (D-003), including whether anything still depends on an
// area or system being retired.

import type { ActionResult } from "@/components/ActionForm";
import { optional, run, text } from "@/lib/action-helpers";
import { fromVenueLocal } from "@/lib/permits";

const key = (f: FormData) => text(f, "key");
const version = (f: FormData) => Number(text(f, "row_version"));
const at = (f: FormData, name: string) => { const v = text(f, name); return v ? fromVenueLocal(v, text(f, "tz")) : null; };
const missingDate = (what: string): ActionResult =>
  ({ ok: false, code: "missing", reason: `Say ${what}.`, missing: "A date and time", resolvable_by: "You" });

// Areas ------------------------------------------------------------------------------------------
export async function createAreaKind(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_area_kind", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"),
    p_code: text(f, "code"), p_label: text(f, "label") }, "Area kind added");
}

export async function createArea(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_area", { p_idempotency_key: key(f), p_parent_area_id: text(f, "parent_id"),
    p_area_kind_id: text(f, "kind_id"), p_code: text(f, "code"), p_name: text(f, "name") }, "Area added");
}

export async function retireArea(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("retire_area", { p_idempotency_key: key(f), p_area_id: text(f, "area_id"),
    p_expected_version: version(f) }, "Area retired");
}

// Systems ----------------------------------------------------------------------------------------
export async function createSystemType(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_system_type", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"),
    p_code: text(f, "code"), p_label: text(f, "label") }, "System type added");
}

export async function createSystem(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_system", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"),
    p_system_type_id: text(f, "type_id"), p_code: text(f, "code"), p_name: text(f, "name"),
    p_description: optional(f, "description") }, "System registered");
}

export async function linkSystemArea(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("link_system_area", { p_idempotency_key: key(f), p_system_id: text(f, "system_id"),
    p_area_id: text(f, "area_id") }, "Area linked");
}

export async function retireSystem(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("retire_system", { p_idempotency_key: key(f), p_system_id: text(f, "system_id"),
    p_expected_version: version(f) }, "System retired");
}

// Ownership register -------------------------------------------------------------------------------
export async function recordOwnership(_: ActionResult, f: FormData): Promise<ActionResult> {
  const from = at(f, "valid_from");
  if (!from) return missingDate("when the responsibility starts");
  const to = at(f, "valid_to");
  if (to && to <= from) return { ok: false, code: "dates", reason: "The end must be after the start.", missing: "An end after the start", resolvable_by: "You" };
  // One choice names the organisation, and optionally the engagement it relies on.
  const [organisation, engagement] = text(f, "party").split("|");
  return run("record_system_ownership", { p_idempotency_key: key(f), p_system_id: text(f, "system_id"),
    p_organisation_id: organisation, p_responsibility: text(f, "responsibility"), p_valid_from: from, p_valid_to: to,
    p_engagement_id: engagement || null, p_evidence_ref: optional(f, "evidence_ref") }, "Ownership recorded");
}

export async function endOwnership(_: ActionResult, f: FormData): Promise<ActionResult> {
  const from = at(f, "ends_from");
  if (!from) return missingDate("when the responsibility ends");
  return run("end_system_ownership", { p_idempotency_key: key(f), p_ownership_id: text(f, "ownership_id"),
    p_expected_version: version(f), p_ends_from: from, p_reason: text(f, "reason") }, "Ownership record ended");
}
