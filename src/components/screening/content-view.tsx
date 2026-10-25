import type { ReactNode } from "react";
import { answersOf, type ScreeningContent } from "@/lib/screening/content";

/**
 * Screening questions and rules in plain English. Used by the author and by the technical
 * authority deciding the version, so both read exactly the same thing. `questionAction` and
 * `ruleAction` render per-item controls (only while the version is a draft).
 */
export function ContentView({ content, classes, questionAction, ruleAction }: {
  content: ScreeningContent;
  classes: Map<string, { name: string; handling: string }>;
  questionAction?: (key: string) => ReactNode;
  ruleAction?: (key: string) => ReactNode;
}) {
  const text = new Map(content.questions.map((q) => [q.key, q]));
  const answerText = (qk: string, a: string) => answersOf(text.get(qk) ?? { key: qk, text: qk, type: "yes_no" }).find((o) => o.key === a)?.text ?? a;
  return (
    <>
      <h3>Questions ({content.questions.length})</h3>
      {content.questions.length === 0 ? <p>None yet.</p> : (
        <ol>{content.questions.map((q) => (
          <li key={q.key} className="mb-2">
            <strong>{q.text}</strong>
            <div className="muted">
              {q.type === "yes_no" ? "Yes or no" : `${q.type === "choose_one" ? "Choose one" : "Choose any"}: ${answersOf(q).map((o) => o.text).join(" · ")}`}
              {q.show_if ? ` · asked only if "${text.get(q.show_if.question)?.text ?? q.show_if.question}" is ${q.show_if.answers.map((a) => answerText(q.show_if!.question, a)).join(" or ")}` : ""}
            </div>
            {q.help ? <div className="muted">{q.help}</div> : null}
            {questionAction?.(q.key)}
          </li>
        ))}</ol>
      )}
      <h3>Rules ({content.rules.length})</h3>
      {content.rules.length === 0 ? <p>None yet.</p> : (
        <ul>{content.rules.map((r) => {
          const c = classes.get(r.permit_class_id);
          return (
            <li key={r.key} className="mb-2">
              If {r.all.map((x, i) => (
                <span key={i}>{i > 0 ? " and " : ""}&ldquo;{text.get(x.question)?.text ?? x.question}&rdquo; is {x.answers.map((a) => answerText(x.question, a)).join(" or ")}</span>
              ))}{" "}
              → {c?.handling === "external_reference" ? "hold for external evidence: " : "recommend "}<strong>{c?.name ?? "an unknown class"}</strong>
              <div className="muted">Reason shown to the applicant: {r.rationale}</div>
              {ruleAction?.(r.key)}
            </li>
          );
        })}</ul>
      )}
    </>
  );
}
