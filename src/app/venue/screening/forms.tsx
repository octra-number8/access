"use client";

import { useActionState, useState } from "react";
import { ActionForm } from "@/components/ActionForm";
import { answersOf, isShown, type ScreeningContent } from "@/lib/screening/content";
import { addQuestion, addRule, previewScreening, type PreviewResult } from "./actions";

function AnswerChoices({ content, question, name }: { content: ScreeningContent; question: string; name: string }) {
  const q = content.questions.find((x) => x.key === question);
  if (!q) return null;
  return (
    <fieldset className="stack"><legend>Answers that apply</legend>
      {answersOf(q).map((o) => <label className="inline" key={o.key}><input type="checkbox" name={name} value={o.key} /> {o.text}</label>)}
    </fieldset>
  );
}

export function QuestionForm({ versionId, content, newKey }: { versionId: string; content: ScreeningContent; newKey: string }) {
  const [type, setType] = useState("yes_no");
  const [dep, setDep] = useState("");
  return (
    <ActionForm action={addQuestion} what="Adding this question" submitLabel="Add question">
      <input type="hidden" name="key" value={newKey} />
      <input type="hidden" name="version_id" value={versionId} />
      <label>Question<input name="text" required placeholder="e.g. Will the work produce heat, flame or sparks?" /></label>
      <label>Help text (optional)<input name="help" /></label>
      <label>Answer type
        <select name="type" value={type} onChange={(e) => setType(e.target.value)}>
          <option value="yes_no">Yes or no</option>
          <option value="choose_one">Choose one</option>
          <option value="choose_many">Choose any that apply</option>
        </select>
      </label>
      {type !== "yes_no" ? <label>Answers, one per line<textarea name="options" rows={4} required /></label> : null}
      {content.questions.length > 0 ? (
        <>
          <label>Ask only after an earlier answer (optional)
            <select name="show_if_question" value={dep} onChange={(e) => setDep(e.target.value)}>
              <option value="">— Always ask —</option>
              {content.questions.map((q) => <option key={q.key} value={q.key}>{q.text}</option>)}
            </select>
          </label>
          {dep ? <AnswerChoices content={content} question={dep} name="show_if_answer" /> : null}
        </>
      ) : null}
    </ActionForm>
  );
}

export function RuleForm({ versionId, content, classes, newKey }: {
  versionId: string; content: ScreeningContent; newKey: string;
  classes: Array<{ id: string; name: string; handling: string }>;
}) {
  const [q1, setQ1] = useState("");
  const [q2, setQ2] = useState("");
  const [cls, setCls] = useState(classes[0]?.id ?? "");
  return (
    <ActionForm action={addRule} what="Adding this rule" submitLabel="Add rule">
      <input type="hidden" name="key" value={newKey} />
      <input type="hidden" name="version_id" value={versionId} />
      <input type="hidden" name="class_label" value={classes.find((c) => c.id === cls)?.name ?? ""} />
      <label>When this question…
        <select name="q1" value={q1} onChange={(e) => setQ1(e.target.value)} required>
          <option value="">— Choose —</option>
          {content.questions.map((q) => <option key={q.key} value={q.key}>{q.text}</option>)}
        </select>
      </label>
      {q1 ? <AnswerChoices content={content} question={q1} name="a1" /> : null}
      <label>…and also this one (optional)
        <select name="q2" value={q2} onChange={(e) => setQ2(e.target.value)}>
          <option value="">— No second condition —</option>
          {content.questions.filter((q) => q.key !== q1).map((q) => <option key={q.key} value={q.key}>{q.text}</option>)}
        </select>
      </label>
      {q2 ? <AnswerChoices content={content} question={q2} name="a2" /> : null}
      <label>Then
        <select name="permit_class_id" value={cls} onChange={(e) => setCls(e.target.value)} required>
          {classes.map((c) => <option key={c.id} value={c.id}>{c.handling === "external_reference" ? `Hold for external evidence: ${c.name}` : `Recommend ${c.name}`}</option>)}
        </select>
      </label>
      <label>Reason shown to the applicant<textarea name="rationale" rows={2} required /></label>
    </ActionForm>
  );
}

/** Runs sample answers through the database's own evaluator; records nothing. */
export function Preview({ versionId, content }: { versionId: string; content: ScreeningContent }) {
  const [answers, setAnswers] = useState<Record<string, string[]>>({});
  const [result, run, pending] = useActionState<PreviewResult, FormData>(previewScreening, null);
  return (
    <form action={run} className="stack">
      <input type="hidden" name="version_id" value={versionId} />
      {content.questions.filter((q) => isShown(q, answers)).map((q) => (
        <fieldset key={q.key} className="stack"><legend>{q.text}</legend>
          {answersOf(q).map((o) => (
            <label className="inline" key={o.key}>
              <input type={q.type === "choose_many" ? "checkbox" : "radio"} name={`ans_${q.key}`} value={o.key}
                onChange={(e) => setAnswers((a) => {
                  const cur = q.type === "choose_many" ? (a[q.key] ?? []).filter((x) => x !== o.key) : [];
                  return { ...a, [q.key]: e.target.checked ? [...cur, o.key] : cur };
                })} /> {o.text}
            </label>
          ))}
        </fieldset>
      ))}
      <button type="submit" disabled={pending} className="secondary">{pending ? "Working…" : "Show what these answers would recommend"}</button>
      <div aria-live="polite">
        {result?.ok === false ? <p className="notice notice-blocked">{result.reason}</p> : null}
        {result?.ok ? (
          <div className="panel">
            {result.problems.length > 0 ? <p>An applicant could not submit these answers yet: {result.problems.join(" ")}</p> : null}
            {result.matches.length === 0 ? <p><strong>Nothing would be recommended.</strong> An appointed authority would have to record that no permit is required.</p> : (
              <ul>{result.matches.map((m) => (
                <li key={m.rule_key}>{m.handling === "external_reference" ? "Hold for external evidence: " : "Recommend "}<strong>{m.class_name}</strong> — {m.rationale}</li>
              ))}</ul>
            )}
          </div>
        ) : null}
      </div>
    </form>
  );
}
