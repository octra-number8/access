"use server";

// The venue's permit set-up (phase 5c, D-018): class configurations (approved by the
// technical authority from the decisions page), the working calendar, restriction
// windows and the area occupation register. Every change is decided by the database.

import type { ActionResult } from "@/components/ActionForm";
import { failure, optional, run, text } from "@/lib/action-helpers";
import { type ClassConfig, fromVenueLocal, type RouteStep } from "@/lib/permits";
import { answersOf, slug } from "@/lib/screening/content";
import { supabaseServer } from "@/lib/supabase/server";

function withProblems(r: ActionResult): ActionResult {
  const problems = (r as { problems?: string[] } | null)?.problems;
  return r && r.ok === false && Array.isArray(problems) ? { ...r, reason: `${r.reason} ${problems.join(" ")}` } : r;
}

export async function startClassDraft(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_class_draft", { p_idempotency_key: text(f, "key"), p_permit_class_id: text(f, "class_id") }, "Draft started");
}

export async function createWorkApprovalClass(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_work_approval_class", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"),
    p_code: text(f, "code").toUpperCase(), p_name: text(f, "name") }, "Work Approval class added");
}

export async function proposeClass(_: ActionResult, f: FormData): Promise<ActionResult> {
  return withProblems(await run("propose_class_version", { p_idempotency_key: text(f, "key"), p_version_id: text(f, "version_id"),
    p_expected_version: Number(text(f, "row_version")) }, "Proposed. The technical authority decides it from their decisions page"));
}

async function save(versionId: string, key: string, change: (c: ClassConfig) => ClassConfig | string, done: string): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const { data } = await db.from("permit_class_version").select("content, row_version, source_ref").eq("id", versionId).single();
    const next = change(structuredClone(data!.content as ClassConfig));
    if (typeof next === "string") return { ok: false, code: "invalid_content", reason: next, missing: "A valid change", resolvable_by: "You" };
    return withProblems(await run("save_class_draft", { p_idempotency_key: key, p_version_id: versionId,
      p_expected_version: data!.row_version, p_content: next, p_source_ref: data!.source_ref }, done));
  } catch (e) {
    return failure(e);
  }
}

const lines = (v: string) => v.split("\n").map((s) => s.trim()).filter(Boolean);
const choice = (v: string) => (v === "yes" ? true : v === "no" ? false : undefined);

/** Saves everything except the questions: route, declarations, notice, evidence and flags. */
export async function saveClassSettings(_: ActionResult, f: FormData): Promise<ActionResult> {
  return save(text(f, "version_id"), text(f, "key"), (c) => {
    const route: RouteStep[] = JSON.parse(text(f, "route") || "[]");
    const notice = text(f, "notice_amount") === "" ? undefined : {
      amount: Number(text(f, "notice_amount")),
      unit: text(f, "notice_unit") as NonNullable<ClassConfig["notice"]>["unit"],
      cutoff_applies: text(f, "cutoff_applies") === "yes",
      restart_on_resubmission: text(f, "restart") === "yes",
    };
    if (notice && (text(f, "cutoff_applies") === "" || text(f, "restart") === "")) {
      return "Choose whether the cut-off applies and whether a resubmission restarts the notice.";
    }
    const next: ClassConfig = {
      ...c, route,
      submission_declaration: lines(text(f, "submission_declaration")),
      acceptance_declaration: lines(text(f, "acceptance_declaration")),
      evidence: { induction_course_ids: f.getAll("induction_course_ids").map(String),
                  team_competency_type_ids: f.getAll("team_competency_type_ids").map(String),
                  supervisor_competency_type_ids: f.getAll("supervisor_competency_type_ids").map(String) },
    };
    const controls = choice(text(f, "requires_physical_controls"));
    const prohibited = choice(text(f, "override_prohibited"));
    if (controls === undefined) delete next.requires_physical_controls; else next.requires_physical_controls = controls;
    if (prohibited === undefined) delete next.override_prohibited; else next.override_prohibited = prohibited;
    if (notice) next.notice = notice; else delete next.notice;
    // Live rules (P6-5 to P6-7): left blank means not chosen; the database refuses approval until each is.
    const count = text(f, "extension_count"), hours = text(f, "extension_hours");
    if (count === "" && hours === "") delete next.extension;
    else if (count === "" || hours === "") return "Give both the number of extensions and the total hours (zero for none).";
    else next.extension = { max_count: Number(count), max_total_hours: Number(hours) };
    const add = text(f, "worker_add");
    if (add === "supervisor" || add === "issuer_approval") next.worker_add = add; else delete next.worker_add;
    const reval = text(f, "revalidation");
    if (reval === "none") next.revalidation = { mode: "none" };
    else if (reval === "interval") {
      if (text(f, "revalidation_hours") === "") return "Say how many hours apart revalidation is needed.";
      next.revalidation = { mode: "interval", every_hours: Number(text(f, "revalidation_hours")) };
    } else delete next.revalidation;
    return next;
  }, "Saved");
}

