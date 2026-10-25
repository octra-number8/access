import Link from "next/link";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";

export default async function Home() {
  const session = await getSession();
  if (!session) {
    return (
      <>
        <h1>Octra Access</h1>
        <p>Sign in to manage your organisation, your documents or venue decisions.</p>
        <p><Link href="/sign-in">Sign in</Link></p>
      </>
    );
  }
  const { data: isOps } = await (await supabaseServer()).rpc("am_platform_admin");
  return (
    <>
      <h1>Signed in</h1>
      <p className="muted">{session.email}</p>
      <ul>
        {session.personIds.length > 0 ? <li><Link href="/me">Your details and organisations</Link></li> : null}
        {session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/venue">Venue administration</Link></li> : null}
        {session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/venue/inductions">Inductions</Link></li> : null}
        {session.organisationAdmin.map((o) => (
          <li key={o.organisation_id}><Link href={`/organisation/${o.organisation_id}`}>Your organisation</Link> ({o.role} administrator)</li>
        ))}
        {session.appointmentVenueIds.length > 0 ? <li><Link href="/review">Decisions waiting for you</Link></li> : null}
        {session.appointmentVenueIds.length > 0 ? <li><Link href="/facilitate">Record a facilitated induction</Link></li> : null}
        {isOps ? <li><Link href="/operations">Platform operations</Link></li> : null}
      </ul>
      {session.personIds.length === 0 ? (
        <p className="muted">Your account is not linked to any organisation yet. If you were invited, open the link in your invitation email.</p>
      ) : null}
    </>
  );
}
