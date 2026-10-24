import { ActionForm } from "@/components/ActionForm";
import { sendCode, verifyCode } from "../actions";

export default async function SignIn({ searchParams }: { searchParams: Promise<{ next?: string; email?: string }> }) {
  const { next = "/", email = "" } = await searchParams;
  return (
    <>
      <h1>Sign in</h1>
      <p>We will email you a 6-digit code. It works on any device.</p>
      <ActionForm action={sendCode} what="Sending a code" submitLabel="Email me a code">
        <label>Email address<input name="email" type="email" autoComplete="email" required defaultValue={email} /></label>
      </ActionForm>
      <h2>Enter your code</h2>
      <ActionForm action={verifyCode} what="Signing in" submitLabel="Sign in">
        <label>Email address<input name="email" type="email" autoComplete="email" required defaultValue={email} /></label>
        <label>Code<input name="code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required /></label>
        <input type="hidden" name="next" value={next} />
      </ActionForm>
    </>
  );
}
