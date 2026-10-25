"use server";

// Permit actions (phase 5c, D-018). Each calls one database function as the signed-in
// user; the database decides who may do what and whether the permit is ready.

import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/components/ActionForm";
import { failure, optional, run, text } from "@/lib/action-helpers";
import { write } from "@/lib/authz";
import { fromVenueLocal } from "@/lib/permits";
import { supabaseServer } from "@/lib/supabase/server";

function withDetail(r: ActionResult): ActionResult {
  const x = r as { problems?: string[]; blockers?: Array<{ problem: string }> } | null;
  if (!r || r.ok !== false) return r;
  const more = [...(x?.problems ?? []), ...(x?.blockers ?? []).map((b) => b.problem)];
  return more.length ? { ...r, reason: `${r.reason} ${more.join(" ")}` } : r;
}

const key = (f: FormData) => text(f, "key");
const ver = (f: FormData) => Number(text(f, "row_version"));
// datetime-local inputs are the venue's local time; the form carries its time zone.
const when = (f: FormData, n: string) => (optional(f, n) ? fromVenueLocal(text(f, n), text(f, "tz")) : null);

export async function startPermits(_: ActionResult, f: FormData): Promise<ActionResult> {
  return withDetail(await run("start_permits", { p_idempotency_key: key(f), p_work_package_id: text(f, "work_package_id") }, "Permits started"));
}

export async function savePermitDraft(_: ActionResult, f: FormData): Promise<ActionResult> {
  const answers: Record<string, string[]> = JSON.parse(text(f, "answers") || "{}");
  return withDetail(await run("save_permit_draft", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_answers: answers,
    p_window_from: when(f, "window_from"), p_window_to: when(f, "window_to"),
    p_document_version_ids: f.getAll("document_version_ids").map(String) }, "Saved"));
}

export async function setTeam(_: ActionResult, f: FormData): Promise<ActionResult> {
  const supervisor = text(f, "supervisor");
  const members = [{ person_id: supervisor, role: "supervisor" },
                   ...f.getAll("operatives").map(String).filter((p) => p !== supervisor).map((p) => ({ person_id: p, role: "operative" }))];
  return withDetail(await run("set_permit_team", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_members: members }, "Team saved"));
}

export async function submitPermit(_: ActionResult, f: FormData): Promise<ActionResult> {
  if (f.get("confirm") !== "on") {
    return { ok: false, code: "declaration", reason: "Confirm the declaration to submit.", missing: "Your confirmation", resolvable_by: "You" };
  }
  return withDetail(await run("submit_permit", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f) },
    "Submitted. The venue's reviewers decide each step"));
}

export async function respondToRfi(_: ActionResult, f: FormData): Promise<ActionResult> {
  if (f.get("confirm") !== "on") {
    return { ok: false, code: "declaration", reason: "Confirm the declaration to resubmit.", missing: "Your confirmation", resolvable_by: "You" };
  }
  return withDetail(await run("respond_to_rfi", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_responses: f.getAll("responses").map(String) }, "Response sent as a new version; every step decides again"));
}

export async function cancelPermit(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("cancel_permit", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
    p_reason: text(f, "reason") }, "Request cancelled");
}

export async function requestException(_: ActionResult, f: FormData): Promise<ActionResult> {
  const [kind, windowId] = text(f, "kind_and_window").split(":");
  return run("request_exception", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_kind: kind,
    p_reason: text(f, "reason"), p_consequence: text(f, "consequence"), p_restriction_window_id: windowId ?? null },
    "Exception asked for. The venue's authority decides it");
}

export async function decideException(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("decide_exception", { p_idempotency_key: key(f), p_request_id: text(f, "request_id"), p_outcome: text(f, "outcome"),
    p_reason: text(f, "reason"), p_conditions: optional(f, "conditions") }, text(f, "outcome") === "allowed" ? "Exception allowed" : "Exception refused");
}

export async function decideStep(_: ActionResult, f: FormData): Promise<ActionResult> {
  const outcome = text(f, "outcome");
  const conditions = f.getAll("condition_text").map(String).map((t, i) => ({ text: t.trim(), acknowledge: f.getAll("condition_ack").map(String).includes(String(i)) }))
    .filter((c) => c.text);
  const items = f.getAll("rfi_item").map(String).map((t) => t.trim()).filter(Boolean).map((t) => ({ text: t }));
  return run("decide_step", {
    p_idempotency_key: key(f), p_step_id: text(f, "step_id"), p_outcome: outcome, p_reason: text(f, "reason"),
    p_scope_wording: optional(f, "scope_wording"), p_conditions: conditions,
    p_rfi: outcome === "more_information" ? { message: text(f, "rfi_message"), items } : null,
    p_external: text(f, "kind") === "external" ? { decider: text(f, "ext_decider"), organisation: text(f, "ext_organisation"),
      reference: optional(f, "ext_reference"), scope: text(f, "ext_scope"), decided_on: optional(f, "ext_decided_on"),
      conditions: optional(f, "ext_conditions") } : null,
  }, "Decision recorded");
}

export async function reopenStep(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("reopen_step", { p_idempotency_key: key(f), p_step_id: text(f, "step_id"), p_reason: text(f, "reason") },
    "Decision withdrawn; the permit is back under review");
}

export async function issuePermit(_: ActionResult, f: FormData): Promise<ActionResult> {
  return withDetail(await run("issue_permit", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f) },
    "Issued. The named supervisor accepts it at the workface"));
}

export async function acceptPermit(_: ActionResult, f: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const r = await write(db, "accept_permit", { p_idempotency_key: key(f), p_permit_id: text(f, "permit_id"), p_expected_version: ver(f),
      p_acknowledged_condition_ids: f.getAll("acknowledged").map(String), p_briefed_person_ids: f.getAll("briefed").map(String),
      p_briefed_at: new Date().toISOString() });
    if (!r.ok) return r as ActionResult;
    revalidatePath("/", "layout");
    return { ok: true, message: "Accepted. The permit is active.", detail: "Stop the work if anything changes from what the permit describes." };
  } catch (e) {
    return failure(e);
  }
}

export async function decideClassVersion(_: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = text(f, "decision") === "approve";
  return run("decide_class_version", { p_idempotency_key: key(f), p_version_id: text(f, "version_id"), p_expected_version: ver(f),
    p_decision: approve ? "approve" : "reject", p_reason: text(f, "reason") },
    approve ? "Configuration approved; requests made from now on use it" : "Configuration rejected");
}
