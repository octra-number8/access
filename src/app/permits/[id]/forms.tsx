"use client";

import { useState } from "react";
import { ActionForm } from "@/components/ActionForm";
import { answersOf, isShown, type ScreeningQuestion } from "@/lib/screening/content";
import { decideStep, savePermitDraft } from "../actions";

/** The class's questions (follow-ups appear only when they apply), the window and documents. */
export function DraftForm({ permitId, newKey, questions, answers: initial, windowFrom, windowTo, documents, chosenDocuments, tz }: {
  permitId: string; newKey: string; questions: ScreeningQuestion[]; answers: Record<string, string[]>; tz: string;
  windowFrom: string; windowTo: string; documents: Array<{ id: string; title: string }>; chosenDocuments: string[];
}) {
  const [answers, setAnswers] = useState<Record<string, string[]>>(initial);
  const shown = questions.filter((q) => isShown(q, answers));
  const clean = Object.fromEntries(Object.entries(answers).filter(([k, v]) => v.length > 0 && shown.some((q) => q.key === k)));
  return (
    <ActionForm action={savePermitDraft} what="Saving this request" submitLabel="Save">
      <input type="hidden" name="key" value={newKey} />
      <input type="hidden" name="permit_id" value={permitId} />
      <input type="hidden" name="answers" value={JSON.stringify(clean)} />
      <input type="hidden" name="tz" value={tz} />
      {shown.map((q) => (
        <fieldset key={q.key} className="stack"><legend>{q.text}</legend>
          {q.help ? <p className="muted m-0">{q.help}</p> : null}
          {answersOf(q).map((o) => {
            const many = q.type === "choose_many";
            return (
              <label className="inline" key={o.key}>
                <input type={many ? "checkbox" : "radio"} name={`q_${q.key}`} checked={(answers[q.key] ?? []).includes(o.key)}
                  onChange={(e) => setAnswers((a) => {
                    const cur = many ? (a[q.key] ?? []).filter((x) => x !== o.key) : [];
                    return { ...a, [q.key]: e.target.checked ? [...cur, o.key] : cur };
                  })} /> {o.text}
              </label>
            );
          })}
        </fieldset>
      ))}
      <div className="grid gap-3 sm:grid-cols-2">
        <label>Permit starts<input name="window_from" type="datetime-local" required defaultValue={windowFrom} /></label>
        <label>Permit ends<input name="window_to" type="datetime-local" required defaultValue={windowTo} /></label>
      </div>
      {documents.length > 0 ? (
        <fieldset className="stack"><legend>Documents to include (method statement, risk assessment, drawings)</legend>
          {documents.map((d) => <label className="inline" key={d.id}><input type="checkbox" name="document_version_ids" value={d.id} defaultChecked={chosenDocuments.includes(d.id)} /> {d.title}</label>)}
        </fieldset>
      ) : <p className="muted">Upload documents on your organisation&apos;s page to include them.</p>}
    </ActionForm>
  );
}

const WORDING_HINT = "e.g. Reviewed for lamp replacement from a MEWP in Hall 1 on 26–27 October. Never \"approved\" or \"safe\".";

/** One step's decision. Fields follow the outcome chosen; the database checks everything again. */
export function StepDecisionForm({ stepId, kind, newKey, previous }: {
  stepId: string; kind: string; newKey: string;
  previous: null | { outcome: string; reason: string; scope_wording: string | null; by: string };
}) {
  const [outcome, setOutcome] = useState(previous && ["no_further_comments", "conditions"].includes(previous.outcome) ? previous.outcome : "");
  const [conditions, setConditions] = useState(1);
  const [items, setItems] = useState(1);
  return (
    <ActionForm action={decideStep} what="Recording this decision" submitLabel="Record decision">
      <input type="hidden" name="key" value={newKey} />
      <input type="hidden" name="step_id" value={stepId} />
      <input type="hidden" name="kind" value={kind} />
      {previous ? (
        <p className="notice m-0">On the previous version {previous.by} recorded: <strong>{previous.outcome.replace(/_/g, " ")}</strong>
          {previous.scope_wording ? ` — ${previous.scope_wording}` : ""}. Check what changed before confirming it.</p>
      ) : null}
      <label>Outcome
        <select name="outcome" required value={outcome} onChange={(e) => setOutcome(e.target.value)}>
          <option value="">— Choose —</option>
          <option value="no_further_comments">Reviewed for the stated scope, no further comments</option>
          <option value="conditions">Reviewed for the stated scope, with conditions</option>
          <option value="more_information">Ask for more information</option>
          <option value="refused">Refuse</option>
          <option value="not_applicable">Not applicable to this request</option>
        </select>
      </label>
      {outcome === "no_further_comments" || outcome === "conditions" ? (
        <label>Scope this decision covers<textarea name="scope_wording" required rows={2} placeholder={WORDING_HINT}
          defaultValue={previous?.scope_wording ?? ""} /></label>
      ) : null}
      {outcome === "conditions" ? (
        <fieldset className="stack"><legend>Conditions</legend>
          {Array.from({ length: conditions }, (_, i) => (
            <div key={i} className="stack">
              <input name="condition_text" placeholder={`Condition ${i + 1}`} />
              <label className="inline"><input type="checkbox" name="condition_ack" value={i} defaultChecked /> The supervisor acknowledges it at acceptance</label>
            </div>
          ))}
          <button type="button" className="secondary" onClick={() => setConditions(conditions + 1)}>Add a condition</button>
        </fieldset>
      ) : null}
      {outcome === "more_information" ? (
        <fieldset className="stack"><legend>Information needed (Q70)</legend>
          <label>Message to the applicant<textarea name="rfi_message" required rows={2} /></label>
          {Array.from({ length: items }, (_, i) => <input key={i} name="rfi_item" placeholder={`Item ${i + 1}`} />)}
          <button type="button" className="secondary" onClick={() => setItems(items + 1)}>Add an item</button>
        </fieldset>
      ) : null}
      {kind === "external" && outcome && outcome !== "not_applicable" ? (
        <fieldset className="stack"><legend>The external decision (Q82)</legend>
          <label>Who made it<input name="ext_decider" required /></label>
          <label>Their organisation<input name="ext_organisation" required /></label>
          <label>Their reference (optional)<input name="ext_reference" /></label>
          <label>What it covers<input name="ext_scope" required /></label>
          <label>Date of their decision<input name="ext_decided_on" type="date" required /></label>
          <label>Their conditions (optional)<input name="ext_conditions" /></label>
        </fieldset>
      ) : null}
      <label>Reason<input name="reason" required defaultValue={previous && outcome === previous.outcome ? "Unchanged from the previous version" : ""} /></label>
    </ActionForm>
  );
}
