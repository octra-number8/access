"use server";

// Authoring the venue's activity screening (phase 4b, D-017). Every change is saved
// through api.save_screening_draft, which validates it; approval is the technical
// authority's decision, made from the decisions page.

import type { ActionResult } from "@/components/ActionForm";
import { failure, optional, run, text } from "@/lib/action-helpers";
import { answersOf, type ScreeningContent, slug } from "@/lib/screening/content";
import { STARTER_SOURCE, starterFor } from "@/lib/screening/starter";
import { supabaseServer } from "@/lib/supabase/server";

export async function createPermitClass(_: ActionResult, f: FormData): Promise<ActionResult> {
  const external = text(f, "handling") === "external_reference";
  return run(external ? "create_external_class" : "create_permit_class",
    { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"), p_code: text(f, "code").toUpperCase(), p_name: text(f, "name") },
    external ? "Specialist class added (handled by external reference)" : "Permit class added");
}

export async function createWorkType(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_work_type", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id"),
    p_code: text(f, "code"), p_label: text(f, "label") }, "Work type added");
}

export async function startScreeningDraft(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_screening_draft", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id") }, "Draft started");
}

export async function proposeScreening(_: ActionResult, f: FormData): Promise<ActionResult> {
  return withProblems(await run("propose_screening_version", { p_idempotency_key: text(f, "key"),
    p_version_id: text(f, "version_id"), p_expected_version: Number(text(f, "row_version")) },
    "Proposed. The venue's technical authority decides it from their decisions page"));
}

// ---- Editing the draft's content ---------------------------------------------------------

async function draft(versionId: string) {
  const db = await supabaseServer();
  const { data } = await db.from("screening_set_version").select("id, content, row_version, source_ref, status").eq("id", versionId).single();
  return data as { id: string; content: ScreeningContent; row_version: number; source_ref: string | null; status: string };
}

function withProblems(r: ActionResult): ActionResult {
  if (r && r.ok === false && Array.isArray((r as { problems?: string[] }).problems)) {
    return { ...r, reason: `${r.reason} ${(r as unknown as { problems: string[] }).problems.join(" ")}` };
  }
  return r;
}

async function save(versionId: string, key: string, change: (c: ScreeningContent) => ScreeningContent | string,
                    done: string, sourceRef?: string | null): Promise<ActionResult> {
  try {
    const d = await draft(versionId);
    const next = change(structuredClone(d.content));
    if (typeof next === "string") return { ok: false, code: "invalid_content", reason: next, missing: "A valid change", resolvable_by: "You" };
    return withProblems(await run("save_screening_draft", { p_idempotency_key: key, p_version_id: versionId,
      p_expected_version: d.row_version, p_content: next, p_source_ref: sourceRef === undefined ? d.source_ref : sourceRef }, done));
  } catch (e) {
    return failure(e);
  }
}

/** P4-2: replaces the draft with the starter set, mapped onto this venue's classes. */
export async function loadStarter(_: ActionResult, f: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  const { data: classes } = await db.from("permit_class").select("id, code, handling, retired_at").eq("venue_id", text(f, "venue_id"));
  const { content, missing } = starterFor(classes ?? []);
  const r = await save(text(f, "version_id"), text(f, "key"), () => content, "Starter set loaded as a draft", STARTER_SOURCE);
  if (r?.ok && missing.length > 0) {
    return { ok: true, message: "Starter set loaded as a draft.",
      detail: `${missing.length} of its rules were left out because the venue has no class for them yet: ${missing.map((m) => `${m.code} (${m.name}${m.handling === "external_reference" ? ", specialist" : ""})`).join(", ")}. Add those classes, then load it again, or write your own rules.` };
  }
  return r;
}

export async function addQuestion(_: ActionResult, f: FormData): Promise<ActionResult> {
  return save(text(f, "version_id"), text(f, "key"), (c) => {
    const wording = text(f, "text");
    if (!wording) return "Write the question.";
    const type = text(f, "type") as "yes_no" | "choose_one" | "choose_many";
    const options = text(f, "options").split("\n").map((s) => s.trim()).filter(Boolean);
    const question: ScreeningContent["questions"][number] = { key: slug(wording, c.questions.map((q) => q.key)), text: wording, type };
    if (optional(f, "help")) question.help = text(f, "help");
    if (type !== "yes_no") {
      if (options.length < 2) return "List at least two answers, one per line.";
      const keys: string[] = [];
      question.options = options.map((o) => { const k = slug(o, keys); keys.push(k); return { key: k, text: o }; });
    }
    const dep = optional(f, "show_if_question");
    if (dep) {
      const answers = f.getAll("show_if_answer").map(String);
      if (answers.length === 0) return "Choose which earlier answers make this question appear.";
      question.show_if = { question: dep, answers };
    }
    c.questions.push(question);
    return c;
  }, "Question added");
}

export async function removeQuestion(_: ActionResult, f: FormData): Promise<ActionResult> {
  const qk = text(f, "question_key");
  return save(text(f, "version_id"), text(f, "key"), (c) => {
    if (c.rules.some((r) => r.all.some((x) => x.question === qk)) || c.questions.some((q) => q.show_if?.question === qk)) {
      return "Other questions or rules depend on this question. Remove those first.";
    }
    c.questions = c.questions.filter((q) => q.key !== qk);
    return c;
  }, "Question removed");
}

export async function addRule(_: ActionResult, f: FormData): Promise<ActionResult> {
  return save(text(f, "version_id"), text(f, "key"), (c) => {
    const conditions = [1, 2].flatMap((n) => {
      const q = optional(f, `q${n}`);
      const answers = f.getAll(`a${n}`).map(String).filter((a) => {
        const question = c.questions.find((x) => x.key === q);
        return question && answersOf(question).some((o) => o.key === a);
      });
      return q ? [{ question: q, answers }] : [];
    });
    if (conditions.length === 0) return "Choose the question that triggers this rule.";
    if (conditions.some((x) => x.answers.length === 0)) return "Choose the answers that trigger each condition.";
    const rationale = text(f, "rationale");
    if (!rationale) return "Explain, in plain English, why this answer means the permit is needed.";
    c.rules.push({ key: slug(`r ${text(f, "class_label")} ${conditions.map((x) => x.question).join(" ")}`, c.rules.map((r) => r.key)),
                   all: conditions, permit_class_id: text(f, "permit_class_id"), rationale });
    return c;
  }, "Rule added");
}

export async function removeRule(_: ActionResult, f: FormData): Promise<ActionResult> {
  const rk = text(f, "rule_key");
  return save(text(f, "version_id"), text(f, "key"), (c) => ({ ...c, rules: c.rules.filter((r) => r.key !== rk) }), "Rule removed");
}

// ---- Preview -------------------------------------------------------------------------------

export type PreviewResult =
  | { ok: true; problems: string[]; matches: Array<{ rule_key: string; class_name: string; handling: string; rationale: string }> }
  | { ok: false; reason: string }
  | null;

export async function previewScreening(_: PreviewResult, f: FormData): Promise<PreviewResult> {
  const answers: Record<string, string[]> = {};
  for (const [k, v] of f.entries()) {
    if (k.startsWith("ans_") && String(v)) (answers[k.slice(4)] ??= []).push(String(v));
  }
  const db = await supabaseServer();
  const { data, error } = await db.rpc("preview_screening", { p_version_id: text(f, "version_id"), p_answers: answers });
  if (error || !data?.ok) return { ok: false, reason: data?.reason ?? "The preview could not run." };
  return data as PreviewResult;
}
