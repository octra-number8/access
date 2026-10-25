import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { date, RELATIONSHIP_KIND, RELATIONSHIP_STATE, verificationText, type Verification } from "@/lib/labels";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { decideRelationship, declareCompetency, endRelationship } from "../admin-actions";

export const metadata = { title: "Your details" };

// Q33: what a person does for themselves — accept or decline an organisation's claim
// that they work with it, end it, and declare their own qualifications.
export default async function Me() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/me");
  if (session.personIds.length === 0) {
    return <p>Your account is not linked to a person record yet. If you were invited, open the link in your invitation email.</p>;
  }
  const db = await supabaseServer();
  const [people, rels, comps, compTypes] = await Promise.all([
    db.from("person").select("id, given_name, family_name").in("id", session.personIds),
    db.from("person_organisation_relationship").select("id, person_id, organisation_id, kind, status, row_version")
      .in("person_id", session.personIds).in("status", ["invited", "active"]),
    db.from("competency").select("id, person_id, competency_type_id, issuer, number, expires_on").in("person_id", session.personIds),
    db.from("competency_type").select("id, label").is("retired_at", null).order("label"),
  ]);
  const [{ data: orgs }, { data: checks }] = await Promise.all([
    db.from("organisation").select("id, legal_name").in("id", (rels.data ?? []).map((r) => r.organisation_id)),
    db.from("competency_verification").select("competency_id, method, source_checked, holder_match, scope, valid_until, outcome, created_at")
      .in("competency_id", (comps.data ?? []).map((c) => c.id)).order("created_at", { ascending: false }),
  ]);
  const orgName = new Map((orgs ?? []).map((o) => [o.id, o.legal_name]));
  const compLabel = new Map((compTypes.data ?? []).map((t) => [t.id, t.label]));
  const latestCheck = new Map<string, Verification>();
  for (const c of (checks ?? []) as Array<Verification & { competency_id: string }>) if (!latestCheck.has(c.competency_id)) latestCheck.set(c.competency_id, c);
  const me = (people.data ?? [])[0];
  const k = () => randomUUID();

  return (
    <>
      <h1>Your details</h1>
      {me ? <p>{me.given_name} {me.family_name} · <span className="muted">{session.email}</span></p> : null}

      <h2>Organisations you work with</h2>
      {(rels.data ?? []).length === 0 ? <p>None.</p> : null}
      {(rels.data ?? []).map((r) => (
        <div className="panel" key={r.id}>
          <p><strong>{orgName.get(r.organisation_id) ?? "An organisation"}</strong> — {RELATIONSHIP_KIND[r.kind] ?? r.kind} — {RELATIONSHIP_STATE[r.status]}</p>
          {r.status === "invited" ? (
            <>
              <p>This organisation has recorded that you work with it. Nothing changes until you accept.</p>
              <ActionForm action={decideRelationship} what="Accepting" submitLabel="Accept">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="relationship_id" value={r.id} />
                <input type="hidden" name="row_version" value={r.row_version} />
                <input type="hidden" name="decision" value="accept" />
              </ActionForm>
              <ActionForm action={decideRelationship} what="Declining" submitLabel="Decline" secondary>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="relationship_id" value={r.id} />
                <input type="hidden" name="row_version" value={r.row_version} />
                <input type="hidden" name="decision" value="decline" />
              </ActionForm>
            </>
          ) : (
            <ActionForm action={endRelationship} what="Ending this relationship" submitLabel="I no longer work with them" secondary>
              <input type="hidden" name="key" value={k()} />
              <input type="hidden" name="relationship_id" value={r.id} />
              <input type="hidden" name="row_version" value={r.row_version} />
              <input type="hidden" name="by" value="own" />
              <label>Reason<input name="reason" required placeholder="e.g. Changed employer" /></label>
              <p className="muted">Documents this organisation provided for you stay with them. A new employer invites you separately (Q40).</p>
            </ActionForm>
          )}
        </div>
      ))}

      <h2>Your competencies</h2>
      {(comps.data ?? []).length === 0 ? <p>None declared.</p> : (
        <ul>{(comps.data ?? []).map((c) => (
          <li key={c.id}>{compLabel.get(c.competency_type_id) ?? "Competency"} — {c.issuer} {c.number} ({c.expires_on ? `expires ${date(c.expires_on)}` : "no expiry date given"})
            <div className="muted">{verificationText(latestCheck.get(c.id))}</div></li>
        ))}</ul>
      )}
      {me && (compTypes.data ?? []).length > 0 ? (
        <>
          <h3>Declare a card or qualification</h3>
          <ActionForm action={declareCompetency} what="Declaring this competency" submitLabel="Declare">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="person_id" value={me.id} />
            <label>Competency
              <select name="competency_type_id" required>{(compTypes.data ?? []).map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}</select>
            </label>
            <label>Issuer<input name="issuer" required /></label>
            <label>Card or certificate number<input name="number" required /></label>
            <label>Expires on<input name="expires_on" type="date" /></label>
          </ActionForm>
        </>
      ) : null}
    </>
  );
}
