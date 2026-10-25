"use server";

// Learner actions: each calls one database function as the learner, with the request
// key chosen by the screen for that intent, so a double tap replays rather than repeats.

import { ConflictError, write } from "@/lib/authz";
import { supabaseServer } from "@/lib/supabase/server";

export type StepResult = { ok: true } | { ok: false; reason: string };

async function call(fn: string, args: Record<string, unknown> & { p_idempotency_key: string }): Promise<StepResult> {
  const db = await supabaseServer();
  try {
    const r = await write(db, fn, args);
    return r.ok ? { ok: true } : { ok: false, reason: r.reason };
  } catch (e) {
    if (e instanceof ConflictError) return { ok: false, reason: "This changed in another window. The page has been refreshed." };
    return { ok: false, reason: "Something went wrong saving that. Please try again." };
  }
}

export async function startInduction(key: string, courseId: string) {
  return call("start_induction", { p_idempotency_key: key, p_course_id: courseId });
}
export async function moduleEvent(key: string, attemptId: string, moduleKey: string, event: "start" | "complete") {
  return call("module_progress", { p_idempotency_key: key, p_attempt_id: attemptId, p_module_key: moduleKey, p_event: event });
}
export async function answerQuestion(key: string, attemptId: string, questionKey: string, optionKeys: string[]) {
  return call("answer_question", { p_idempotency_key: key, p_attempt_id: attemptId, p_question_key: questionKey, p_option_keys: optionKeys });
}
export async function finishAttempt(key: string, attemptId: string, version: number) {
  return call("finish_attempt", { p_idempotency_key: key, p_attempt_id: attemptId, p_expected_version: version });
}
export async function completeInduction(key: string, attemptId: string, version: number, confirmed: string[], typedName: string) {
  return call("complete_induction", {
    p_idempotency_key: key, p_attempt_id: attemptId, p_expected_version: version,
    p_confirmed_keys: confirmed, p_typed_name: typedName, p_drawn_signature: false,
  });
}
