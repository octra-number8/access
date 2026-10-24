"use client";

import { useActionState, type ReactNode } from "react";
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
  return (
    <form action={run} className={className ?? "stack"}>
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
