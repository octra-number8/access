"use server";

// Entry set-up (phase 7c, D-020): entry rules, gate points, visit purposes and card passes.
// Rules and purposes are drafted and proposed by the venue and approved by an appointed
// access authority who did not write them. Nothing has a default; the database validates.

import type { ActionResult } from "@/components/ActionForm";
import { failure, run, text } from "@/lib/action-helpers";
import { write } from "@/lib/authz";
import type { Purpose } from "@/lib/gate";
import { slug } from "@/lib/screening/content";
import { supabaseServer } from "@/lib/supabase/server";

export interface Audience {
  key: string; name: string; capacities: string[]; relationship_kinds: string[]; event_phase: string | null;
  induction_course_ids: string[]; escort: "never" | "always"; area_ids: string[];
}
export interface EntryRules { audiences: Audience[]; never_overridable?: string[] }
type Kind = "entry" | "venue_config";

const invalid = (reason: string): ActionResult => ({ ok: false, code: "invalid_content", reason, missing: "A valid change", resolvable_by: "You" });

function withProblems(r: ActionResult): ActionResult {
  const problems = (r as { problems?: string[] } | null)?.problems;
  return r && r.ok === false && Array.isArray(problems) ? { ...r, reason: `${r.reason} ${problems.join(" ")}` } : r;
}

async function save<T>(kind: Kind, versionId: string, key: string, change: (c: T) => T | string, done: string): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const { data } = await db.from(kind === "entry" ? "entry_rule_version" : "venue_config_version")
      .select("content, row_version, source_ref").eq("id", versionId).single();
    const next = change(structuredClone(data!.content as T));
    if (typeof next === "string") return invalid(next);
    return withProblems(await run(kind === "entry" ? "save_entry_rule_draft" : "save_venue_config_draft", { p_idempotency_key: key,
      p_version_id: versionId, p_expected_version: data!.row_version, p_content: next, p_source_ref: data!.source_ref }, done));
  } catch (e) {
    return failure(e);
  }
}

/** "None" must be chosen, not implied by leaving every box empty (no silent default). */
function inductions(f: FormData): string[] | string {
  const choice = text(f, "inductions");
  if (choice === "none") return [];
  if (choice !== "listed") return "Say which inductions are needed, or that none is.";
  const ids = f.getAll("induction_course_ids").map(String);
  return ids.length ? ids : "Tick the inductions needed, or choose none.";
}

// ---- Entry rules (P7-2) --------------------------------------------------------------------------
export async function startEntryDraft(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_entry_rule_draft", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id") }, "Draft started");
}

export async function saveAudience(_: ActionResult, f: FormData): Promise<ActionResult> {
  const ind = inductions(f);
  if (typeof ind === "string") return invalid(ind);
  const phase = text(f, "event_phase");
  if (!phase) return invalid("Say whether this audience applies only in an event phase, or always.");
  return save<EntryRules>("entry", text(f, "version_id"), text(f, "key"), (c) => {
    const existing = text(f, "audience_key");
    const audience: Audience = {
      key: existing || slug(text(f, "name"), c.audiences.map((a) => a.key)),
      name: text(f, "name"), capacities: f.getAll("capacities").map(String), relationship_kinds: f.getAll("relationship_kinds").map(String),
      event_phase: phase === "always" ? null : phase, induction_course_ids: ind, escort: text(f, "escort") as Audience["escort"],
      area_ids: f.getAll("area_ids").map(String),
    };
    c.audiences = existing ? c.audiences.map((a) => (a.key === existing ? audience : a)) : [...c.audiences, audience];
    return c;
  }, "Audience saved");
}

export async function removeAudience(_: ActionResult, f: FormData): Promise<ActionResult> {
  return save<EntryRules>("entry", text(f, "version_id"), text(f, "key"), (c) => ({ ...c, audiences: c.audiences.filter((a) => a.key !== text(f, "audience_key")) }),
    "Audience removed");
}

export async function saveNeverOverridable(_: ActionResult, f: FormData): Promise<ActionResult> {
  return save<EntryRules>("entry", text(f, "version_id"), text(f, "key"), (c) => ({ ...c, never_overridable: f.getAll("codes").map(String) }),
    "Saved");
}

export async function proposeEntryRules(_: ActionResult, f: FormData): Promise<ActionResult> {
  return withProblems(await run("propose_entry_rule_version", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
    p_expected_version: Number(text(f, "row_version")) }, "Proposed. An access authority decides it from their decisions page"));
}

export async function decideEntryRules(_: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = text(f, "decision") === "approve";
  return run("decide_entry_rule_version", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
    p_expected_version: Number(text(f, "row_version")), p_decision: approve ? "approve" : "reject", p_reason: text(f, "reason") },
    approve ? "Entry rules approved; the gate uses them from now on" : "Entry rules rejected");
}

// ---- Gate points ---------------------------------------------------------------------------------
export async function createGatePoint(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_gate_point", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"), p_area_id: text(f, "area_id"),
    p_name: text(f, "name") }, "Gate point added");
}

// ---- Visit purposes (Q121, Q162) -------------------------------------------------------------------
export async function startPurposesDraft(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_venue_config_draft", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"), p_kind: "access_purposes" },
    "Draft started");
}

