// Activity screening content (phase 4, D-017): the shape stored per screening version
// and validated by core.validate_screening_content. The database decides what a set of
// answers recommends (core.screening_matches); this module only describes and edits it.

export type QuestionType = "yes_no" | "choose_one" | "choose_many";

export interface ScreeningQuestion {
  key: string;
  text: string;
  help?: string;
  type: QuestionType;
  options?: Array<{ key: string; text: string }>;
  show_if?: { question: string; answers: string[] };
}

export interface ScreeningRule {
  key: string;
  all: Array<{ question: string; answers: string[] }>;
  permit_class_id: string;
  rationale: string;
}

export interface ScreeningContent {
  questions: ScreeningQuestion[];
  rules: ScreeningRule[];
}

export const EMPTY_CONTENT: ScreeningContent = { questions: [], rules: [] };

export function answersOf(q: ScreeningQuestion): Array<{ key: string; text: string }> {
  return q.type === "yes_no" ? [{ key: "yes", text: "Yes" }, { key: "no", text: "No" }] : (q.options ?? []);
}

/** Whether a question applies, given the answers so far (mirrors show_if; the database re-checks). */
export function isShown(q: ScreeningQuestion, answers: Record<string, string[]>): boolean {
  if (!q.show_if) return true;
  const given = answers[q.show_if.question] ?? [];
  return given.some((a) => q.show_if!.answers.includes(a));
}

export function slug(text: string, taken: string[]): string {
  const base = text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "item";
  let key = base;
  for (let n = 2; taken.includes(key); n += 1) key = `${base}-${n}`;
  return key;
}
