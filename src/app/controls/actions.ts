"use server";

// Controls desk, live board and emergency work actions (phase 6d, D-019). Each calls one
// database function as the signed-in user; the database decides.

import type { ActionResult } from "@/components/ActionForm";
import { optional, run, text } from "@/lib/action-helpers";

const key = (f: FormData) => text(f, "key");
const ver = (f: FormData) => Number(text(f, "row_version"));
const lines = (s: string) => s.split("\n").map((x) => x.trim()).filter(Boolean);

async function explained(p: Promise<ActionResult>): Promise<ActionResult> {
  const r = await p;
  if (!r || r.ok !== false) return r;
  const x = r as unknown as Record<string, unknown>;
  const items = [
    ...((x.problems as string[] | undefined) ?? []),
    ...((x.items as string[] | undefined) ?? []),
    ...((x.permits as Array<{ job_reference: string; class: string }> | undefined) ?? []).map((p) => `${p.job_reference} ${p.class}`),
    ...((x.locks as string[] | undefined) ?? []).map((n) => `${n}'s lock`),
    ...((x.jobs as string[] | undefined) ?? []),
  ];
  return items.length ? { ...r, reason: `${r.reason} ${items.join(", ")}.` } : r;
}

// ---- Isolations -------------------------------------------------------------------------------
export async function isolationStep(_: ActionResult, f: FormData): Promise<ActionResult> {
  const step = text(f, "step");
  const base = { p_idempotency_key: key(f), p_isolation_id: text(f, "id"), p_expected_version: ver(f) };
  switch (step) {
    case "authorise": case "refuse":
      return run("authorise_isolation", { ...base, p_outcome: step, p_note: text(f, "note") }, step === "authorise" ? "Isolation authorised" : "Isolation refused");
    case "apply":
      return run("apply_isolation", { ...base, p_certificate_ref: text(f, "certificate_ref"), p_lock_refs: lines(text(f, "lock_refs")),
        p_lock_box_ref: optional(f, "lock_box_ref") }, "Isolation applied. It must be proved before work relies on it");
    case "prove":
      return run("prove_isolation", { ...base, p_instrument_ref: text(f, "instrument_ref"), p_method: text(f, "method"),
        p_confirmed: f.get("confirmed") === "on" }, "Isolation proved");
    case "remove":
      return explained(run("remove_isolation", { ...base, p_note: text(f, "note") }, "Isolation removed"));
    case "return":
      return run("return_isolation", { ...base, p_evidence: text(f, "evidence"), p_witness_person_id: optional(f, "witness") }, "System returned to service");
    case "withdraw":
      return run("withdraw_isolation", { ...base, p_reason: text(f, "note") }, "Isolation request withdrawn");
    default:
      return { ok: false, code: "unknown", reason: "Unknown step.", missing: "A step", resolvable_by: "You" };
  }
}

export async function lockOffOnBehalf(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("isolation_lock_off_on_behalf", { p_idempotency_key: key(f), p_lock_id: text(f, "lock_id"), p_reason: text(f, "reason"),
    p_confirmed_not_in_area: f.get("confirmed") === "on" }, "Lock removed on the holder's behalf");
}

// ---- Impairments ------------------------------------------------------------------------------
export async function impairmentStep(_: ActionResult, f: FormData): Promise<ActionResult> {
  const step = text(f, "step");
  const base = { p_idempotency_key: key(f), p_impairment_id: text(f, "id"), p_expected_version: ver(f) };
  switch (step) {
    case "authorise": case "refuse":
      return run("authorise_impairment", { ...base, p_outcome: step, p_note: text(f, "note") }, step === "authorise" ? "Impairment authorised" : "Impairment refused");
    case "impair": {
      const measures = f.getAll("measure").map(String).map((m, i) => ({ measure: m, in_place_person_id: String(f.getAll("measure_person")[i] ?? "") }))
        .filter((m) => m.in_place_person_id);
      const notices = f.getAll("notification").map(String).map((n, i) => ({ notification: n, told: String(f.getAll("told")[i] ?? "").trim(),
        how: String(f.getAll("how")[i] ?? "").trim(), at: new Date().toISOString() })).filter((n) => n.told);
      return explained(run("impair_system", { ...base, p_measures: measures, p_notifications: notices }, "System impaired"));
    }
    case "test":
      return run("test_reinstatement", { ...base, p_witness_person_id: optional(f, "witness"), p_passed: text(f, "passed") === "" ? null : text(f, "passed") === "yes",
        p_note: text(f, "note") }, text(f, "passed") === "yes" ? "Reinstatement test passed" : "Failed test recorded; the system stays impaired");
    case "restore":
      return run("restore_system", { ...base, p_note: text(f, "note") }, "System confirmed back in service");
    case "reauthorise":
      return run("reauthorise_impairment", { ...base, p_new_max_hours: Number(text(f, "max_hours")), p_reason: text(f, "note") },
        "Impairment authorised to continue");
    case "withdraw":
      return run("withdraw_impairment", { ...base, p_reason: text(f, "note") }, "Impairment request withdrawn");
    default:
      return { ok: false, code: "unknown", reason: "Unknown step.", missing: "A step", resolvable_by: "You" };
  }
}

