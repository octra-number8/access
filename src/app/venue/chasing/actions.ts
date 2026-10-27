"use server";

// The venue's chasing (Q207, P8-5): which overdue items are chased, how often their owners are
// reminded, and when and to whom they are escalated. No default; approved by an appointee who
// did not write it. Escalation only tells more people: it never changes the overdue item.

import type { ActionResult } from "@/components/ActionForm";
import { failure, run, text } from "@/lib/action-helpers";
import { supabaseServer } from "@/lib/supabase/server";
import { CHASE_KINDS, type ChaseItem } from "@/components/chasing-view";


function withProblems(r: ActionResult): ActionResult {
  const problems = (r as { problems?: string[] } | null)?.problems;
  return r && r.ok === false && Array.isArray(problems) ? { ...r, reason: `${r.reason} ${problems.join(" ")}` } : r;
}

export async function startChasingDraft(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_venue_config_draft", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"), p_kind: "chasing" }, "Draft started");
}

export async function saveChasing(_: ActionResult, f: FormData): Promise<ActionResult> {
  const items: Record<string, ChaseItem> = {};
  for (const [kind] of CHASE_KINDS) {
    if (f.get(`${kind}.on`) !== "on") continue;
    const escalate = text(f, `${kind}.escalate`);
    if (escalate === "") {
      return { ok: false, code: "invalid_content", reason: "For each kind you chase, say whether it is escalated.", missing: "A choice", resolvable_by: "You" };
    }
    items[kind] = {
      remind_every_hours: Number(text(f, `${kind}.remind`)),
      escalate_after_hours: escalate === "no" ? null : Number(text(f, `${kind}.after`)),
      ...(escalate === "no" ? {} : { escalate_to: { person_ids: f.getAll(`${kind}.people`).map(String), appointment_type_ids: f.getAll(`${kind}.types`).map(String) } }),
    };
  }
  const db = await supabaseServer();
  try {
    const { data } = await db.from("venue_config_version").select("row_version").eq("id", text(f, "version_id")).single();
    return withProblems(await run("save_venue_config_draft", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
      p_expected_version: data!.row_version, p_content: { items }, p_source_ref: null }, "Chasing saved"));
  } catch (e) {
    return failure(e);
  }
}

export async function proposeChasing(_: ActionResult, f: FormData): Promise<ActionResult> {
  return withProblems(await run("propose_venue_config", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
    p_expected_version: Number(text(f, "row_version")) }, "Proposed. An appointee approves it from their decisions page"));
}

export async function decideChasing(_: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = text(f, "decision") === "approve";
  return run("decide_venue_config", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
    p_expected_version: Number(text(f, "row_version")), p_decision: approve ? "approve" : "reject", p_reason: text(f, "reason") },
    approve ? "Chasing approved; reminders follow it from the next run" : "Chasing rejected");
}
