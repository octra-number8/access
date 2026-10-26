"use server";

// Live permit actions (phase 6d, D-019): stopping, restarting, the live team, extensions,
// revalidation, physical controls at the workface, and hand-back. Each calls one database
// function as the signed-in user; the database decides who may do what, and refuses with
// what is missing and who can resolve it.

import type { ActionResult } from "@/components/ActionForm";
import { optional, run, text } from "@/lib/action-helpers";
import { fromVenueLocal } from "@/lib/permits";

const key = (f: FormData) => text(f, "key");
const ver = (f: FormData) => Number(text(f, "row_version"));
const ids = (f: FormData, n: string) => f.getAll(n).map(String).filter(Boolean);
const lines = (s: string) => s.split("\n").map((x) => x.trim()).filter(Boolean);

/** Adds the lists a refusal carries (duties, suspensions, blockers, problems) to its reason. */
async function explained(p: Promise<ActionResult>): Promise<ActionResult> {
  const r = await p;
  if (!r || r.ok !== false) return r;
  const x = r as unknown as Record<string, unknown>;
  const items = [
    ...((x.problems as string[] | undefined) ?? []),
    ...((x.blockers as Array<{ problem: string }> | undefined) ?? []).map((b) => b.problem),
    ...((x.duties as Array<{ problem: string; who: string }> | undefined) ?? []).map((d) => `${d.problem} (${d.who})`),
    ...((x.suspensions as Array<{ reason: string; who: string }> | undefined) ?? []).map((s) => `${s.reason} — ${s.who}`),
    ...((x.items as string[] | undefined) ?? []),
  ];
  return items.length ? { ...r, reason: `${r.reason} ${items.join(" ")}` } : r;
}

// ---- Stopping and restarting (P6-2, P6-3) ---------------------------------------------------
export async function stopWork(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("stop_work", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_category: text(f, "category"),
    p_reason: text(f, "reason") }, "Work stopped. Everyone on the job must stop now");
}

export async function liftSuspension(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("lift_suspension", { p_idempotency_key: key(f), p_suspension_id: text(f, "suspension_id"), p_reason: text(f, "reason"),
    p_conditions: lines(text(f, "conditions")) }, "Suspension lifted. Work restarts only when the supervisor re-briefs and re-accepts");
}

export async function reacceptPermit(_: ActionResult, f: FormData): Promise<ActionResult> {
  return explained(run("reaccept_permit", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_acknowledged_condition_ids: ids(f, "acknowledged"), p_acknowledged_lift_ids: ids(f, "lifts"), p_briefed_person_ids: ids(f, "briefed"),
    p_briefed_at: new Date().toISOString() }, "Re-accepted. The permit is active again"));
}

// ---- The live team (P6-6) -------------------------------------------------------------------
export async function addWorker(_: ActionResult, f: FormData): Promise<ActionResult> {
  return explained(run("add_worker", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_person_id: text(f, "person_id") }, "Added. They join the team once briefed"));
}

export async function approveWorker(_: ActionResult, f: FormData): Promise<ActionResult> {
  return explained(run("approve_worker", { p_idempotency_key: key(f), p_member_id: text(f, "member_id") }, "Addition approved"));
}

export async function briefWorker(_: ActionResult, f: FormData): Promise<ActionResult> {
  return explained(run("brief_worker", { p_idempotency_key: key(f), p_member_id: text(f, "member_id"), p_briefed_at: new Date().toISOString() },
    "Briefing recorded. They are on the team"));
}

export async function excludeWorker(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("exclude_worker", { p_idempotency_key: key(f), p_member_id: text(f, "member_id"), p_reason: text(f, "reason") }, "Removed from the team");
}

export async function changeSupervisor(_: ActionResult, f: FormData): Promise<ActionResult> {
  return explained(run("change_supervisor", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_person_id: text(f, "person_id"), p_keep_previous_as_operative: f.get("keep") === "on", p_reason: text(f, "reason") },
    "Supervisor changed. The permit is suspended until the new supervisor re-accepts"));
}

// ---- Extension and revalidation (P6-5, P6-7) ---------------------------------------------------
export async function extendPermit(_: ActionResult, f: FormData): Promise<ActionResult> {
  return explained(run("extend_permit", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_new_end: fromVenueLocal(text(f, "new_end"), text(f, "tz")), p_reason: text(f, "reason") },
    "Extension recorded. It counts once the supervisor acknowledges it"));
}

export async function acknowledgeExtension(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("acknowledge_extension", { p_idempotency_key: key(f), p_extension_id: text(f, "extension_id") }, "Extension acknowledged");
}

export async function revalidatePermit(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("revalidate_permit", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_conditions_note: optional(f, "note") }, "Revalidation recorded");
}

