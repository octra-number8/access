"use server";

// Access visits (phase 7c, D-020). Each action calls one database function as the signed-in
// user; the database decides who may ask, consent, approve, change or cancel.

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import type { ActionResult } from "@/components/ActionForm";
import { failure, run, text } from "@/lib/action-helpers";
import { write } from "@/lib/authz";
import { fromVenueLocal } from "@/lib/permits";
import { supabaseServer } from "@/lib/supabase/server";

function withProblems(r: ActionResult): ActionResult {
  const problems = (r as { problems?: string[] } | null)?.problems;
  return r && r.ok === false && Array.isArray(problems) ? { ...r, reason: `${r.reason} ${problems.join(" ")}` } : r;
}

export async function requestAccess(_: ActionResult, f: FormData): Promise<ActionResult> {
  const tz = text(f, "tz");
  const db = await supabaseServer();
  let id: string;
  try {
    const r = await write(db, "request_access", {
      p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"), p_organisation_id: text(f, "organisation_id"),
      p_purpose_key: text(f, "purpose_key"), p_description: text(f, "description"), p_area_ids: f.getAll("area_ids").map(String),
      p_from: text(f, "from") ? fromVenueLocal(text(f, "from"), tz) : null, p_to: text(f, "to") ? fromVenueLocal(text(f, "to"), tz) : null,
      p_person_ids: f.getAll("person_ids").map(String),
    });
    if (!r.ok) return withProblems(r as ActionResult);
    id = r.id;
  } catch (e) {
    return failure(e);
  }
  revalidatePath("/", "layout");
  redirect(`/visits/${id}`);
}

export async function consentAccess(_: ActionResult, f: FormData): Promise<ActionResult> {
  const outcome = text(f, "outcome");
  return run("consent_access", { p_idempotency_key: text(f, "key"), p_authorisation_id: text(f, "id"), p_area_id: text(f, "area_id"),
    p_organisation_id: text(f, "organisation_id"), p_outcome: outcome, p_reason: text(f, "reason") },
    outcome === "given" ? "Consent recorded" : "Refusal recorded. The visit cannot be approved as asked");
}

export async function decideAccess(_: ActionResult, f: FormData): Promise<ActionResult> {
  const outcome = text(f, "outcome");
  const conditions = outcome === "approve"
    ? { escort: text(f, "escort") || null, no_photography: f.get("no_photography") === "on", confidentiality: f.get("confidentiality") === "on",
        other: text(f, "other") || null }
    : {};
  return run("decide_access", { p_idempotency_key: text(f, "key"), p_authorisation_id: text(f, "id"), p_expected_version: Number(text(f, "row_version")),
    p_outcome: outcome, p_reason: text(f, "reason"), p_conditions: conditions }, outcome === "approve" ? "Visit approved" : "Visit refused");
}

export async function changeRoster(_: ActionResult, f: FormData): Promise<ActionResult> {
  return withProblems(await run("change_access_roster", { p_idempotency_key: text(f, "key"), p_authorisation_id: text(f, "id"),
    p_add_person_ids: f.getAll("add").map(String), p_remove_member_ids: f.getAll("remove").map(String), p_reason: text(f, "reason") },
    "Roster changed. Removals apply now; anyone added to an approved visit needs approving"));
}

export async function approveAddition(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("approve_roster_addition", { p_idempotency_key: text(f, "key"), p_member_id: text(f, "member_id") }, "Addition approved");
}

export async function cancelAccess(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("cancel_access", { p_idempotency_key: text(f, "key"), p_authorisation_id: text(f, "id"),
    p_expected_version: Number(text(f, "row_version")), p_reason: text(f, "reason") }, "Done. The visit is no longer a reason to enter");
}

export async function linkWorkRequest(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("link_work_request", { p_idempotency_key: text(f, "key"), p_authorisation_id: text(f, "id"),
    p_work_package_id: text(f, "work_package_id") }, "Job linked to the visit. It follows the normal screening and permit route");
}
