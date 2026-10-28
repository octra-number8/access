"use server";

// The venue's retention schedule and disposal (phase 8d, D-022, Q221–Q224): the schedule is drafted
// by a tenant administrator and approved by a retention appointee who did not write it; batches
// listed by the job are confirmed or declined by a disposal appointee who did not approve the
// schedule. The database decides every one of these and checks each record again at confirmation.

import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/components/ActionForm";
import { failure, run, text } from "@/lib/action-helpers";
import { write } from "@/lib/authz";
import { supabaseServer } from "@/lib/supabase/server";
import { RETENTION_CATEGORIES } from "@/lib/retention";

function withProblems(r: ActionResult): ActionResult {
  const problems = (r as { problems?: string[] } | null)?.problems;
  return r && r.ok === false && Array.isArray(problems) ? { ...r, reason: `${r.reason} ${problems.join(" ")}` } : r;
}

export async function startRetentionDraft(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_venue_config_draft", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"), p_kind: "retention" }, "Draft started");
}

export async function saveRetention(_: ActionResult, f: FormData): Promise<ActionResult> {
  const rules: Record<string, { days: number | string; basis: string }> = {};
  for (const code of RETENTION_CATEGORIES) {
    if (f.get(`${code}.on`) !== "on") continue;
    const days = text(f, `${code}.days`);
    // Sent as given: the database says what is wrong with it, in words.
    rules[code] = { days: /^\d+$/.test(days) ? Number(days) : days, basis: text(f, `${code}.basis`) };
  }
  const db = await supabaseServer();
  try {
    const { data } = await db.from("venue_config_version").select("row_version").eq("id", text(f, "version_id")).single();
    return withProblems(await run("save_venue_config_draft", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
      p_expected_version: data!.row_version, p_content: { rules }, p_source_ref: text(f, "source_ref") || null }, "Schedule saved"));
  } catch (e) {
    return failure(e);
  }
}

export async function proposeRetention(_: ActionResult, f: FormData): Promise<ActionResult> {
  return withProblems(await run("propose_venue_config", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
    p_expected_version: Number(text(f, "row_version")) }, "Proposed. A retention appointee who did not write it approves it here"));
}

export async function decideRetention(_: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = text(f, "decision") === "approve";
  return run("decide_venue_config", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
    p_expected_version: Number(text(f, "row_version")), p_decision: approve ? "approve" : "reject", p_reason: text(f, "reason") },
    approve ? "Schedule approved. Records past their period are listed at the next run, for someone to confirm" : "Schedule rejected");
}

export async function decideBatch(_: ActionResult, f: FormData): Promise<ActionResult> {
  const confirm = text(f, "decision") === "confirm";
  const db = await supabaseServer();
  try {
    const r = await write(db, "decide_disposal_batch", { p_idempotency_key: text(f, "key"), p_batch_id: text(f, "batch_id"),
      p_expected_version: Number(text(f, "row_version")), p_decision: confirm ? "confirm" : "decline", p_reason: text(f, "reason") });
    if (!r.ok) return r as ActionResult;
    revalidatePath("/", "layout");
    if (!confirm) return { ok: true, message: "Batch declined. Its records are kept and not listed again under this schedule." };
    const x = r as { disposed?: number; kept?: number };
    return { ok: true, message: `Batch confirmed: ${x.disposed ?? 0} disposed of, ${x.kept ?? 0} kept.`,
             detail: (x.kept ?? 0) > 0 ? "The records kept, and why, are listed with the batch." : undefined };
  } catch (e) {
    return failure(e);
  }
}
