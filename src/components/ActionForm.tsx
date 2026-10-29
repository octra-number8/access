"use client";

import { startTransition, useActionState, useEffect, useRef, type ReactNode } from "react";
import { usePathname } from "next/navigation";
import { Blocked, type Denial } from "./Blocked";
import { useKeepMessage } from "./Flash";

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
  // A success not yet shown here. The refreshed page and the result arrive together, so when the
  // page no longer has this form (its work is done), the form is removed without ever showing
  // the result: on removal, the message is kept at the foot of the screen instead.
  const unshown = useRef<{ message: string; detail?: string } | null>(null);
  const [result, run, pending] = useActionState(async (prev: ActionResult, data: FormData) => {
    const r = await action(prev, data);
    if (r?.ok === true) unshown.current = r;
    return r;
  }, null);
  const form = useRef<HTMLFormElement>(null);
  // A form passed to `action` is cleared by React whatever the outcome. Submitting by hand
  // keeps what was typed when the action is refused, and clears it only once it succeeds.
  useEffect(() => {
    if (result?.ok === true) { form.current?.reset(); unshown.current = null; }
  }, [result]);
  const keep = useKeepMessage();
  const path = usePathname();
  const here = useRef(path);
  useEffect(() => { here.current = path; }, [path]);
  useEffect(() => () => {
    if (unshown.current) keep?.(unshown.current.message, unshown.current.detail, here.current);
  }, [keep]);
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
