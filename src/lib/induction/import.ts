// Importers for existing induction content (D-015). Both produce a draft for the
// venue's H&S authority to review: nothing imported is published, and anything the
// source does not decide (reading times, safety-critical questions, unresolved facts)
// becomes an open point that blocks publication.

import { slug, type Block, type CourseContent, type ImportResult, type Module, type Question } from "./content";

const UNSET_READING_TIME =
  "Set a minimum reading time for each module (imported as 0 seconds because the source gives none).";
const UNSET_CRITICAL =
  "Mark which questions are safety-critical (imported as not safety-critical because the source does not say).";

// ---------------------------------------------------------------------------
// Induction brief markdown (the `Induction briefs` format)
// ---------------------------------------------------------------------------

/** Splits "## n. Title" sections into a map keyed by lower-case title. */
function topSections(md: string): Map<string, string> {
  const out = new Map<string, string>();
  const parts = md.split(/^## (?:\d+\.\s*)?/m);
  for (const part of parts.slice(1)) {
    const nl = part.indexOf("\n");
    const title = (nl === -1 ? part : part.slice(0, nl)).trim().toLowerCase();
    out.set(title, nl === -1 ? "" : part.slice(nl + 1));
  }
  return out;
}

function bullets(text: string | undefined): string[] {
  return (text ?? "")
    .split("\n")
    .map((l) => l.match(/^\s*-\s+(.*)$/)?.[1]?.trim())
    .filter((l): l is string => !!l);
}

const TYPE_MAP: Record<string, Question["type"]> = {
  "single choice": "single_choice",
  "multi-select": "multiple_select",
  "multiple select": "multiple_select",
  "true/false": "true_false",
};

export function parseBrief(md: string): ImportResult {
  const title = md.match(/^# (?:Induction brief:\s*)?(.+)$/m)?.[1]?.trim() ?? null;
  const top = topSections(md);
  const notes: string[] = [];
  const openPoints: ImportResult["openPoints"] = [];
  const moduleKeys = new Set<string>();
  const byTitle = new Map<string, Module>();

  // Sections: "### Title" followed by body text, under "## Sections".
  const modules: Module[] = [];
  for (const chunk of (top.get("sections") ?? "").split(/^### /m).slice(1)) {
    const nl = chunk.indexOf("\n");
    const heading = (nl === -1 ? chunk : chunk.slice(0, nl)).trim();
    const body = (nl === -1 ? "" : chunk.slice(nl + 1)).trim();
    const blocks: Block[] = body ? [{ type: "rich_text", text: body }] : [];
    const m: Module = { key: slug(heading, moduleKeys), title: heading, kind: "core", min_seconds: 0, blocks };
    modules.push(m);
    byTitle.set(heading.toLowerCase(), m);
  }

  // Questions: "Qn. Section: X" / "Type:" / "Question:" / "- [x] option" / "Explanation:".
  const questions: Question[] = [];
  const questionKeys = new Set<string>();
  for (const chunk of (top.get("questions") ?? "").split(/^Q\d+\.\s*/m).slice(1)) {
    const section = chunk.match(/^Section:\s*(.+)$/m)?.[1]?.trim() ?? "";
    const rawType = chunk.match(/^Type:\s*(.+)$/m)?.[1]?.trim().toLowerCase() ?? "";
    const stem = chunk.match(/^Question:\s*(.+)$/m)?.[1]?.trim() ?? "";
    const explanation = chunk.match(/^Explanation:\s*(.+)$/m)?.[1]?.trim() ?? "";
    const optionKeys = new Set<string>();
    const options = [...chunk.matchAll(/^- \[( |x|X)\]\s*(.+)$/gm)].map((o) => ({
      key: slug(o[2]!, optionKeys),
      text: o[2]!.trim(),
      correct: o[1]!.toLowerCase() === "x",
    }));
    const module = byTitle.get(section.toLowerCase()) ?? null;
    if (!module && section) notes.push(`Question "${stem}" refers to section "${section}", which was not found.`);
    questions.push({
      key: slug(`q-${stem}`, questionKeys),
      placement: "final",
      module_key: module?.key ?? null,
      type: TYPE_MAP[rawType] ?? "single_choice",
      stem,
      explanation,
      safety_critical: false,
      weight: 1,
      options,
    });
    if (!TYPE_MAP[rawType]) notes.push(`Question "${stem}" had type "${rawType}", imported as single choice.`);
  }

  const declarationKeys = new Set<string>();
  const declaration = bullets(top.get("declaration")).map((text) => ({ key: slug(text, declarationKeys), text }));

  // Images: "file | section | alt text"; "to supply: what | section" becomes an open point.
  const images: ImportResult["images"] = [];
  for (const line of bullets(top.get("images"))) {
    const parts = line.split("|").map((p) => p.trim());
    if (/^to supply:/i.test(parts[0] ?? "")) {
      openPoints.push({ text: `Image still to supply for "${parts[1] ?? "?"}": ${parts[0]!.replace(/^to supply:\s*/i, "")}`, owner: null });
      continue;
    }
    const [file, section, alt] = parts;
    const module = byTitle.get((section ?? "").toLowerCase());
    if (!file || !module) {
      notes.push(`Image line not imported: ${line}`);
      continue;
    }
    module.blocks.push({ type: "image", media_id: null, alt: alt ?? null, source_file: file });
    images.push({ file, moduleKey: module.key, alt: alt ?? "" });
  }

  // Open points: "- What is undecided. ... Decide: Who."
  for (const line of bullets(top.get("open points"))) {
    const owner = line.match(/Decide:\s*(.+?)\.?$/)?.[1]?.trim() ?? null;
    openPoints.push({ text: line.replace(/\s*Decide:\s*.+$/, "").trim(), owner });
  }

  if (top.has("extra registration fields")) {
    notes.push("Extra registration fields were listed in the source; they are not imported. Collecting extra personal data needs a privacy decision (G11).");
  }
  openPoints.push({ text: UNSET_READING_TIME, owner: null }, { text: UNSET_CRITICAL, owner: null });

  const content: CourseContent = { modules, questions, declaration };
  return { title, content, openPoints, images, notes };
}

// ---------------------------------------------------------------------------
// OCTRA Induct starter template JSON (schema 1)
// ---------------------------------------------------------------------------

interface InductStarter {
  schema: number;
  sections: Array<{ title: string; min_seconds: number; blocks: Array<{ type: string; text: string }> }>;
  final_questions: Array<{
    section: number;
    type: string;
    prompt: string;
    explanation: string;
    options: Array<{ label: string; correct: boolean }>;
  }>;
  declaration: { heading?: string; body?: string; confirmations: string[] };
}

export function fromInductStarter(json: unknown, title: string | null = null): ImportResult {
  const s = json as InductStarter;
  if (s?.schema !== 1 || !Array.isArray(s.sections)) throw new Error("Not an OCTRA Induct starter template (schema 1).");
  const notes: string[] = [];
  const moduleKeys = new Set<string>();
  const modules: Module[] = s.sections.map((sec) => ({
    key: slug(sec.title, moduleKeys),
    title: sec.title,
    kind: "core",
    // The starter's reading time is carried over; the H&S authority still reviews it.
    min_seconds: Math.max(0, Math.round(sec.min_seconds ?? 0)),
    blocks: sec.blocks.map((b): Block => (b.type === "callout" ? { type: "callout", text: b.text } : { type: "rich_text", text: b.text })),
  }));
  const questionKeys = new Set<string>();
  const questions: Question[] = (s.final_questions ?? []).map((q) => {
    const optionKeys = new Set<string>();
    return {
      key: slug(`q-${q.prompt}`, questionKeys),
      placement: "final",
      module_key: modules[q.section]?.key ?? null,
      type: (["single_choice", "multiple_select", "true_false"].includes(q.type) ? q.type : "single_choice") as Question["type"],
      stem: q.prompt,
      explanation: q.explanation ?? "",
      safety_critical: false,
      weight: 1,
      options: q.options.map((o) => ({ key: slug(o.label, optionKeys), text: o.label, correct: !!o.correct })),
    };
  });
  const declarationKeys = new Set<string>();
  const declaration = (s.declaration?.confirmations ?? []).map((text) => ({ key: slug(text, declarationKeys), text }));
  if (s.declaration?.body) notes.push("The starter's declaration introduction text is shown as guidance only; each confirmation is imported as an item.");
  return {
    title,
    content: { modules, questions, declaration },
    openPoints: [{ text: UNSET_CRITICAL, owner: null }],
    images: [],
    notes,
  };
}
