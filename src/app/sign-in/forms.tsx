"use client";

import { startTransition, useActionState, useEffect, useState, type FormEvent } from "react";
import type { ActionResult } from "@/components/ActionForm";
import { Blocked } from "@/components/Blocked";
import { sendCode, verifyCode } from "../actions";

/**
 * Two steps: the email address, then the code. Someone who already has a code can skip straight
 * to the second step. What was typed is kept when a step is refused; a code is never cleared
 * by the page, only replaced by the person.
 */
export function SignInForms({ next, initialEmail }: { next: string; initialEmail: string }) {
  const [step, setStep] = useState<"email" | "code">("email");
  const [email, setEmail] = useState(initialEmail);
  const [code, setCode] = useState("");
  const [sent, send, sending] = useActionState<ActionResult, FormData>(sendCode, null);
  const [verified, verify, verifying] = useActionState<ActionResult, FormData>(verifyCode, null);
  // The address the last code went to, so the code step can name it.
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [resent, setResent] = useState(false);

  useEffect(() => {
    if (sent?.ok === true) { setStep("code"); setSentTo(email.trim().toLowerCase()); }
    // Only a new result moves the step on; typing in the address does not.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sent]);

  const submit = (action: (f: FormData) => void) => (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const data = new FormData(e.currentTarget);
    startTransition(() => action(data));
  };
  const resend = () => {
    const data = new FormData();
    data.set("email", sentTo ?? email);
    setResent(true);
    startTransition(() => send(data));
  };
  const backToEmail = () => { setStep("email"); setCode(""); setResent(false); };

  const emailField = (
    <div className="grid gap-2">
      <label htmlFor="email" className="text-sm font-semibold text-ink">Email address</label>
      <input id="email" name="email" type="email" autoComplete="email" inputMode="email" required placeholder="you@company.com"
        value={email} onChange={(e) => setEmail(e.target.value)} className="signin-input" />
    </div>
  );

  if (step === "email") {
    return (
      <>
        <div className="grid gap-2">
          <h1 className="m-0 text-[28px] font-bold leading-tight tracking-[-0.02em] text-ink">Sign in</h1>
          <p className="m-0 text-[15px] leading-normal text-[#5f5e5a]">Enter your work email and we will send you a 6-digit code. No password needed.</p>
        </div>
        <form className="grid gap-[18px]" onSubmit={submit(send)}>
          {emailField}
          <button type="submit" disabled={sending} className="signin-primary">
            {sending ? "Sending…" : "Email me a code"}
            {sending ? null : (
              <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true" fill="none">
                <path d="M3 9h12M10 4l5 5-5 5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            )}
          </button>
          <div aria-live="polite">{sent?.ok === false ? <Blocked what="Sending a code" denial={sent} /> : null}</div>
        </form>
        <div className="flex items-center gap-3 text-[13px] text-[#6e6e73]" aria-hidden="true">
          <span className="h-px flex-1 bg-line" />Already have a code?<span className="h-px flex-1 bg-line" />
        </div>
        <button type="button" className="signin-secondary" onClick={() => setStep("code")}>Enter a code</button>
      </>
    );
  }

  return (
    <>
      <div className="grid gap-2">
        {sentTo ? (
          <p className="m-0 flex items-center gap-2.5 text-[13px] font-semibold text-ready">
            <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true" fill="none">
              <rect x="2" y="4" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.6" />
              <path d="M2.5 5.5L9 10l6.5-4.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            Code sent
          </p>
        ) : null}
        <h1 className="m-0 text-[28px] font-bold leading-tight tracking-[-0.02em] text-ink">{sentTo ? "Check your inbox" : "Enter your code"}</h1>
        <p className="m-0 text-[15px] leading-normal text-[#5f5e5a]">
          {sentTo
            ? <>We emailed a 6-digit code to <strong className="font-semibold text-ink">{sentTo}</strong>. It works on any device and expires in one hour.</>
            : "Enter the email address the code was sent to, and the 6-digit code from the email."}
        </p>
      </div>
      <form className="grid gap-[18px]" onSubmit={submit(verify)}>
        {sentTo ? <input type="hidden" name="email" value={sentTo} /> : emailField}
        <div className="grid gap-2">
          <label htmlFor="code" className="text-sm font-semibold text-ink">6-digit code</label>
          <input id="code" name="code" type="text" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required
            autoFocus={Boolean(sentTo)} placeholder="000000" value={code}
            onChange={(e) => setCode(e.target.value.replace(/[^0-9]/g, "").slice(0, 6))} className="signin-input signin-code" />
        </div>
        <input type="hidden" name="next" value={next} />
        <button type="submit" disabled={verifying} className="signin-primary">{verifying ? "Signing in…" : "Sign in"}</button>
        <div aria-live="polite">
          {verified?.ok === false ? <Blocked what="Signing in" denial={verified} /> : null}
          {resent && sent?.ok === false ? <Blocked what="Sending a new code" denial={sent} /> : null}
          {resent && sent?.ok === true && !sending ? <p className="notice notice-done m-0">We have sent a new code to {sentTo}. Use the newest email.</p> : null}
        </div>
      </form>
      <div className="grid gap-2.5 text-center text-sm text-[#5f5e5a]">
        {sentTo ? (
          <p className="m-0">Did not get it? Check your spam folder, or{" "}
            <button type="button" className="signin-link" onClick={resend} disabled={sending}>{sending ? "sending…" : "send a new code"}</button>
          </p>
        ) : null}
        <button type="button" className="signin-link justify-self-center text-[#5f5e5a]" onClick={backToEmail}>
          {sentTo ? "Use a different email" : "I need a code"}
        </button>
      </div>
    </>
  );
}
