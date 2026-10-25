"use client";

// One question per screen (as in the induction journey), saved on every step so the
// applicant can stop and come back. The database decides what is complete and what is
// recommended; this screen only collects the answers.

import { useRouter } from "next/navigation";
import { useMemo, useState, useTransition } from "react";
import { answersOf, isShown, type ScreeningContent } from "@/lib/screening/content";
import { saveAnswers, submitJob } from "../../actions";

const newKey = () => crypto.randomUUID();

export function ScreeningJourney({ jobId, reference, title, rowVersion, content, classes, initialAnswers, initialSelected }: {
  jobId: string; reference: string; title: string; rowVersion: number; content: ScreeningContent;
  classes: Array<{ id: string; name: string }>;
  initialAnswers: Record<string, string[]>; initialSelected: string[];
}) {
  const router = useRouter();
  const [answers, setAnswers] = useState<Record<string, string[]>>(initialAnswers);
  const [selected, setSelected] = useState<string[]>(initialSelected);
  // Resume at the first question still unanswered, or at the review if all are answered.
  const [step, setStep] = useState(() => {
    const first = content.questions.filter((q) => isShown(q, initialAnswers));
    const gap = first.findIndex((q) => (initialAnswers[q.key] ?? []).length === 0);
    return gap === -1 ? first.length : gap;
  });
  const [problem, setProblem] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [submitKey] = useState(newKey);

  // Only the questions that apply, given the answers so far; answers to questions that
  // no longer apply are dropped so the database receives a consistent set.
  const shown = useMemo(() => content.questions.filter((q) => isShown(q, answers)), [content, answers]);
  const clean = (a: Record<string, string[]>) =>
    Object.fromEntries(Object.entries(a).filter(([k, v]) => v.length > 0 && content.questions.some((q) => q.key === k && isShown(q, a))));
  const q = shown[step];
  const reviewing = step >= shown.length;

  function choose(key: string, value: string, many: boolean, checked: boolean) {
    setProblem(null);
    setAnswers((a) => {
      const cur = many ? (a[key] ?? []).filter((x) => x !== value) : [];
      return { ...a, [key]: checked ? [...cur, value] : cur };
    });
  }

  function persist(next: () => void) {
    start(async () => {
      const r = await saveAnswers(jobId, newKey(), clean(answers), selected);
      if (r?.ok) next(); else setProblem(r?.ok === false ? r.reason : "Not saved.");
    });
  }

  function submit() {
    start(async () => {
      const saved = await saveAnswers(jobId, newKey(), clean(answers), selected);
      if (!saved?.ok) { setProblem(saved?.ok === false ? saved.reason : "Not saved."); return; }
      const r = await submitJob(jobId, submitKey, rowVersion);
      if (r?.ok) { router.push(`/jobs/${jobId}`); router.refresh(); }
      else setProblem(r?.ok === false ? [r.reason, ...(r.problems ?? [])].join(" ") : "Not submitted.");
    });
  }

  return (
    <section className="mx-auto flex max-w-xl flex-col gap-4 rounded-2xl bg-surface p-5 shadow-sm" aria-labelledby="screening-step">
      <p className="m-0 text-sm text-muted">{reference} — {title}</p>
      {!reviewing && q ? (
        <>
          <p className="m-0 text-sm text-muted">Question {step + 1} of {shown.length}</p>
          <fieldset className="m-0 flex flex-col gap-3 border-0 p-0">
            <legend id="screening-step" className="mb-3 p-0 text-xl font-extrabold text-ink">{q.text}</legend>
            {q.help ? <p className="text-body">{q.help}</p> : null}
            {answersOf(q).map((o) => {
              const many = q.type === "choose_many";
              return (
                <label key={o.key} className="flex min-h-11 items-center gap-3 rounded-lg border border-line px-4 py-3">
                  <input type={many ? "checkbox" : "radio"} name={q.key} value={o.key}
                    checked={(answers[q.key] ?? []).includes(o.key)}
                    onChange={(e) => choose(q.key, o.key, many, e.target.checked)} />
                  <span>{o.text}</span>
                </label>
              );
            })}
          </fieldset>
          {problem ? <p role="alert" className="notice notice-blocked">{problem}</p> : null}
          <div className="flex gap-3">
            {step > 0 ? <button type="button" className="secondary" onClick={() => setStep(step - 1)} disabled={pending}>Back</button> : null}
            <button type="button" disabled={pending || (answers[q.key] ?? []).length === 0}
              onClick={() => persist(() => setStep(step + 1))}>{pending ? "Saving…" : "Next"}</button>
          </div>
          <p className="m-0 text-sm text-muted">Your answers are saved as you go.</p>
        </>
      ) : (
        <>
          <h1 id="screening-step" className="m-0 text-xl font-extrabold text-ink">Check your answers</h1>
          <dl className="m-0 flex flex-col divide-y divide-line">{shown.map((x, i) => (
            <div key={x.key} className="flex items-start justify-between gap-3 py-3">
              <div>
                <dt className="text-sm text-muted">{x.text}</dt>
                <dd className="m-0 font-semibold text-ink">{(answers[x.key] ?? []).map((a) => answersOf(x).find((o) => o.key === a)?.text ?? a).join(", ") || "Not answered"}</dd>
              </div>
              <button type="button" onClick={() => setStep(i)} aria-label={`Change your answer to: ${x.text}`}
                className="m-0 min-h-11 shrink-0 border-0 bg-transparent px-2 font-semibold text-ink underline hover:bg-transparent">Change</button>
            </div>
          ))}</dl>
          {classes.length > 0 ? (
            <fieldset className="stack">
              <legend className="font-semibold">Permits you already know you need (optional)</legend>
              <p className="text-sm text-muted">Choosing one adds it. It never removes anything screening recommends.</p>
              {classes.map((c) => (
                <label key={c.id} className="inline">
                  <input type="checkbox" checked={selected.includes(c.id)}
                    onChange={(e) => setSelected((s) => e.target.checked ? [...s, c.id] : s.filter((x) => x !== c.id))} /> {c.name}
                </label>
              ))}
            </fieldset>
          ) : null}
          {problem ? <p role="alert" className="notice notice-blocked">{problem}</p> : null}
          <button type="button" disabled={pending} onClick={submit}>{pending ? "Working…" : "Submit for screening"}</button>
          <p className="m-0 text-sm text-muted">After you submit, the answers are fixed. Changing the job later means screening it again.</p>
        </>
      )}
    </section>
  );
}
