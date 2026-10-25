"use client";
// Adapted from OCTRA Induct (src/components/participant/section-step.tsx), D-015.
// The countdown only unlocks the button; the server checks the time again (api.module_progress).

import { useEffect, useId, useState } from "react";
import { BlockView } from "./block-view";
import type { LearnerModule } from "./types";

function formatCountdown(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return m > 0 ? `${m}:${String(s).padStart(2, "0")}` : `${s} seconds`;
}

export function SectionStep({ module, courseId, position, remainingSeconds, busy, problem, onContinue }: {
  module: LearnerModule; courseId: string; position: string; remainingSeconds: number;
  busy: boolean; problem: string | null; onContinue: () => void;
}) {
  const id = useId();
  const [remaining, setRemaining] = useState(remainingSeconds);
  useEffect(() => {
    setRemaining(remainingSeconds);
    if (remainingSeconds <= 0) return;
    const startedAt = Date.now();
    const timer = window.setInterval(() => {
      const left = Math.max(0, remainingSeconds - Math.floor((Date.now() - startedAt) / 1000));
      setRemaining(left);
      if (left === 0) window.clearInterval(timer);
    }, 250);
    return () => window.clearInterval(timer);
  }, [remainingSeconds]);

  const locked = remaining > 0;
  const total = Math.max(module.min_seconds, 1);
  const progress = module.min_seconds > 0 ? ((module.min_seconds - remaining) / total) * 100 : 100;

  return (
    <article aria-labelledby={`${id}-title`} className="flex flex-col gap-4">
      <div>
        <p className="text-sm font-semibold text-muted">{position}</p>
        <h2 id={`${id}-title`} className="text-2xl font-extrabold text-ink">{module.title}</h2>
      </div>
      <div className="flex flex-col gap-4">
        {module.blocks.map((block, i) => <BlockView key={i} block={block} courseId={courseId} />)}
      </div>
      <div className="sticky bottom-0 -mx-5 flex flex-col gap-2 border-t border-line bg-surface px-5 pt-3 pb-4">
        {module.min_seconds > 0 && (
          <div aria-hidden="true" className="h-1 w-full overflow-hidden rounded-full bg-line">
            <div className="h-1 bg-brand motion-safe:transition-[width]" style={{ width: `${progress}%` }} />
          </div>
        )}
        {problem && <p role="alert" className="rounded-md bg-warning-subtle px-3 py-2 text-sm text-ink">{problem}</p>}
        <p id={`${id}-countdown`} className="min-h-5 text-sm text-body">{locked ? `Next available in ${formatCountdown(remaining)}` : ""}</p>
        <p aria-live="polite" className="sr-only">{!locked && module.min_seconds > 0 ? "You can now continue." : ""}</p>
        <button type="button" onClick={onContinue} disabled={locked || busy} aria-describedby={`${id}-countdown`}
                className="min-h-12 rounded-md bg-brand px-4 text-base font-semibold text-white hover:bg-brand-hover disabled:opacity-50">
          {busy ? "Saving…" : "Next"}
        </button>
      </div>
    </article>
  );
}
