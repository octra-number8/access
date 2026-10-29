import { randomUUID } from "node:crypto";
import Link from "next/link";
import { ActionForm } from "@/components/ActionForm";
import { Blocked, type Denial } from "@/components/Blocked";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { acceptInvitation, declineInvitation } from "../../actions";

export default async function Invitation({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const session = await getSession();
  if (!session) {
    return (
      <>
        <h1>Your invitation</h1>
        <p>Sign in with the email address this invitation was sent to.</p>
        <p><Link href={`/sign-in?next=${encodeURIComponent(`/invitations/${token}`)}`}>Sign in to continue</Link></p>
      </>
    );
  }
  const db = await supabaseServer();
  const { data: preview } = await db.rpc("invitation_preview", { p_token: token });
  if (!preview?.ok) return <Blocked what="This invitation" denial={preview as Denial} />;
  if (preview.status !== "pending" || preview.expired) {
    return (
      <>
        <h1>Your invitation</h1>
        <p>This invitation is {preview.expired && preview.status === "pending" ? "expired" : preview.status.replace("_", " ")}.</p>
        <p className="muted">Ask whoever invited you to send a new one if you still need it.</p>
      </>
    );
  }
  const isOrganisation = preview.kind === "organisation";
  const isStaff = preview.kind === "staff";
  const key = randomUUID();
  return (
    <>
      <h1>{isOrganisation ? `Set up your organisation at ${preview.venue_name}` : isStaff ? `Sign in to ${preview.customer_name}` : `Join ${preview.organisation_name}`}</h1>
      {isStaff ? (
        <p>You are invited to sign in as <strong>{preview.person_name}</strong>, a member of the venue&apos;s staff. Signing in gives you no authority by itself: what you can do comes only from appointments made to you, which you will be asked to acknowledge.</p>
      ) : isOrganisation ? (
        <p>You are invited as a <strong>{String(preview.capacity_code).replace("_", " ")}</strong>. Accepting creates your organisation&apos;s record; the venue then checks your evidence before your engagement can start.</p>
      ) : (
        <p>You are invited to join as <strong>{String(preview.relationship_kind).replace("_", " ")}</strong>.</p>
      )}
      <div className="panel">
        <h2>Privacy notice</h2>
        {preview.privacy_notice ? (
          <p>{preview.privacy_notice.title} <span className="muted">(reference {preview.privacy_notice.content_ref})</span></p>
        ) : (
          <p>This venue has not published a privacy notice, so invitations cannot be accepted yet. Contact the venue.</p>
        )}
      </div>
      {preview.privacy_notice ? (
        <ActionForm action={acceptInvitation} what="Accepting this invitation" submitLabel="Accept invitation">
          <input type="hidden" name="key" value={key} />
          <input type="hidden" name="token" value={token} />
          <input type="hidden" name="notice_id" value={preview.privacy_notice.id} />
          {isOrganisation ? (
            <>
              <label>Organisation legal name<input name="legal_name" required /></label>
              <label>Trading name (if different)<input name="trading_name" /></label>
              <label>Company registration number (if any)<input name="company_number" /></label>
              <label>How you work with the organisation
                <select name="relationship_kind" defaultValue="employee">
                  <option value="employee">Employee</option>
                  <option value="self_employed">Self-employed / sole trader</option>
                  <option value="agency">Agency worker</option>
                </select>
              </label>
            </>
          ) : null}
          {isStaff ? null : (
            <>
              <label>Your first name<input name="given_name" autoComplete="given-name" /></label>
              <label>Your last name<input name="family_name" autoComplete="family-name" /></label>
            </>
          )}
          <label className="inline"><input type="checkbox" name="notice_read" required /> I have read the privacy notice</label>
        </ActionForm>
      ) : null}
      <h2>Not for you?</h2>
      <ActionForm action={declineInvitation} what="Declining this invitation" submitLabel="Decline invitation" secondary>
        <input type="hidden" name="key" value={randomUUID()} />
        <input type="hidden" name="token" value={token} />
      </ActionForm>
    </>
  );
}
