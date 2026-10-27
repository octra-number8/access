"use client";

import { startTransition, useActionState, useEffect, useRef, type ReactNode } from "react";
import { Blocked, type Denial } from "./Blocked";

export type ActionResult = { ok: true; message: string; detail?: string } | Denial | null;

/** A form posting to a server action, showing success or a full explanation of a refusal. */
export function ActionForm({
  action,
  what,
  submitLabel,
  children,
  className,
  secondary,
}: {
  action: (prev: ActionResult, form: FormData) => Promise<ActionResult>;
  what: string;
  submitLabel: string;
  children?: ReactNode;
  className?: string;
  /** For actions that should not look like the main one (e.g. declining). */
  secondary?: boolean;
}) {
  const [result, run, pending] = useActionState(action, null);
  const form = useRef<HTMLFormElement>(null);
  // A form passed to `action` is cleared by React whatever the outcome. Submitting by hand
  // keeps what was typed when the action is refused, and clears it only once it succeeds.
  useEffect(() => { if (result?.ok === true) form.current?.reset(); }, [result]);
  return (
    <form ref={form} className={className ?? "stack"}
      onSubmit={(e) => { e.preventDefault(); const data = new FormData(e.currentTarget); startTransition(() => run(data)); }}>
      {children}
      <button type="submit" disabled={pending} className={secondary ? "secondary" : undefined}>
        {pending ? "Working…" : submitLabel}
      </button>
      <div aria-live="polite">
        {result?.ok === true ? (
          <p className="notice notice-done">
            {result.message}
            {result.detail ? <span className="muted"> {result.detail}</span> : null}
          </p>
        ) : null}
        {result?.ok === false ? <Blocked what={what} denial={result} /> : null}
      </div>
    </form>
  );
}
