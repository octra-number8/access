"use server";

// Corrections to a person's, organisation's or evidence file's details (8c-5, §16.5). The database
// decides who may record one and whether the detail itself changes.

import type { ActionResult } from "@/components/ActionForm";
import { run, text } from "@/lib/action-helpers";

export async function correctRecord(_: ActionResult, f: FormData): Promise<ActionResult> {
  const [kind, id, field] = text(f, "target").split(":");
  const r = await run("correct_record", {
    p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"), p_target_type: kind ?? "", p_target_id: id ?? "", p_field: field ?? "",
    p_corrected: text(f, "corrected"), p_reason: text(f, "reason"), p_evidence: text(f, "evidence"),
  }, kind === "document_version" ? "Correction recorded beside the file" : "Corrected, with the earlier value kept beside it");
  const problems = (r as { problems?: string[] } | null)?.problems;
  return r && r.ok === false && Array.isArray(problems) ? { ...r, reason: `${r.reason} ${problems.join(" ")}` } : r;
}