// ---- Controls at the workface (6b) -------------------------------------------------------------
export async function requestControl(_: ActionResult, f: FormData): Promise<ActionResult> {
  const tz = text(f, "tz");
  const kind = text(f, "kind");
  const args = { p_idempotency_key: key(f), p_permit_ids: [text(f, "permit_id")], p_system_id: text(f, "system_id"),
    p_reason: text(f, "reason"), p_from: fromVenueLocal(text(f, "from"), tz), p_to: fromVenueLocal(text(f, "to"), tz) };
  return explained(kind === "impairment"
    ? run("request_impairment", { ...args, p_zones: text(f, "detail") }, "Impairment asked for. The system's authority decides it")
    : run("request_isolation", { ...args, p_points: text(f, "detail") }, "Isolation asked for. The system's authority decides it"));
}

export async function lockOn(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("isolation_lock_on", { p_idempotency_key: key(f), p_isolation_id: text(f, "isolation_id"), p_person_id: text(f, "person_id"),
    p_lock_ref: text(f, "lock_ref") }, "Personal lock recorded");
}

export async function lockOff(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("isolation_lock_off", { p_idempotency_key: key(f), p_lock_id: text(f, "lock_id") }, "Personal lock taken off");
}

export async function arrangeFireWatch(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("arrange_fire_watch", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_phase: text(f, "phase"),
    p_watcher_person_id: text(f, "watcher") }, "Fire watch arranged");
}

export async function startFireWatch(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("start_fire_watch", { p_idempotency_key: key(f), p_fire_watch_id: text(f, "fire_watch_id"), p_expected_version: ver(f) }, "Fire watch started");
}

export async function checkFireWatch(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("check_fire_watch", { p_idempotency_key: key(f), p_fire_watch_id: text(f, "fire_watch_id"), p_findings: text(f, "findings") }, "Check recorded");
}

export async function endFireWatch(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("end_fire_watch", { p_idempotency_key: key(f), p_fire_watch_id: text(f, "fire_watch_id"), p_expected_version: ver(f),
    p_final_findings: text(f, "findings") }, "Final check recorded; the watch has ended");
}

export async function setUpZone(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("set_up_exclusion_zone", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_area_id: optional(f, "area_id"),
    p_description: text(f, "description") }, "Exclusion zone recorded");
}

export async function removeZone(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("remove_exclusion_zone", { p_idempotency_key: key(f), p_zone_id: text(f, "zone_id"), p_expected_version: ver(f),
    p_note: text(f, "note") }, "Exclusion zone removed");
}

export async function reportFailure(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("report_control_failure", { p_idempotency_key: key(f), p_kind: text(f, "kind"), p_control_id: text(f, "control_id"),
    p_reason: text(f, "reason") }, "Failure reported. Every job relying on this control is stopped");
}

// ---- Hand-back and closure (6c) ----------------------------------------------------------------
export async function handBack(_: ActionResult, f: FormData): Promise<ActionResult> {
  const complete = text(f, "complete") === "yes";
  return explained(run("hand_back_permit", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_work_complete: text(f, "complete") === "" ? null : complete, p_remaining_work: optional(f, "remaining"), p_area_state: text(f, "area_state"),
    p_all_workers_out: f.get("workers_out") === "on" }, "Handed back. The hand-back acceptor decides it"));
}

export async function decideHandBack(_: ActionResult, f: FormData): Promise<ActionResult> {
  const accept = text(f, "outcome") === "accept";
  return explained(run("decide_hand_back", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_outcome: accept ? "accept" : "reject", p_inspection: text(f, "inspection"), p_reason: text(f, "reason") },
    accept ? "Hand-back accepted. The permit is closed" : "Hand-back rejected; the permit is back where it was"));
}

export async function returnAreas(_: ActionResult, f: FormData): Promise<ActionResult> {
  return explained(run("return_areas", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_area_ids: ids(f, "area_ids"), p_area_state: text(f, "area_state") }, "Areas handed back. The hand-back acceptor decides it"));
}

export async function decideAreaReturn(_: ActionResult, f: FormData): Promise<ActionResult> {
  const accept = text(f, "outcome") === "accept";
  return run("decide_area_return", { p_idempotency_key: key(f), p_area_return_id: text(f, "area_return_id"),
    p_outcome: accept ? "accept" : "reject", p_reason: text(f, "reason") }, accept ? "Areas accepted back" : "Return of areas rejected");
}

export async function cancelIssued(_: ActionResult, f: FormData): Promise<ActionResult> {
  return explained(run("cancel_issued_permit", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_reason: text(f, "reason") }, "Permit cancelled"));
}

export async function flagAbandoned(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("flag_abandoned", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_reason: text(f, "reason") },
    "Flagged abandoned. It must still be closed out");
}
