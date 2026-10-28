"use server";

// Legal holds (Q223, P8-14, §16.4): asked for by a hold requester, approved or refused by a hold
// approver who did not ask for it; renewed with a new review date or lifted with a reason. A hold
// never ends by time passing (invariant 10). The database decides each of these.

import type { ActionResult } from "@/components/ActionForm";
import { run, text } from "@/lib/action-helpers";

function withProblems(r: ActionResult): ActionResult {
  const problems = (r as { problems?: string[] } | null)?.problems;
  return r && r.ok === false && Array.isArray(problems) ? { ...r, reason: `${r.reason} ${problems.join(" ")}` } : r;
}

// A date and time typed in the venue's own time zone, as an instant.
function venueInstant(value: string, tz: string): string | null {
  if (!value) return null;
  const guess = new Date(`${value}:00Z`);
  const shown = new Date(guess.toLocaleString("en-US", { timeZone: tz }));
  return new Date(guess.getTime() + (guess.getTime() - shown.getTime())).toISOString();
}

export async function requestHold(_: ActionResult, f: FormData): Promise<ActionResult> {
  const tz = text(f, "tz") || "Europe/London";
  return withProblems(await run("request_legal_hold", {
    p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"), p_matter: text(f, "matter"), p_reason: text(f, "reason"),
    p_review_on: text(f, "review_on") || null,
    p_organisation_id: text(f, "organisation_id") || null, p_person_id: text(f, "person_id") || null,
    p_work_package_id: text(f, "work_package_id") || null, p_visit_id: text(f, "visit_id") || null,
    p_from: venueInstant(text(f, "from"), tz), p_to: venueInstant(text(f, "to"), tz),
  }, "Hold requested. It takes effect once a hold approver who did not ask for it approves it"));
}

export async function decideHold(_: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = text(f, "decision") === "approve";
  return run("decide_legal_hold", { p_idempotency_key: text(f, "key"), p_hold_id: text(f, "hold_id"),
    p_expected_version: Number(text(f, "row_version")), p_decision: approve ? "approve" : "refuse", p_reason: text(f, "reason") },
    approve ? "Hold approved: nothing it covers can be disposed of while it is in force" : "Hold refused");
}

export async function renewHold(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("renew_legal_hold", { p_idempotency_key: text(f, "key"), p_hold_id: text(f, "hold_id"), p_review_on: text(f, "review_on") || null,
    p_reason: text(f, "reason") }, "Hold renewed with a new review date");
}

export async function liftHold(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("lift_legal_hold", { p_idempotency_key: text(f, "key"), p_hold_id: text(f, "hold_id"),
    p_expected_version: Number(text(f, "row_version")), p_reason: text(f, "reason") },
    "Hold lifted. Records it kept are disposed of only if they are listed again and someone confirms it");
}
