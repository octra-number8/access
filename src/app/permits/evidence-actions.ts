"use server";

// Evidence actions (phase 8c): asking for a permit pack, and recording a correction beside a
// frozen record. The database decides who may do either and fixes what a pack holds; the pack
// itself is built by the pack builder service, which is asked to start straight away.

import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/components/ActionForm";
import { failure, run, text } from "@/lib/action-helpers";
import { write } from "@/lib/authz";
import { buildPacksNow } from "@/lib/job-runner";
import { supabaseServer } from "@/lib/supabase/server";

function withProblems(r: ActionResult): ActionResult {
  const x = r as { problems?: string[] } | null;
  return r && r.ok === false && x?.problems?.length ? { ...r, reason: `${r.reason} ${x.problems.join(" ")}` } : r;
}

export async function requestPack(_: ActionResult, f: FormData): Promise<ActionResult> {
  // Each thing left out carries its own reason, typed beside it.
  const omissions = f.getAll("omit").map(String).map((item) => ({ item, reason: text(f, `reason:${item}`) }));
  const db = await supabaseServer();
  try {
    const r = await write(db, "request_permit_pack", {
      p_idempotency_key: text(f, "key"), p_permit_id: text(f, "permit_id"), p_purpose: text(f, "purpose"),
      p_recipient: text(f, "recipient"), p_profile: text(f, "profile"), p_omissions: omissions,
    });
    if (!r.ok) return withProblems(r as ActionResult);
    let built = false;
    try {
      built = (await buildPacksNow()).built > 0;
    } catch (e) {
      // The scheduled run builds it instead; the request itself is recorded.
      console.error("pack build on request failed:", (e as Error).message);
    }
    revalidatePath("/", "layout");
    return { ok: true, message: `Pack ${String(r.reference ?? "")} ${r.replayed ? "was already requested" : "requested"}.`,
             detail: built ? "It is built and ready to download below." : "It will be built within a few minutes; refresh to download it." };
  } catch (e) {
    return failure(e);
  }
}

export async function recordCorrection(_: ActionResult, f: FormData): Promise<ActionResult> {
  const [targetType, targetId] = text(f, "target").split(":");
  return withProblems(await run("record_correction", {
    p_idempotency_key: text(f, "key"), p_target_type: targetType ?? "", p_target_id: targetId ?? "",
    p_about: text(f, "about"), p_was: text(f, "was"), p_corrected: text(f, "corrected"), p_reason: text(f, "reason"), p_evidence: text(f, "evidence"),
  }, "Correction recorded beside the record"));
}
