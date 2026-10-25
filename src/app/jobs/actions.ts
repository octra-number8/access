"use server";

// A job's journey (phase 4b, D-017): describe it, answer the venue's screening, submit,
// then accept or challenge what was recommended. The database decides every step.

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import type { ActionResult } from "@/components/ActionForm";
import { failure, optional, run, text } from "@/lib/action-helpers";
import { write } from "@/lib/authz";
import { supabaseServer } from "@/lib/supabase/server";

function withProblems(r: ActionResult): ActionResult {
  const problems = (r as { problems?: string[] } | null)?.problems;
  return r && r.ok === false && Array.isArray(problems) ? { ...r, reason: `${r.reason} ${problems.join(" ")}` } : r;
}

/** Dates are whole days: the window runs from the start of the first day to the end of the last. */
function jobInput(f: FormData) {
  const from = text(f, "start");
  const to = text(f, "end");
  const end = to ? new Date(`${to}T00:00:00Z`) : null;
  if (end) end.setUTCDate(end.getUTCDate() + 1);
  return {
    title: text(f, "title"),
    scope: text(f, "scope"),
    method: optional(f, "method"),
    window_from: from ? `${from}T00:00:00Z` : null,
    window_to: end ? end.toISOString() : null,
    contact_person_id: text(f, "contact_person_id"),
    supervisor_person_id: optional(f, "supervisor_person_id"),
    area_ids: f.getAll("area_ids").map(String),
    system_ids: f.getAll("system_ids").map(String),
    parties: JSON.parse(text(f, "parties") || "[]"),
  };
}

export async function createJob(_: ActionResult, f: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  let id: string;
  try {
    const r = await write(db, "create_work_package", {
      p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"), p_engagement_id: text(f, "engagement_id"),
      p_work_type_id: text(f, "work_type_id"), p_input: jobInput(f),
    });
    if (!r.ok) return withProblems(r as ActionResult);
    id = r.id;
  } catch (e) {
    return failure(e);
  }
  revalidatePath("/", "layout");
  redirect(`/jobs/${id}`);
}

export async function reviseJob(_: ActionResult, f: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const r = await write(db, "revise_work_package", {
      p_idempotency_key: text(f, "key"), p_work_package_id: text(f, "work_package_id"),
      p_expected_version: Number(text(f, "row_version")), p_input: jobInput(f), p_reason: text(f, "reason"),
    });
    if (!r.ok) return withProblems(r as ActionResult);
    revalidatePath("/", "layout");
    return r.change_kind === "material"
      ? { ok: true, message: "Change saved.", detail: "It changes what the job is, so any screening result was replaced and the job needs screening again." }
      : { ok: true, message: "Correction saved.", detail: "It does not change what the job is, so its screening stands." };
  } catch (e) {
    return failure(e);
  }
}

export type StepResult = { ok: true } | { ok: false; reason: string; problems?: string[] } | null;

/** Saves the answers so far; the journey calls it on every step so nothing is lost. */
export async function saveAnswers(workPackageId: string, key: string, answers: Record<string, string[]>,
                                  selected: string[]): Promise<StepResult> {
  const db = await supabaseServer();
  try {
    const r = await write(db, "save_screening_answers", { p_idempotency_key: key, p_work_package_id: workPackageId,
      p_answers: answers, p_selected_class_ids: selected });
    return r.ok ? { ok: true } : { ok: false, reason: r.reason };
  } catch (e) {
    const x = failure(e);
    return { ok: false, reason: x && x.ok === false ? x.reason : "Not saved." };
  }
}

export async function submitJob(workPackageId: string, key: string, expectedVersion: number): Promise<StepResult> {
  const db = await supabaseServer();
  try {
    const r = await write(db, "submit_work_package", { p_idempotency_key: key, p_work_package_id: workPackageId,
      p_expected_version: expectedVersion });
    if (!r.ok) return { ok: false, reason: r.reason, problems: (r as { problems?: string[] }).problems };
  } catch (e) {
    const x = failure(e);
    return { ok: false, reason: x && x.ok === false ? x.reason : "Not submitted." };
  }
  revalidatePath("/", "layout");
  return { ok: true };
}

export async function cancelJob(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("cancel_work_package", { p_idempotency_key: text(f, "key"), p_work_package_id: text(f, "work_package_id"),
    p_expected_version: Number(text(f, "row_version")), p_reason: text(f, "reason") }, "Job cancelled");
}

export async function acceptRecommendation(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("accept_recommendation", { p_idempotency_key: text(f, "key"), p_recommendation_id: text(f, "recommendation_id"),
    p_expected_version: Number(text(f, "row_version")) }, "Accepted");
}

export async function challengeRecommendation(_: ActionResult, f: FormData): Promise<ActionResult> {
  return withProblems(await run("challenge_recommendation", { p_idempotency_key: text(f, "key"),
    p_recommendation_id: text(f, "recommendation_id"), p_expected_version: Number(text(f, "row_version")),
    p_reason: text(f, "reason"), p_document_version_ids: f.getAll("document_version_ids").map(String) },
    "Challenge sent to the venue's authority"));
}

export async function addExternalEvidence(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("add_external_evidence", {
    p_idempotency_key: text(f, "key"), p_hold_id: text(f, "hold_id"), p_external_decider: text(f, "decider"),
    p_external_organisation: text(f, "organisation"), p_reference: optional(f, "reference"), p_scope: text(f, "scope"),
    p_decided_on: text(f, "decided_on"), p_conditions: optional(f, "conditions"),
    p_document_version_ids: f.getAll("document_version_ids").map(String),
  }, "Evidence added");
}
