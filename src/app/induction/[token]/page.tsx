import { randomUUID } from "node:crypto";
import Link from "next/link";
import { ActionForm } from "@/components/ActionForm";
import { getSession } from "@/lib/session";
import { claimLink } from "./actions";

export const metadata = { title: "Your induction" };

// A personal induction link (P3-2). The person signs in with the address it was sent to,
// then opens it; that links their login to their record and takes them to the induction.
export default async function InductionLink({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const session = await getSession();
  return (
    <div className="mx-auto flex max-w-xl flex-col gap-4 rounded-card bg-surface px-5 py-6">
      <h1 className="m-0 text-2xl font-extrabold text-ink">Your induction</h1>
      {!session ? (
        <>
          <p>Sign in with the email address this link was sent to. We will email you a 6-digit code.</p>
          <p><Link className="button" href={`/sign-in?next=${encodeURIComponent(`/induction/${token}`)}`}>Sign in to start</Link></p>
        </>
      ) : (
        <ActionForm action={claimLink} what="Opening this induction" submitLabel="Open my induction">
          <p className="muted">Signed in as {session.email}.</p>
          <input type="hidden" name="key" value={randomUUID()} />
          <input type="hidden" name="token" value={token} />
        </ActionForm>
      )}
    </div>
  );
}
