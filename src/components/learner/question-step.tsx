"use client";
// Adapted from OCTRA Induct (src/components/participant/question-step.tsx), D-015.
// Answers are recorded and marked at the end; nothing here knows which option is correct.

import { useId, useMemo, useState } from "react";
import type { LearnerQuestion } from "./types";

function shuffled<T>(items: T[], seed: string): T[] {
  // Stable per question and attempt, so a refresh does not reorder the options.
  let h = 0;
  for (const ch of seed) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    h = (h * 1103515245 + 12345) >>> 0;
    const j = h % (i + 1);
    [out[i], out[j]] = [out[j]!, out[i]!];
  }
  return out;
}

export function QuestionStep({ question, position, shuffle, seed, busy, problem, onAnswer }: {
  question: LearnerQuestion; position: string; shuffle: boolean; seed: string;
  busy: boolean; problem: string | null; onAnswer: (optionKeys: string[]) => void;
}) {
  const id = useId();
  const [selected, setSelected] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const multiple = question.type === "multiple_select";
  const options = useMemo(() => (shuffle ? shuffled(question.options, seed + question.key) : question.options),
    [question, shuffle, seed]);

  function toggle(key: string) {
    setSelected((cur) => (multiple ? (cur.includes(key) ? cur.filter((k) => k !== key) : [...cur, key]) : [key]));
  }
  function submit(event: React.FormEvent) {
    event.preventDefault();
    if (selected.length === 0) {
      setError(multiple ? "Choose at least one answer." : "Choose an answer.");
      return;
    }
    setError(null);
    onAnswer(selected);
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4">
      <fieldset className="flex flex-col gap-3 border-0 p-0">
        <legend className="mb-2 p-0">
          <span className="block text-sm font-semibold text-muted">{position}</span>
          <span className="block text-xl font-extrabold text-ink">{question.stem}</span>
          {multiple && <span className="mt-1 block text-sm font-normal text-body">Choose all that apply.</span>}
        </legend>
        {options.map((option) => {
          const checked = selected.includes(option.key);
          return (
            <label key={option.key}
                   className={`flex min-h-12 cursor-pointer items-center gap-3 rounded-md border px-4 py-2 text-base text-ink ${checked ? "border-brand bg-brand-subtle" : "border-line bg-surface"}`}>
              <input type={multiple ? "checkbox" : "radio"} name={`question-${id}`} value={option.key} checked={checked}
                     onChange={() => toggle(option.key)} disabled={busy} className="size-5 shrink-0" />
              {option.text}
            </label>
          );
        })}
      </fieldset>
      {(error ?? problem) && <p role="alert" className="rounded-md bg-warning-subtle px-4 py-3 text-sm text-ink">{error ?? problem}</p>}
      <button type="submit" disabled={busy}
              className="min-h-12 rounded-md bg-brand px-4 text-base font-semibold text-white hover:bg-brand-hover disabled:opacity-50">
        {busy ? "Saving…" : "Save answer"}
      </button>
    </form>
  );
}
