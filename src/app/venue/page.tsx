import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { EvidenceList, type EvidenceLine } from "@/components/Blocked";
import { date } from "@/lib/labels";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { inviteOrganisation } from "../actions";
import { cancelInvitation, createAppointmentType, proposeTypeVersion, resolveMatch } from "../admin-actions";

const TYPE_STATE: Record<string, string> = {
  proposed: "proposed, waiting for a root appointee",
  approved: "approved",
  rejected: "rejected",
};

export default async function Venue() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue");
  if (session.tenantAdminCustomerIds.length === 0) {
    return <p>Venue administration is available to tenant administrators only.</p>;
  }
  const db = await supabaseServer();
  const [venues, capacities, me, invitations, engagements, orgs, apptTypes, typeVersions, actions, roots] = await Promise.all([
    db.from("venue").select("id, name, customer_id").in("customer_id", session.tenantAdminCustomerIds),
    db.from("engagement_capacity").select("code, label"),
    db.from("person").select("id, customer_id").in("id", session.personIds),
    db.from("invitation").select("id, invitee_email, invitee_given_name, invitee_family_name, status, expires_at, venue_id, row_version, match_organisation_id, acceptance_details")
      .eq("kind", "organisation").order("created_at", { ascending: false }),
    db.from("engagement").select("id, organisation_id, capacity_code, status, valid_during, venue_id").order("created_at", { ascending: false }),
    db.from("organisation").select("id, legal_name").order("legal_name"),
    db.from("appointment_type").select("id, venue_id, code, name").is("retired_at", null).order("name"),
    db.from("appointment_type_version").select("id, appointment_type_id, version_no, status, allowed_action_codes, is_root_eligible, effective_from, decision_reason").order("version_no", { ascending: false }),
    db.from("authority_action").select("code, description").eq("basis", "appointment").order("code"),
    db.from("appointment").select("venue_id").eq("is_root", true).neq("status", "revoked"),
  ]);
  const orgName = new Map((orgs.data ?? []).map((o) => [o.id, o.legal_name]));
  const evidence = await Promise.all(
    (engagements.data ?? []).map(async (e) => (await db.rpc("engagement_evidence", { p_engagement_id: e.id })).data?.evidence as EvidenceLine[] | undefined),
  );
  const venueList = venues.data ?? [];
  const oneVenue = venueList.length === 1 ? venueList[0] : null;
  const venueField = oneVenue ? <input type="hidden" name="venue_id" value={oneVenue.id} /> : (
    <label>Venue<select name="venue_id" required>{venueList.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label>
  );
  const myPerson = (me.data ?? [])[0]?.id ?? "";
  const hasRoot = new Set((roots.data ?? []).map((r) => r.venue_id));
  const today = new Date().toISOString().slice(0, 10);
  const k = () => randomUUID();
  const pending = (invitations.data ?? []).filter((i) => i.status === "awaiting_match");

  return (
    <>
      <h1>Venue administration</h1>
      <p className="muted">Administration records information. It does not authorise any work (invariant 9).</p>
      <p><Link href="/venue/setup">Set-up</Link> · <Link href="/venue/authority">Authority</Link> · <Link href="/venue/places">Places and systems</Link> · <Link href="/venue/events">Events</Link> · <Link href="/venue/evidence">Evidence settings</Link> · <Link href="/venue/screening">Activity screening, permit classes and work types</Link> · <Link href="/venue/permits">Permit set-up</Link> · <Link href="/jobs">Jobs</Link> · <Link href="/venue/retention">Retention and disposal</Link> · <Link href="/venue/holds">Legal holds</Link></p>

      {pending.length > 0 ? (
        <>
          <h2>Organisations to confirm</h2>
          <p className="muted">These organisations gave a company number that matches one already registered. Decide whether they are the same organisation. The person accepting has not been told anything about the existing one (Q26).</p>
          {pending.map((i) => (
            <div className="panel" key={i.id}>
              <p><strong>{i.invitee_given_name} {i.invitee_family_name}</strong> ({i.invitee_email}) accepted an invitation as <strong>{(i.acceptance_details as { legal_name?: string } | null)?.legal_name ?? "an organisation"}</strong>
                {" "}(company number {(i.acceptance_details as { company_number?: string } | null)?.company_number ?? "—"}). That number is registered to <strong>{orgName.get(i.match_organisation_id ?? "") ?? "an existing organisation"}</strong>.</p>
              <ActionForm action={resolveMatch} what="Linking to the existing organisation" submitLabel="Same organisation: link them">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="invitation_id" value={i.id} />
                <input type="hidden" name="row_version" value={i.row_version} />
                <input type="hidden" name="resolution" value="linked" />
              </ActionForm>
              <ActionForm action={resolveMatch} what="Setting up a separate organisation" submitLabel="Different organisation: set up separately" secondary>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="invitation_id" value={i.id} />
                <input type="hidden" name="row_version" value={i.row_version} />
                <input type="hidden" name="resolution" value="separate" />
                <p className="muted">The separate organisation is created without the company number, which stays with the existing one.</p>
              </ActionForm>
            </div>
          ))}
        </>
      ) : null}

      <h2>Invite an organisation</h2>
      <ActionForm action={inviteOrganisation} what="Sending this invitation" submitLabel="Create and email invitation">
        <input type="hidden" name="key" value={k()} />
        {venueField}
        <input type="hidden" name="owner_person_id" value={myPerson} />
        <label>Capacity
          <select name="capacity" required>{(capacities.data ?? []).map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}</select>
        </label>
        <label>Contact first name<input name="given_name" required /></label>
        <label>Contact last name<input name="family_name" required /></label>
        <label>Contact email<input name="email" type="email" required /></label>
        <label>Engagement starts<input name="from" type="date" required defaultValue={today} /></label>
        <label>Engagement ends (optional)<input name="to" type="date" /></label>
        <label>Invitation valid for (days)<input name="days" type="number" min={1} max={60} required defaultValue={14} /></label>
      </ActionForm>

      <h2>Invitations</h2>
      <div className="table-wrap"><table>
        <thead><tr><th scope="col">Email</th><th scope="col">Recorded state</th><th scope="col">Expires</th><th scope="col"><span className="sr-only">Action</span></th></tr></thead>
        <tbody>{(invitations.data ?? []).map((i) => (
          <tr key={i.id}>
            <td>{i.invitee_email}</td><td>{i.status.replace("_", " ")}</td><td>{date(i.expires_at)}</td>
            <td>{i.status === "pending" || i.status === "awaiting_match" ? (
              <ActionForm action={cancelInvitation} what="Cancelling this invitation" submitLabel="Cancel" secondary>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="invitation_id" value={i.id} />
                <input type="hidden" name="row_version" value={i.row_version} />
              </ActionForm>
            ) : null}</td>
          </tr>
        ))}</tbody>
      </table></div>

      <h2>Organisations</h2>
      {(orgs.data ?? []).length === 0 ? <p>None yet.</p> : (
        <ul>{(orgs.data ?? []).map((o) => <li key={o.id}><Link href={`/organisation/${o.id}`}>{o.legal_name}</Link></li>)}</ul>
      )}

      <h2>Engagements and the evidence each needs</h2>
      {(engagements.data ?? []).map((e, n) => (
        <div className="panel" key={e.id}>
          <p><strong>{orgName.get(e.organisation_id) ?? "Organisation"}</strong> — {e.capacity_code.replace("_", " ")} — recorded state: {e.status}</p>
          <EvidenceList lines={evidence[n] ?? []} />
          {e.status === "proposed" ? <p className="muted">Approval is made by an appointed authority, from their decisions page.</p> : null}
        </div>
      ))}

      <h2>Competency types</h2>
      <p className="muted">Competency types are now on the <Link href="/venue/evidence">Evidence settings</Link> page, with document types, review criteria and evidence requirements.</p>

      <h2>Appointment types</h2>
      <p className="muted">What an appointment of each type allows. A new version takes effect only when a root appointee approves it (D-011).</p>
      {(apptTypes.data ?? []).map((t) => {
        const versions = (typeVersions.data ?? []).filter((v) => v.appointment_type_id === t.id);
        return (
          <div className="panel" key={t.id}>
            <p><strong>{t.name}</strong> <span className="muted">({t.code})</span></p>
            {versions.length === 0 ? <p>No versions yet.</p> : (
              <ul>{versions.map((v) => (
                <li key={v.id}>Version {v.version_no} — {TYPE_STATE[v.status] ?? v.status}, from {date(v.effective_from)}
                  <div className="muted">{v.allowed_action_codes.length === 0 ? "Allows no actions" : `Allows: ${v.allowed_action_codes.join(", ")}`}{v.is_root_eligible ? " · root-eligible" : ""}</div>
                  {v.decision_reason ? <div className="muted">Decision: {v.decision_reason}</div> : null}</li>
              ))}</ul>
            )}
            <details>
              <summary>Propose a new version</summary>
              <ActionForm action={proposeTypeVersion} what="Proposing this version" submitLabel="Propose for approval">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="appointment_type_id" value={t.id} />
                <input type="hidden" name="owner_person_id" value={myPerson} />
                <fieldset className="stack"><legend>What it allows</legend>
                  {(actions.data ?? []).map((a) => (
                    <label className="inline" key={a.code}><input type="checkbox" name="actions" value={a.code} defaultChecked={versions[0]?.allowed_action_codes.includes(a.code)} /> {a.description} <span className="muted">({a.code})</span></label>
                  ))}
                </fieldset>
                <fieldset className="stack"><legend>Appointments of this type may appoint people to</legend>
                  {(apptTypes.data ?? []).filter((x) => x.venue_id === t.venue_id).map((x) => (
                    <label className="inline" key={x.id}><input type="checkbox" name="grantable" value={x.id} /> {x.name}</label>
                  ))}
                </fieldset>
                <label>Can be a root appointment
                  <select name="root_eligible" required defaultValue=""><option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option></select></label>
                <label>Needs competence evidence when appointing
                  <select name="requires_evidence" required defaultValue=""><option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option></select></label>
                <label>Takes effect from<input name="effective_from" type="date" required defaultValue={today} /></label>
                <label>Reason for the change<textarea name="reason" required rows={2} /></label>
                {!hasRoot.has(t.venue_id) ? (
                  <label className="inline"><input type="checkbox" name="mode" value="publish" /> Publish directly: this venue has no root appointment yet, so nobody can approve it (D-011 set-up only)</label>
                ) : null}
              </ActionForm>
            </details>
          </div>
        );
      })}
      <h3>New appointment type</h3>
      <ActionForm action={createAppointmentType} what="Creating this appointment type" submitLabel="Create appointment type">
        <input type="hidden" name="key" value={k()} />
        {venueField}
        <label>Short code<input name="code" required pattern="[A-Za-z0-9-]+" /></label>
        <label>Name<input name="name" required placeholder="e.g. Authorising Engineer (Electrical)" /></label>
      </ActionForm>
    </>
  );
}
