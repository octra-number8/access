"use client";

// The learner journey (OCTRA Induct's, on Access's model). Every step is decided from the
// server's record of the attempt, so a refresh or a dropped connection resumes in place.

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState, useTransition } from "react";
import { DeclarationStep } from "@/components/learner/declaration-step";
import { QuestionStep } from "@/components/learner/question-step";
import { ResultStep } from "@/components/learner/result-step";
import { SectionStep } from "@/components/learner/section-step";
import type { LearnerCourse } from "@/components/learner/types";
import { answerQuestion, completeInduction, finishAttempt, moduleEvent, startInduction, type StepResult } from "../actions";

const newKey = () => crypto.randomUUID();

export function Journey({ course }: { course: LearnerCourse }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [problem, setProblem] = useState<string | null>(null);
  const [declaring, setDeclaring] = useState(false);
  const top = useRef<HTMLDivElement>(null);
  const { content, attempt } = course;

  function run(action: () => Promise<StepResult>) {
    setProblem(null);
    startTransition(async () => {
      const r = await action();
      if (!r.ok) setProblem(r.reason);
      router.refresh();
      top.current?.scrollIntoView({ block: "start" });
    });
  }

  // Which module is current, and is it started?
  const modules = content.modules;
  const progress = attempt?.modules ?? {};
  const current = attempt?.status === "in_progress" ? modules.find((m) => !progress[m.key]?.completed_at) : undefined;
  const autoStarted = useRef<string | null>(null);
  useEffect(() => {
    if (attempt && current && !progress[current.key] && autoStarted.current !== current.key) {
      autoStarted.current = current.key;
      run(() => moduleEvent(newKey(), attempt.id, current.key, "start"));
    }
  }); // eslint-disable-line react-hooks/exhaustive-deps

  const frame = (child: React.ReactNode) => (
    <div ref={top} className="mx-auto flex max-w-xl flex-col gap-4 rounded-card bg-surface px-5 py-6">{child}</div>
  );

  if (course.completion && !course.completion.invalidated_for && (!attempt || attempt.status === "completed")) {
    return frame(
      <section className="flex flex-col gap-3" aria-labelledby="done">
        <h2 id="done" className="text-2xl font-extrabold text-ink">Induction complete</h2>
        <p className="text-body">You completed {course.title} on {new Date(course.completion.completed_at).toLocaleDateString("en-GB")}.</p>
        <p className="text-body">It is recorded as valid until {new Date(course.completion.valid_until).toLocaleDateString("en-GB")}.</p>
        <p className="text-sm text-muted">Completing the induction records that you have been briefed. It is not permission to enter or to work: the venue confirms those separately.</p>
      </section>,
    );
  }

  if (attempt?.status === "completed" && course.completion?.invalidated_for) {
    return frame(
      <section className="flex flex-col gap-4" aria-labelledby="invalidated">
        <h2 id="invalidated" className="text-2xl font-extrabold text-ink">Please take the induction again</h2>
        <p className="text-body">Your earlier completion is no longer valid. The venue recorded the reason as: {course.completion.invalidated_for.replace("_", " ")}.</p>
        {problem && <p role="alert" className="rounded-md bg-warning-subtle px-4 py-3 text-sm text-ink">{problem}</p>}
        <button type="button" disabled={pending} onClick={() => run(() => startInduction(newKey(), course.course_id))}
                className="min-h-12 rounded-md bg-brand px-4 text-base font-semibold text-white hover:bg-brand-hover disabled:opacity-50">
          {pending ? "Starting…" : "Start the induction again"}
        </button>
      </section>,
    );
  }

  if (!attempt) {
    const seconds = modules.reduce((s, m) => s + m.min_seconds, 0);
    const minutes = Math.floor(seconds / 60);
    const reading = seconds === 0 ? "" : seconds < 60 ? ` At least ${seconds} seconds of reading.`
      : ` At least ${minutes} ${minutes === 1 ? "minute" : "minutes"} of reading.`;
    const questions = content.questions.length;
    return frame(
      <section className="flex flex-col gap-4" aria-labelledby="welcome">
        <h1 id="welcome" className="m-0 text-2xl font-extrabold text-ink">{course.title}</h1>
        <p className="text-body">{modules.length} {modules.length === 1 ? "section" : "sections"} and {questions} {questions === 1 ? "question" : "questions"}.{reading}</p>
        <p className="text-body">Your progress is kept: you can stop and come back to this link.</p>
        {problem && <p role="alert" className="rounded-md bg-warning-subtle px-4 py-3 text-sm text-ink">{problem}</p>}
        <button type="button" disabled={pending} onClick={() => run(() => startInduction(newKey(), course.course_id))}
                className="min-h-12 rounded-md bg-brand px-4 text-base font-semibold text-white hover:bg-brand-hover disabled:opacity-50">
          {pending ? "Starting…" : "Start the induction"}
        </button>
      </section>,
    );
  }

  if (attempt.status === "failed" || (attempt.status === "passed" && !declaring)) {
    return frame(
      <>
        {problem && <p role="alert" className="rounded-md bg-warning-subtle px-4 py-3 text-sm text-ink">{problem}</p>}
        <ResultStep course={course} busy={pending}
                    onRetry={() => run(() => startInduction(newKey(), course.course_id))}
                    onContinue={() => setDeclaring(true)} />
      </>,
    );
  }

  if (attempt.status === "passed") {
    return frame(
      <DeclarationStep items={content.declaration} busy={pending} problem={problem}
                       signingAs={`${course.learner.given_name} ${course.learner.family_name}`}
                       onComplete={(keys, name) => run(() => completeInduction(newKey(), attempt.id, attempt.row_version, keys, name))} />,
    );
  }

  // In progress: the current module, then its questions; after the last module, the final questions.
  const answered = new Set(attempt.answered);
  const done = modules.filter((m) => progress[m.key]?.completed_at);
  const lastDone = done.at(-1);
  const total = modules.length;
  const moduleQuestion = lastDone && content.questions.find((q) => q.placement === "module" && q.module_key === lastDone.key && !answered.has(q.key));
  const pendingModuleQuestion = content.questions.find((q) => q.placement === "module" && progress[q.module_key ?? ""]?.completed_at && !answered.has(q.key));
  const nextQuestion = moduleQuestion ?? pendingModuleQuestion ?? (!current ? content.questions.find((q) => !answered.has(q.key)) : undefined);
  const answerAndRefresh = (q: string) => (keys: string[]) => run(() => answerQuestion(newKey(), attempt.id, q, keys));

  if (nextQuestion) {
    const n = content.questions.findIndex((q) => q.key === nextQuestion.key) + 1;
    return frame(
      <QuestionStep key={nextQuestion.key} question={nextQuestion} position={`Question ${n} of ${content.questions.length}`}
                    shuffle={course.settings.shuffle_options} seed={attempt.id} busy={pending} problem={problem}
                    onAnswer={answerAndRefresh(nextQuestion.key)} />,
    );
  }

  if (current) {
    const started = progress[current.key]?.started_at;
    const elapsed = started ? (new Date(course.server_now).getTime() - new Date(started).getTime()) / 1000 : 0;
    const remaining = started ? Math.max(0, Math.ceil(current.min_seconds - elapsed)) : current.min_seconds;
    return frame(
      <SectionStep key={current.key} module={current} courseId={course.course_id}
                   position={`Section ${modules.indexOf(current) + 1} of ${total}`}
                   remainingSeconds={remaining} busy={pending || !started} problem={problem}
                   onContinue={() => run(() => moduleEvent(newKey(), attempt.id, current.key, "complete"))} />,
    );
  }

  return frame(
    <section className="flex flex-col gap-4" aria-labelledby="finish">
      <h2 id="finish" className="text-2xl font-extrabold text-ink">Ready to see your result</h2>
      <p className="text-body">You have read every section and answered every question.</p>
      {problem && <p role="alert" className="rounded-md bg-warning-subtle px-4 py-3 text-sm text-ink">{problem}</p>}
      <button type="button" disabled={pending} onClick={() => run(() => finishAttempt(newKey(), attempt.id, attempt.row_version))}
              className="min-h-12 rounded-md bg-brand px-4 text-base font-semibold text-white hover:bg-brand-hover disabled:opacity-50">
        {pending ? "Marking…" : "See my result"}
      </button>
    </section>,
  );
}
