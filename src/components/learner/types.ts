// What api.learner_course returns (migration 0025). Correct answers are never included.

export type LearnerBlock =
  | { type: "rich_text"; text: string }
  | { type: "callout"; text: string; tone?: "info" | "warning" | "risk" }
  | { type: "image"; media_id: string | null; alt: string | null; decorative?: boolean }
  | { type: "video"; media_id: string | null; caption_media_id: string | null; transcript: string | null }
  | { type: "document"; media_id: string | null; title: string };

export interface LearnerModule { key: string; title: string; kind: string; min_seconds: number; blocks: LearnerBlock[] }
export interface LearnerQuestion {
  key: string; placement: "module" | "final"; module_key: string | null;
  type: "single_choice" | "multiple_select" | "true_false"; stem: string; options: Array<{ key: string; text: string }>;
}
export interface WrongAnswer { question_key: string; stem: string; explanation: string; module_key: string | null; safety_critical: boolean }

export interface LearnerCourse {
  ok: true;
  server_now: string;
  course_id: string;
  title: string;
  version_id: string;
  version_no: number;
  settings: {
    pass_mark_percent: number; all_critical_required: boolean; max_attempts: number;
    retry_delay_minutes: number; shuffle_options: boolean; signature_mode: "typed" | "typed_or_drawn";
  };
  learner: { given_name: string; family_name: string };
  content: { modules: LearnerModule[]; questions: LearnerQuestion[]; declaration: Array<{ key: string; text: string }> };
  attempts_left: number;
  retry_from: string | null;
  attempt: null | {
    id: string; status: "in_progress" | "passed" | "failed" | "completed"; row_version: number;
    score_percent: number | null; critical_missed: number | null;
    modules: Record<string, { started_at: string; completed_at: string | null }>;
    answered: string[];
    wrong: WrongAnswer[] | null;
  };
  completion: null | { id: string; completed_at: string; valid_until: string; method: string; invalidated_for: string | null };
}