export async function savePurpose(_: ActionResult, f: FormData): Promise<ActionResult> {
  const ind = inductions(f);
  if (typeof ind === "string") return invalid(ind);
  const consent = text(f, "occupier_consent");
  if (!consent) return invalid("Choose whether the occupier of an area must consent.");
  return save<{ purposes: Purpose[] }>("venue_config", text(f, "version_id"), text(f, "key"), (c) => {
    const existing = text(f, "purpose_key");
    const purposes = c.purposes ?? [];
    const purpose: Purpose = {
      key: existing || slug(text(f, "name"), purposes.map((p) => p.key)), name: text(f, "name"), allows: text(f, "allows"),
      prohibits: text(f, "prohibits"), induction_course_ids: ind, escort: text(f, "escort") as Purpose["escort"], occupier_consent: consent === "yes",
    };
    return { ...c, purposes: existing ? purposes.map((p) => (p.key === existing ? purpose : p)) : [...purposes, purpose] };
  }, "Purpose saved");
}

export async function removePurpose(_: ActionResult, f: FormData): Promise<ActionResult> {
  return save<{ purposes: Purpose[] }>("venue_config", text(f, "version_id"), text(f, "key"),
    (c) => ({ ...c, purposes: (c.purposes ?? []).filter((p) => p.key !== text(f, "purpose_key")) }), "Purpose removed");
}

export async function proposePurposes(_: ActionResult, f: FormData): Promise<ActionResult> {
  return withProblems(await run("propose_venue_config", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
    p_expected_version: Number(text(f, "row_version")) }, "Proposed. An access authority decides it from their decisions page"));
}

export async function decidePurposes(_: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = text(f, "decision") === "approve";
  return run("decide_venue_config", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
    p_expected_version: Number(text(f, "row_version")), p_decision: approve ? "approve" : "reject", p_reason: text(f, "reason") },
    approve ? "Visit purposes approved; visits can be asked for under them" : "Visit purposes rejected");
}

// ---- Card passes (P7-3, 6b-2) --------------------------------------------------------------------
export type IssuedCard = { ok: true; message: string; pass_number: string; payload: string; person: string; venue: string } | ActionResult;

/** The card's code is returned once, for printing; only its hash is kept. */
export async function issueCard(_: IssuedCard, f: FormData): Promise<IssuedCard> {
  const db = await supabaseServer();
  try {
    const r = await write(db, "issue_card_pass", { p_idempotency_key: text(f, "key"), p_person_id: text(f, "person_id"), p_venue_id: text(f, "venue_id") });
    if (!r.ok) return r as ActionResult;
    const x = r as unknown as { pass_number: string; payload?: string };
    if (!x.payload) {
      return { ok: false, code: "replayed", reason: "This card was already issued, and its code is shown only once.", missing: "A new card",
               resolvable_by: "You: revoke this card and issue another" };
    }
    const [{ data: person }, { data: venue }] = await Promise.all([
      db.from("person").select("given_name, family_name").eq("id", text(f, "person_id")).single(),
      db.from("venue").select("name").eq("id", text(f, "venue_id")).single(),
    ]);
    return { ok: true, message: `Card ${x.pass_number} issued`, pass_number: x.pass_number, payload: x.payload,
             person: person ? `${person.given_name} ${person.family_name}` : "", venue: venue?.name ?? "" };
  } catch (e) {
    return failure(e);
  }
}

export async function revokePass(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("revoke_pass", { p_idempotency_key: text(f, "key"), p_pass_id: text(f, "pass_id"), p_reason: text(f, "reason") },
    "Pass revoked. It is refused at every gate from now on");
}

// ---- Outage procedure (Q198, Q199, Q201, P7-10) ------------------------------------------------------
export interface OutageProcedure { instruction?: string; steps: string[]; manifest_max_age_minutes?: number; manifest_refresh_minutes?: number }

export async function startOutageDraft(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_venue_config_draft", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"), p_kind: "outage_procedure" },
    "Draft started");
}

export async function saveOutage(_: ActionResult, f: FormData): Promise<ActionResult> {
  const age = text(f, "max_age");
  const refresh = text(f, "refresh");
  if (age !== "" && !/^\d+$/.test(age)) return invalid("The manifest's maximum age is a whole number of minutes.");
  if (refresh !== "" && !/^\d+$/.test(refresh)) return invalid("Automatic refresh is a whole number of minutes.");
  return save<OutageProcedure>("venue_config", text(f, "version_id"), text(f, "key"), (c) => {
    const next: OutageProcedure = { ...c, instruction: text(f, "instruction"), steps: text(f, "steps").split("\n").map((s) => s.trim()).filter(Boolean) };
    if (age === "") delete next.manifest_max_age_minutes; else next.manifest_max_age_minutes = Number(age);
    if (refresh === "") delete next.manifest_refresh_minutes; else next.manifest_refresh_minutes = Number(refresh);
    return next;
  }, "Outage procedure saved");
}

export async function decideOutage(_: ActionResult, f: FormData): Promise<ActionResult> {
  const approve = text(f, "decision") === "approve";
  return run("decide_venue_config", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
    p_expected_version: Number(text(f, "row_version")), p_decision: approve ? "approve" : "reject", p_reason: text(f, "reason") },
    approve ? "Outage procedure approved; gate devices can now keep a manifest" : "Outage procedure rejected");
}
