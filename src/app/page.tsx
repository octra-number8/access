import Link from "next/link";
import { getSession } from "@/lib/session";
import { signOut } from "./actions";

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
  return (
    <>
      <h1>Signed in</h1>
      <p className="muted">{session.email}</p>
      <ul>
        {session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/venue">Venue administration</Link></li> : null}
        {session.organisationAdmin.map((o) => (
          <li key={o.organisation_id}><Link href={`/organisation/${o.organisation_id}`}>Your organisation</Link> ({o.role} administrator)</li>
        ))}
        {session.appointmentVenueIds.length > 0 ? <li><Link href="/review">Decisions waiting for you</Link></li> : null}
      </ul>
      {session.personIds.length === 0 ? (
        <p className="muted">Your account is not linked to any organisation yet. If you were invited, open the link in your invitation email.</p>
      ) : null}
      <form action={signOut}><button type="submit">Sign out</button></form>
    </>
  );
}
