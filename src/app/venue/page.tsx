import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { EvidenceList, type EvidenceLine } from "@/components/Blocked";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { inviteOrganisation } from "../actions";

export default async function Venue() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue");
  const db = await supabaseServer();
  const [venues, capacities, me, invitations, engagements, orgs] = await Promise.all([
    db.from("venue").select("id, name, customer_id").in("customer_id", session.tenantAdminCustomerIds),
    db.from("engagement_capacity").select("code, label"),
    db.from("person").select("id, customer_id").in("id", session.personIds),
    db.from("invitation").select("id, kind, invitee_email, status, expires_at, venue_id").eq("kind", "organisation").order("created_at", { ascending: false }),
    db.from("engagement").select("id, organisation_id, capacity_code, status, valid_during, venue_id").order("created_at", { ascending: false }),
    db.from("organisation").select("id, legal_name"),
  ]);
  if (session.tenantAdminCustomerIds.length === 0) {
    return <p>Venue administration is available to tenant administrators only.</p>;
  }
  const orgName = new Map((orgs.data ?? []).map((o) => [o.id, o.legal_name]));
  const evidence = await Promise.all(
    (engagements.data ?? []).map(async (e) => (await db.rpc("engagement_evidence", { p_engagement_id: e.id })).data?.evidence as EvidenceLine[] | undefined),
  );
  const today = new Date().toISOString().slice(0, 10);
  return (
    <>
      <h1>Venue administration</h1>
      <p className="muted">Administration records information. It does not authorise any work (invariant 9).</p>

      <h2>Invite an organisation</h2>
      <ActionForm action={inviteOrganisation} what="Sending this invitation" submitLabel="Create and email invitation">
        <input type="hidden" name="key" value={randomUUID()} />
        <label>Venue
          <select name="venue_id" required>{(venues.data ?? []).map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select>
        </label>
        <input type="hidden" name="owner_person_id" value={(me.data ?? [])[0]?.id ?? ""} />
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
        <thead><tr><th scope="col">Email</th><th scope="col">Recorded state</th><th scope="col">Expires</th></tr></thead>
        <tbody>{(invitations.data ?? []).map((i) => (
          <tr key={i.id}><td>{i.invitee_email}</td><td>{i.status.replace("_", " ")}</td><td>{new Date(i.expires_at).toLocaleDateString("en-GB")}</td></tr>
        ))}</tbody>
      </table></div>

      <h2>Engagements and the evidence each needs</h2>
      {(engagements.data ?? []).map((e, n) => (
        <div className="panel" key={e.id}>
          <p><strong>{orgName.get(e.organisation_id) ?? "Organisation"}</strong> — {e.capacity_code.replace("_", " ")} — recorded state: {e.status}</p>
          <EvidenceList lines={evidence[n] ?? []} />
          {e.status === "proposed" ? <p className="muted">Approval is made by an appointed authority, from their decisions page.</p> : null}
        </div>
      ))}
    </>
  );
}
