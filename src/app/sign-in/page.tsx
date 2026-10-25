import { SignInForms } from "./forms";

export default async function SignIn({ searchParams }: { searchParams: Promise<{ next?: string; email?: string }> }) {
  const { next = "/", email = "" } = await searchParams;
  return (
    <>
      <h1>Sign in</h1>
      <p>We will email you a 6-digit code. It works on any device.</p>
      <SignInForms next={next} initialEmail={email} />
    </>
  );
}
