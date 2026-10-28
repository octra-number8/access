import Link from "next/link";
import { PERMIT_STATE, type PermitSummary, timeLeft } from "@/lib/permits";
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
  const db = await supabaseServer();
  const [{ data: isOps }, { data: mine }] = await Promise.all([db.rpc("am_platform_admin"), db.rpc("my_live_permits")]);
  const permits = ((mine as { permits?: PermitSummary[] } | null)?.permits ?? []);
  return (
    <>
      <h1>Signed in</h1>
      <p className="muted">{session.email}</p>
      {permits.length ? (
        <>
          <h2>Your live permits</h2>
          <ul className="stack">{permits.map((p) => (
            <li key={p.id}><Link href={`/permits/${p.id}`}><strong>{PERMIT_STATE[p.status] ?? p.status}</strong>: {p.job_reference} {p.class_name}</Link>
              <span className="muted"> · {p.areas.join(", ")} · {timeLeft(p.window_end)}{p.role === "supervisor" ? " · you supervise" : ""}</span></li>
          ))}</ul>
          <h2>Your pages</h2>
        </>
      ) : null}
      <ul>
        {session.personIds.length > 0 ? <li><Link href="/me">Your details and organisations</Link></li> : null}
        {session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/venue">Venue administration</Link></li> : null}
        {session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/venue/inductions">Inductions</Link></li> : null}
        {session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/venue/screening">Activity screening set-up</Link></li> : null}
        {session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/venue/permits">Permit set-up</Link></li> : null}
        {session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/venue/entry">Entry set-up</Link> · <Link href="/venue/passes">Card passes</Link></li> : null}
        {session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/venue/chasing">Reminders and escalation</Link></li> : null}
        {session.tenantAdminCustomerIds.length > 0 || session.appointmentVenueIds.length > 0 ? <li><Link href="/venue/retention">Retention and disposal</Link> · <Link href="/venue/holds">Legal holds</Link></li> : null}
        {session.organisationAdmin.length > 0 || session.tenantAdminCustomerIds.length > 0 || session.appointmentVenueIds.length > 0 ? <li><Link href="/jobs">Jobs</Link></li> : null}
        {session.organisationAdmin.map((o) => (
          <li key={o.organisation_id}><Link href={`/organisation/${o.organisation_id}`}>Your organisation</Link> ({o.role} administrator)</li>
        ))}
        {session.appointmentVenueIds.length > 0 || session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/dashboard">Venue dashboard</Link></li> : null}
        {session.appointmentVenueIds.length > 0 || session.tenantAdminCustomerIds.length > 0 || session.organisationAdmin.length > 0 ? <li><Link href="/reports">Reports</Link></li> : null}
        {session.appointmentVenueIds.length > 0 ? <li><Link href="/review">Decisions waiting for you</Link></li> : null}
        {session.appointmentVenueIds.length > 0 || session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/live">Live board</Link></li> : null}
        {session.appointmentVenueIds.length > 0 || session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/controls">Controls desk</Link></li> : null}
        {session.appointmentVenueIds.length > 0 || session.tenantAdminCustomerIds.length > 0 || session.organisationAdmin.length > 0 ? <li><Link href="/emergency">Emergency work</Link></li> : null}
        {session.appointmentVenueIds.length > 0 ? <li><Link href="/facilitate">Record a facilitated induction</Link></li> : null}
        {session.appointmentVenueIds.length > 0 ? <li><Link href="/gate">Gate</Link> · <Link href="/gate/overrides">Gate overrides</Link> · <Link href="/gate/reconcile">Reconciliation</Link></li> : null}
        {session.personIds.length > 0 || session.tenantAdminCustomerIds.length > 0 ? <li><Link href="/visits">Visits</Link></li> : null}
        {session.personIds.length > 0 ? <li><Link href="/pass">My pass</Link></li> : null}
        {isOps ? <li><Link href="/operations">Platform operations</Link></li> : null}
      </ul>
      {session.personIds.length === 0 ? (
        <p className="muted">Your account is not linked to any organisation yet. If you were invited, open the link in your invitation email.</p>
      ) : null}
    </>
  );
}
