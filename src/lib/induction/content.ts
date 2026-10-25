// The course-version content format (D-015): OCTRA Induct's sections/blocks/questions/
// declaration, as stored per version and validated by core.validate_course_content.

export type ModuleKind = "core" | "role" | "area" | "event_phase";

export type Block =
  | { type: "rich_text"; text: string }
  | { type: "callout"; text: string; tone?: "info" | "warning" | "risk" }
  | { type: "image"; media_id: string | null; alt: string | null; decorative?: boolean; source_file?: string }
  | { type: "video"; media_id: string | null; caption_media_id: string | null; transcript: string | null }
  | { type: "document"; media_id: string | null; title: string };

export interface Module {
  key: string;
  title: string;
  kind: ModuleKind;
  min_seconds: number;
  blocks: Block[];
}

export interface Option {
  key: string;
  text: string;
  correct: boolean;
}

export interface Question {
  key: string;
  placement: "module" | "final";
  module_key: string | null;
  type: "single_choice" | "multiple_select" | "true_false";
  stem: string;
  explanation: string;
  safety_critical: boolean;
  weight: number;
  options: Option[];
}

export interface DeclarationItem {
  key: string;
  text: string;
}

export interface CourseContent {
  modules: Module[];
  questions: Question[];
  declaration: DeclarationItem[];
}

/** What an import produces. Imports always become drafts; open points block publication. */
export interface ImportResult {
  title: string | null;
  content: CourseContent;
  openPoints: Array<{ text: string; owner: string | null }>;
  /** Image files referenced by the source, to upload and attach to their image block. */
  images: Array<{ file: string; moduleKey: string; alt: string }>;
  /** Things in the source deliberately not imported (e.g. extra data collection). */
  notes: string[];
}

export function slug(text: string, taken: Set<string>): string {
  const base =
    text
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 56) || "item";
  let key = base;
  for (let n = 2; taken.has(key); n++) key = `${base}-${n}`;
  taken.add(key);
  return key;
}
