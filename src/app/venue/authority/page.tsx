import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { AppointmentCard, DelegationRow } from "@/components/appointment-card";
import { ScopePicker } from "@/components/scope-picker";
import type { Appointment, Delegation } from "@/lib/authority";
import { plain } from "@/lib/authority";
import { venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import {
  cancelStaffInvitation, confirmRoot, createPerson, disableLogin, grantTenantAdmin, inviteStaff, recordRoot, revokeAppointment,
  revokeRoot, revokeTenantAdmin,
} from "../../authority-actions";

export const metadata = { title: "Authority" };

interface Person {
  id: string; name: string; deactivated: boolean; organisations: string[]; login: "active" | "disabled" | "none";
  is_admin: boolean; invitation: { id: string; row_version: number; email: string; expires_at: string; expired: boolean } | null;
}
interface Overview {
  ok: true; venue: { id: string; name: string; timezone: string }; customer_id: string; me: string | null; is_admin: boolean;
  admins: Array<{ id: string; row_version: number; person_id: string; name: string; since: string; granted_by: string | null }>;
  people: Person[] | null;
  root_versions: Array<{ id: string; type: string; version_no: number; actions: string[]; class_ids: string[]; system_type_ids: string[]; requires_competence_evidence: boolean }>;
  classes: Array<{ id: string; name: string }>;
  areas: Array<{ id: string; name: string; code: string; depth: number }>;
  system_types: Array<{ id: string; label: string }>;
  systems: Array<{ id: string; name: string; type: string }>;
  appointments: Appointment[]; delegations: Delegation[];
}

// S1a (D-026): who holds authority at the venue, and the administration around it. Tenant
// administrators record root appointments and manage logins; they never grant authority
// (invariant 9). Appointments are granted by appointees, from their own appointments.
export default async function Authority({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/authority");
  const db = await supabaseServer();
  const { data: scopes } = await db.rpc("report_scopes");
  const venues = ((scopes as { venues?: Array<{ id: string; name: string }> } | null)?.venues ?? []);
  const { venue: chosen } = await searchParams;
  const venueId = venues.some((v) => v.id === chosen) ? chosen! : venues[0]?.id;
  const { data } = venueId ? await db.rpc("authority_overview", { p_venue_id: venueId }) : { data: null };
  if (!data?.ok) {
    return <><h1>Authority</h1><p>This page is for a venue&apos;s administrators and the people it has appointed, and you are neither at any venue. If you need to see it, ask the venue&apos;s administrator.</p></>;
  }
  const o = data as Overview;
  const tz = o.venue.timezone;
  const k = () => randomUUID();
  const roots = o.appointments.filter((a) => a.is_root);
  const others = o.appointments.filter((a) => !a.is_root);
  const signedIn = (o.people ?? []).filter((p) => p.login === "active" && !p.deactivated);

  return (
    <>
      <p><Link href="/venue">Venue administration</Link> · <Link href="/venue/setup">Set-up</Link> · <Link href="/me">Your appointments</Link></p>
      <h1>Authority — {o.venue.name}</h1>
      <div className="notice">
        <p className="m-0">Authority comes only from appointments. A root appointment is made by the duty holder: a tenant administrator records it, a second confirms it, and the appointee acknowledges it. Every other appointment is made by an appointee, from their own appointment, within its scope. Administrators manage logins and records; being one gives no authority to act. An appointment in force records a decision; it does not certify the person&apos;s competence.</p>
      </div>
      {venues.length > 1 ? (
        <form className="no-print"><label>Venue <select name="venue" defaultValue={o.venue.id}>{venues.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label> <button type="submit" className="secondary">Show</button></form>
      ) : null}

      <h2>Root appointments</h2>
      {roots.length === 0 ? <p className="notice notice-blocked">This venue has no root appointment, so no one can make any other appointment yet.</p> : null}
      {roots.map((a) => (
        <AppointmentCard key={a.id} a={a} tz={tz}>
          {a.can_confirm ? (
            <ActionForm action={confirmRoot} what="Confirming the root appointment" submitLabel="Confirm this root appointment">
              <input type="hidden" name="key" value={k()} /><input type="hidden" name="appointment_id" value={a.id} />
              <input type="hidden" name="row_version" value={a.row_version} />
              <p className="muted text-sm m-0">Confirm only that it matches the duty holder&apos;s letter of appointment.</p>
            </ActionForm>
          ) : a.status === "pending_confirmation" && o.is_admin ? <p className="muted text-sm">You recorded this, or you are the appointee, so another tenant administrator must confirm it.</p> : null}
          {a.can_revoke_root ? (
            <details><summary>Record that the duty holder has revoked it</summary>
              <ActionForm action={revokeRoot} what="Recording the revocation" submitLabel="Record revocation" secondary>
                <input type="hidden" name="key" value={k()} /><input type="hidden" name="appointment_id" value={a.id} />
                <input type="hidden" name="row_version" value={a.row_version} />
                <label>Reason<input name="reason" required maxLength={1000} /></label>
                <label>The duty holder&apos;s revocation (reference)<input name="evidence" required maxLength={300} placeholder="For example: Letter DH-014, 3 March" /></label>
              </ActionForm>
            </details>
          ) : null}
        </AppointmentCard>
      ))}

      {o.is_admin ? (
        <details className="panel" style={{ maxWidth: "none" }}>
          <summary><strong>Record a root appointment</strong></summary>
          {o.root_versions.length === 0 ? (
            <p>No appointment type at this venue is marked as root-eligible. Add one under <Link href="/venue">Venue administration</Link> first.</p>
          ) : signedIn.length === 0 ? <p>The appointee needs a login to acknowledge it. Invite them to sign in first (People and logins, below).</p> : (
            <ActionForm action={recordRoot} what="Recording the root appointment" submitLabel="Record root appointment">
              <input type="hidden" name="key" value={k()} /><input type="hidden" name="venue_id" value={o.venue.id} />
              <input type="hidden" name="tz" value={tz} />
              <p className="muted text-sm m-0">Record exactly what the duty holder&apos;s letter says. A second tenant administrator then confirms it, and the appointee acknowledges it.</p>
              <label>Appointee<select name="appointee" required defaultValue="">
                <option value="" disabled>Choose a person with a login</option>
                {signedIn.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
              <label>Duty holder who made the appointment<select name="duty_holder" required defaultValue="">
                <option value="" disabled>Choose a person</option>
                {(o.people ?? []).filter((p) => !p.deactivated).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
              <label>Appointment type<select name="type_version_id" required defaultValue="">
                <option value="" disabled>Choose a root-eligible type</option>
                {o.root_versions.map((v) => <option key={v.id} value={v.id}>{v.type} (version {v.version_no})</option>)}</select></label>
              <details><summary className="text-sm">What each type allows</summary>
                {o.root_versions.map((v) => <div key={v.id}><strong>{v.type}</strong><ul>{v.actions.map((x) => <li key={x}>{plain(x)}</li>)}</ul></div>)}
              </details>
              <fieldset className="stack"><legend>Permit classes</legend>
                {o.classes.length ? o.classes.map((c) => <label key={c.id} className="inline"><input type="checkbox" name="class" value={c.id} /> {c.name}</label>)
                  : <p className="muted m-0">The venue has no permit classes yet.</p>}
                <p className="muted text-sm m-0">Only classes the chosen type allows are accepted.</p>
              </fieldset>
              <ScopePicker areas={o.areas} systems={o.systems} systemTypes={o.system_types} />
              <label>Starts<input type="datetime-local" name="valid_from" required /></label>
              <label>Ends (leave empty if the letter gives no end)<input type="datetime-local" name="valid_to" /></label>
              <label>Review due (optional)<input type="date" name="review_due_on" /></label>
              <label>Limitations (optional)<textarea name="limitations" maxLength={2000} rows={2} /></label>
              <label>Letter of appointment (where the signed letter is kept)<input name="letter" required maxLength={300} placeholder="For example: Letter DH-001, held in the H&S file" /></label>
              <label>Competence evidence (reference, if the type requires it)<input name="competence" maxLength={300} /></label>
            </ActionForm>
          )}
        </details>
      ) : null}

      <h2>Other appointments</h2>
      {others.length === 0 ? <p>None yet. Appointees make them from their own appointments, on <Link href="/me">Your appointments</Link>.</p> : null}
      {others.map((a) => (
        <AppointmentCard key={a.id} a={a} tz={tz}>
          {a.can_revoke ? (
            <details><summary>Revoke this appointment</summary>
              <ActionForm action={revokeAppointment} what="Revoking the appointment" submitLabel="Revoke" secondary>
                <input type="hidden" name="key" value={k()} /><input type="hidden" name="appointment_id" value={a.id} />
                <input type="hidden" name="row_version" value={a.row_version} />
                <label>Reason<input name="reason" required maxLength={1000} /></label>
              </ActionForm>
            </details>
          ) : null}
        </AppointmentCard>
      ))}

      <h2>Delegations in force</h2>
      {o.delegations.length === 0 ? <p>None.</p> : <ul className="history">{o.delegations.map((d) => <DelegationRow key={d.id} d={d} tz={tz} />)}</ul>}

      <h2>Tenant administrators</h2>
      <ul>{o.admins.map((a) => (
        <li key={a.id}>{a.name} <span className="muted text-sm">since {venueTime(a.since, tz)}{a.granted_by ? `, added by ${a.granted_by}` : ""}</span>
          {o.is_admin && a.person_id !== o.me ? (
            <details><summary className="text-sm">End {a.name}&apos;s administration</summary>
              <ActionForm action={revokeTenantAdmin} what="Ending the administration" submitLabel="End administration" secondary>
                <input type="hidden" name="key" value={k()} /><input type="hidden" name="tenant_admin_id" value={a.id} />
                <input type="hidden" name="row_version" value={a.row_version} />
                <label>Reason<input name="reason" required maxLength={1000} /></label>
              </ActionForm>
            </details>
          ) : null}
        </li>))}
      </ul>
      {o.is_admin ? (
        <ActionForm action={grantTenantAdmin} what="Adding a tenant administrator" submitLabel="Add as tenant administrator">
          <input type="hidden" name="key" value={k()} /><input type="hidden" name="customer_id" value={o.customer_id} />
          <label>Person<select name="person_id" required defaultValue="">
            <option value="" disabled>Choose a person with a login</option>
            {signedIn.filter((p) => !p.is_admin).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
        </ActionForm>
      ) : null}

      {o.people ? (
        <>
          <h2>People and logins</h2>
          <p className="muted">A login lets a person sign in. It gives them no authority: that comes only from appointments.</p>
          <div className="table-wrap"><table className="stacked">
            <thead><tr><th scope="col">Person</th><th scope="col">Organisations</th><th scope="col">Login</th><th scope="col">Action</th></tr></thead>
            <tbody>{o.people.map((p) => (
              <tr key={p.id}>
                <td data-label="Person"><strong>{p.name}</strong>{p.is_admin ? <span className="muted text-sm"> · tenant administrator</span> : null}{p.deactivated ? <span className="muted text-sm"> · deactivated</span> : null}</td>
                <td data-label="Organisations">{p.organisations.length ? p.organisations.join(", ") : <span className="muted">Venue staff</span>}</td>
                <td data-label="Login">{p.login === "active" ? "Can sign in" : p.login === "disabled" ? "Disabled"
                  : p.invitation ? <>Invited ({p.invitation.email}){p.invitation.expired ? ", expired" : `, until ${venueTime(p.invitation.expires_at, tz)}`}</> : "None"}</td>
                <td data-label="Action">
                  {p.login === "active" && p.id !== o.me && !p.deactivated ? (
                    <ActionForm action={disableLogin} what="Disabling the login" submitLabel="Disable login" secondary>
                      <input type="hidden" name="key" value={k()} /><input type="hidden" name="person_id" value={p.id} />
                    </ActionForm>
                  ) : p.invitation ? (
                    <ActionForm action={cancelStaffInvitation} what="Cancelling the invitation" submitLabel="Cancel invitation" secondary>
                      <input type="hidden" name="key" value={k()} /><input type="hidden" name="invitation_id" value={p.invitation.id} />
                      <input type="hidden" name="row_version" value={p.invitation.row_version} />
                    </ActionForm>
                  ) : p.login === "none" && !p.deactivated && p.organisations.length === 0 ? (
                    <ActionForm action={inviteStaff} what="Inviting them to sign in" submitLabel="Invite to sign in">
                      <input type="hidden" name="key" value={k()} /><input type="hidden" name="person_id" value={p.id} />
                      <label>Email<input type="email" name="email" required autoComplete="off" /></label>
                    </ActionForm>
                  ) : p.login === "none" && p.organisations.length ? <span className="muted text-sm">Invited by their organisation</span> : null}
                </td>
              </tr>
            ))}</tbody>
          </table></div>
          <details className="panel" style={{ maxWidth: "none" }}><summary><strong>Add a member of the venue&apos;s staff</strong></summary>
            <ActionForm action={createPerson} what="Adding the person" submitLabel="Add person">
              <input type="hidden" name="key" value={k()} /><input type="hidden" name="customer_id" value={o.customer_id} />
              <label>First name<input name="given_name" required maxLength={100} /></label>
              <label>Last name<input name="family_name" required maxLength={100} /></label>
            </ActionForm>
          </details>
        </>
      ) : null}
    </>
  );
}
