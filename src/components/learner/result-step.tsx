"use client";
// Adapted from OCTRA Induct (src/components/participant/result-step.tsx), D-015.
// States what was recorded. Correct options are never shown; wrong answers are explained.

import { useEffect, useState } from "react";
import type { LearnerCourse } from "./types";

function retryClock(at: Date): string {
  const r = new Date(at);
  if (r.getSeconds() > 0 || r.getMilliseconds() > 0) r.setMinutes(r.getMinutes() + 1, 0, 0);
  return r.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
}

export function ResultStep({ course, busy, onRetry, onContinue }: {
  course: LearnerCourse; busy: boolean; onRetry: () => void; onContinue: () => void;
}) {
  const a = course.attempt!;
  const passed = a.status === "passed";
  const waitUntil = course.retry_from ? new Date(course.retry_from) : null;
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!waitUntil || waitUntil.getTime() <= Date.now()) return;
    const t = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(t);
  }, [course.retry_from]); // eslint-disable-line react-hooks/exhaustive-deps
  const waiting = !!waitUntil && waitUntil.getTime() > now;
  const wrong = a.wrong ?? [];
  const missedCritical = (a.critical_missed ?? 0) > 0;

  return (
    <section aria-labelledby="result-heading" className="flex flex-col gap-4">
      <div role="status" className={`rounded-md px-4 py-4 ${passed ? "bg-brand-subtle" : "bg-warning-subtle"}`}>
        <h2 id="result-heading" className="text-2xl font-extrabold text-ink">{passed ? "You passed" : "Not passed this time"}</h2>
        <p className="mt-1 text-body">You scored {a.score_percent}%. The pass mark is {course.settings.pass_mark_percent}%.</p>
        {!passed && missedCritical && course.settings.all_critical_required && (
          <p className="mt-1 text-body">Every safety-critical question must be answered correctly, and at least one was not.</p>
        )}
      </div>

      {wrong.length > 0 && (
        <section aria-labelledby="wrong-heading" className="flex flex-col gap-3">
          <h3 id="wrong-heading" className="text-lg font-bold text-ink">{wrong.length} to look at again</h3>
          <ol className="flex flex-col gap-3 pl-0">
            {wrong.map((q) => (
              <li key={q.question_key} className="list-none rounded-md border border-warning/40 bg-surface px-4 py-3">
                <p className="font-semibold text-ink">{q.stem}{q.safety_critical ? <span className="tag">Safety-critical</span> : null}</p>
                {q.explanation && <p className="mt-1 text-sm text-body">{q.explanation}</p>}
              </li>
            ))}
          </ol>
        </section>
      )}

      {!passed && course.attempts_left > 0 && (
        <div className="flex flex-col gap-2">
          <p className="text-body">You have {course.attempts_left} more {course.attempts_left === 1 ? "attempt" : "attempts"}. You will go through the induction again from the start.</p>
          {course.attempts_left === 1 && (
            <p className="rounded-md bg-warning-subtle px-4 py-3 text-sm text-ink">This will be your last attempt. If you do not pass it, an induction facilitator at the venue will go through it with you.</p>
          )}
          <button type="button" onClick={onRetry} disabled={waiting || busy} aria-describedby="retry-wait"
                  className="min-h-12 rounded-md bg-brand px-4 text-base font-semibold text-white hover:bg-brand-hover disabled:opacity-50">
            {busy ? "Starting…" : "Try again"}
          </button>
          <p id="retry-wait" aria-live="polite" className="min-h-5 text-sm text-body">
            {waiting && waitUntil ? `You can try again at ${retryClock(waitUntil)}.` : ""}
          </p>
        </div>
      )}
      {!passed && course.attempts_left === 0 && (
        <p className="rounded-md border border-line bg-surface px-4 py-3 text-body">You have no attempts left. An induction facilitator at the venue will go through it with you.</p>
      )}
      {passed && (
        <button type="button" onClick={onContinue}
                className="min-h-12 rounded-md bg-brand px-4 text-base font-semibold text-white hover:bg-brand-hover">
          Continue to the declaration
        </button>
      )}
    </section>
  );
}