// ---- Continuing controls and failures -----------------------------------------------------------
export async function transferControl(_: ActionResult, f: FormData): Promise<ActionResult> {
  return explained(run("transfer_control", { p_idempotency_key: key(f), p_kind: text(f, "kind"), p_control_id: text(f, "id"),
    p_reason: text(f, "reason"), p_review_on: optional(f, "review_on") }, "You now own this control; it continues after the work"));
}

export async function liftControlFailure(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("lift_control_failure", { p_idempotency_key: key(f), p_failure_id: text(f, "failure_id"), p_reason: text(f, "reason"),
    p_conditions: lines(text(f, "conditions")) }, "Failure lifted. Each permit restarts when its supervisor re-accepts");
}

export async function reportFailureAsAuthority(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("report_control_failure", { p_idempotency_key: key(f), p_kind: text(f, "kind"), p_control_id: text(f, "id"),
    p_reason: text(f, "reason") }, "Failure reported. Every job relying on this control is stopped");
}

// ---- Rules, custody, area stops ------------------------------------------------------------------
export async function publishControlRule(_: ActionResult, f: FormData): Promise<ActionResult> {
  const kind = text(f, "kind");
  const content = kind === "isolation"
    ? { prove_by: text(f, "prove_by") || undefined, return_witness: text(f, "return_witness") || undefined }
    : { max_duration_hours: text(f, "max_hours") === "" ? undefined : Number(text(f, "max_hours")),
        compensatory_measures: lines(text(f, "measures")), notifications: lines(text(f, "notifications")) };
  return explained(run("publish_control_rule", { p_idempotency_key: key(f), p_system_type_id: text(f, "system_type_id"), p_kind: kind,
    p_content: content, p_effective_from: new Date().toISOString(), p_change_reason: text(f, "reason") }, "Rules published"));
}

export async function registerCustodyItem(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("register_custody_item", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"), p_kind: text(f, "kind"),
    p_label: text(f, "label"), p_reference: text(f, "reference"), p_area_id: optional(f, "area_id") }, "Added to the custody register");
}

export async function issueCustody(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("issue_custody_item", { p_idempotency_key: key(f), p_item_id: text(f, "item_id"), p_permit_id: text(f, "permit_id"),
    p_holder_person_id: text(f, "holder") }, "Issued");
}

export async function returnCustody(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("return_custody_item", { p_idempotency_key: key(f), p_movement_id: text(f, "movement_id") }, "Return recorded");
}

export async function stopArea(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("stop_area", { p_idempotency_key: key(f), p_area_id: text(f, "area_id"), p_category: text(f, "category"), p_reason: text(f, "reason") },
    "Area stopped. Every live permit there is suspended");
}

export async function liftAreaStop(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("lift_area_stop", { p_idempotency_key: key(f), p_area_stop_id: text(f, "area_stop_id"), p_reason: text(f, "reason"),
    p_conditions: lines(text(f, "conditions")) }, "Area stop lifted. Each permit restarts when its supervisor re-accepts");
}

// ---- Emergency work ------------------------------------------------------------------------------
export async function publishEmergencyConfig(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("publish_emergency_config", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"), p_categories: lines(text(f, "categories")),
    p_retrospective_hours: text(f, "hours") === "" ? null : Number(text(f, "hours")), p_effective_from: new Date().toISOString(),
    p_change_reason: text(f, "reason") }, "Emergency definitions published");
}

export async function authoriseEmergency(_: ActionResult, f: FormData): Promise<ActionResult> {
  return explained(run("authorise_emergency", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"), p_category: text(f, "category"),
    p_description: text(f, "description"), p_why_could_not_wait: text(f, "why"), p_area_ids: f.getAll("area_ids").map(String),
    p_system_ids: f.getAll("system_ids").map(String), p_organisation_id: text(f, "organisation_id"), p_person_ids: f.getAll("person_ids").map(String),
    p_controls_applied: text(f, "controls") }, "Emergency work authorised. The retrospective permit is due by the deadline shown"));
}

export async function linkRetrospective(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("link_retrospective_job", { p_idempotency_key: key(f), p_emergency_id: text(f, "emergency_id"), p_work_package_id: text(f, "work_package_id") },
    "Retrospective job linked");
}

export async function publishEmergencyContacts(_: ActionResult, f: FormData): Promise<ActionResult> {
  const contacts = lines(text(f, "contacts")).map((l) => {
    const i = l.lastIndexOf(":");
    return i > 0 ? { label: l.slice(0, i).trim(), phone: l.slice(i + 1).trim() } : { label: l, phone: "" };
  });
  return run("publish_emergency_contacts", { p_idempotency_key: key(f), p_venue_id: text(f, "venue_id"), p_contacts: contacts,
    p_change_reason: text(f, "reason") }, "Emergency contacts published");
}