export async function addClassQuestion(_: ActionResult, f: FormData): Promise<ActionResult> {
  return save(text(f, "version_id"), text(f, "key"), (c) => {
    const wording = text(f, "text");
    if (!wording) return "Write the question.";
    const type = text(f, "type") as "yes_no" | "choose_one" | "choose_many";
    const q: ClassConfig["questions"][number] = { key: slug(wording, c.questions.map((x) => x.key)), text: wording, type };
    if (optional(f, "help")) q.help = text(f, "help");
    if (type !== "yes_no") {
      const opts = lines(text(f, "options"));
      if (opts.length < 2) return "List at least two answers, one per line.";
      const keys: string[] = [];
      q.options = opts.map((o) => { const k = slug(o, keys); keys.push(k); return { key: k, text: o }; });
    }
    const dep = optional(f, "show_if_question");
    if (dep) {
      const answers = f.getAll("show_if_answer").map(String).filter((a) => {
        const d = c.questions.find((x) => x.key === dep);
        return d && answersOf(d).some((o) => o.key === a);
      });
      if (answers.length === 0) return "Choose which earlier answers make this question appear.";
      q.show_if = { question: dep, answers };
    }
    c.questions.push(q);
    return c;
  }, "Question added");
}

export async function removeClassQuestion(_: ActionResult, f: FormData): Promise<ActionResult> {
  const qk = text(f, "question_key");
  return save(text(f, "version_id"), text(f, "key"), (c) => {
    if (c.questions.some((q) => q.show_if?.question === qk)) return "Another question depends on this one. Remove that first.";
    c.questions = c.questions.filter((q) => q.key !== qk);
    return c;
  }, "Question removed");
}

// ---- Calendar, restrictions and occupation --------------------------------------------------

export async function publishCalendar(_: ActionResult, f: FormData): Promise<ActionResult> {
  const closures = text(f, "closures").split(/[\s,]+/).filter(Boolean);
  if (closures.some((d) => !/^\d{4}-\d{2}-\d{2}$/.test(d))) {
    return { ok: false, code: "invalid_content", reason: "Write closure dates as YYYY-MM-DD, separated by commas.", missing: "Valid dates", resolvable_by: "You" };
  }
  return run("publish_venue_calendar", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"),
    p_working_weekdays: f.getAll("weekdays").map(Number), p_closures: closures, p_cutoff_time: optional(f, "cutoff"),
    p_effective_from: optional(f, "effective_from") ? fromVenueLocal(text(f, "effective_from"), text(f, "tz")) : null,
    p_change_reason: text(f, "reason") }, "Calendar published");
}

export async function createRestriction(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_restriction_window", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"),
    p_area_ids: f.getAll("area_ids").map(String), p_effect: text(f, "effect"), p_reason: text(f, "reason"),
    p_from: optional(f, "from") ? fromVenueLocal(text(f, "from"), text(f, "tz")) : null,
    p_to: optional(f, "to") ? fromVenueLocal(text(f, "to"), text(f, "tz")) : null,
    p_event_phase_id: optional(f, "event_phase_id") }, "Restriction recorded");
}

export async function endRestriction(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("end_restriction_window", { p_idempotency_key: text(f, "key"), p_window_id: text(f, "window_id") }, "Restriction ended");
}

export async function recordOccupation(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("record_area_occupation", { p_idempotency_key: text(f, "key"), p_area_id: text(f, "area_id"),
    p_organisation_id: text(f, "organisation_id"), p_valid_from: fromVenueLocal(`${text(f, "from")}T00:00`, text(f, "tz")),
    p_valid_to: optional(f, "to") ? fromVenueLocal(`${text(f, "to")}T00:00`, text(f, "tz")) : null, p_evidence_ref: optional(f, "evidence_ref") },
    "Occupation recorded");
}
