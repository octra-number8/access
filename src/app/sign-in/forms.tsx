"use client";

import { useState } from "react";
import { ActionForm } from "@/components/ActionForm";
import { sendCode, verifyCode } from "../actions";

/** Both steps share one email value, so the address typed for the code is already filled in below. */
export function SignInForms({ next, initialEmail }: { next: string; initialEmail: string }) {
  const [email, setEmail] = useState(initialEmail);
  const field = (
    <label>Email address
      <input name="email" type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
    </label>
  );
  return (
    <>
      <ActionForm action={sendCode} what="Sending a code" submitLabel="Email me a code">{field}</ActionForm>
      <h2>Enter your code</h2>
      <ActionForm action={verifyCode} what="Signing in" submitLabel="Sign in">
        {field}
        <label>Code<input name="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required /></label>
        <input type="hidden" name="next" value={next} />
      </ActionForm>
    </>
  );
}
