import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { EvidenceList, type EvidenceLine } from "@/components/Blocked";
import { OrganisationDashboard } from "@/components/organisation-dashboard";
import { date, RELATIONSHIP_KIND, RELATIONSHIP_STATE, verificationText, type Verification } from "@/lib/labels";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { invitePerson, uploadDocumentAction } from "../../actions";
import {
  appointDeputy, cancelInvitation, confirmFacilitated, declareCompetency, endRelationship, recordPersonWithoutLogin,
  revokeDeputy, setAccountable, transferAccountable,
} from "../../admin-actions";
import { sendLink } from "../../venue/inductions/actions";

const SCAN_TEXT: Record<string, string> = {
  pending: "Being checked for malware",
  not_scanned: "Available (not malware-scanned)",
  clean: "Malware-scanned",
  infected: "Failed the malware check: not released",
  rejected: "Could not be checked or wrong file type: not released",
};
const REVIEW_TEXT: Record<string, string> = {
  reviewed_no_further_comments: "Reviewed for the stated scope, no further comments",
  more_information_required: "More information required",
  not_accepted: "Not accepted",
};

export default async function Organisation({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const session = await getSession();
  if (!session) redirect(`/sign-in?next=/organisation/${id}`);
  const db = await supabaseServer();
  const { data: org } = await db.from("organisation").select("id, customer_id, legal_name, trading_name").eq("id", id).maybeSingle();
  if (!org) return <p>This organisation does not exist or you do not have access to it.</p>;
  // What the viewer is shown depends on how they relate to it; the database decides every action.
  const myAdminRole = session.organisationAdmin.find((o) => o.organisation_id === id)?.role ?? null;
  const tenantAdmin = session.tenantAdminCustomerIds.includes(org.customer_id);

  const [rels, invites, docs, types, engagements, courses, published, admins, compTypes] = await Promise.all([
    db.from("person_organisation_relationship").select("id, person_id, kind, status, row_version, acceptance_method").eq("organisation_id", id),
    db.from("invitation").select("id, invitee_email, status, expires_at, row_version").eq("organisation_id", id).order("created_at", { ascending: false }),
    db.from("document").select("id, title, owner_kind, person_id, document_type_id").or(`organisation_id.eq.${id},provided_via_organisation_id.eq.${id}`),
    db.from("document_type").select("id, label, owner_level"),
    db.from("engagement").select("id, capacity_code, status").eq("organisation_id", id),
    db.from("induction_course").select("id, title"),
    db.from("course_version").select("course_id").eq("status", "published"),
    db.from("organisation_admin").select("person_id, role").eq("organisation_id", id).is("revoked_at", null),
    db.from("competency_type").select("id, label").is("retired_at", null).order("label"),
  ]);
  const publishedCourses = (courses.data ?? []).filter((c) => (published.data ?? []).some((v) => v.course_id === c.id));
  const personIds = (rels.data ?? []).map((r) => r.person_id);
  const docIds = (docs.data ?? []).map((d) => d.id);
  const [people, versions, comps] = await Promise.all([
    db.from("person").select("id, given_name, family_name").in("id", personIds),
    db.from("document_version").select("id, document_id, version_no, scan_status, expires_on, created_at").in("document_id", docIds).order("version_no", { ascending: false }),
    db.from("competency").select("id, person_id, competency_type_id, issuer, number, expires_on").in("person_id", personIds),
  ]);
  const versionIds = (versions.data ?? []).map((v) => v.id);
  const [{ data: reviews }, { data: checks }] = await Promise.all([
    db.from("review_decision").select("document_version_id, outcome, scope_wording, conditions").in("document_version_id", versionIds),
    db.from("competency_verification").select("competency_id, method, source_checked, holder_match, scope, valid_until, outcome, created_at")
      .in("competency_id", (comps.data ?? []).map((c) => c.id)).order("created_at", { ascending: false }),
  ]);
  const name = new Map((people.data ?? []).map((p) => [p.id, `${p.given_name} ${p.family_name}`]));
  const typeLabel = new Map((types.data ?? []).map((t) => [t.id, t.label]));
  const compLabel = new Map((compTypes.data ?? []).map((t) => [t.id, t.label]));
  const latest = new Map<string, NonNullable<typeof versions.data>[number]>();
  for (const v of versions.data ?? []) if (!latest.has(v.document_id)) latest.set(v.document_id, v);
  const latestCheck = new Map<string, Verification>();
  for (const c of (checks ?? []) as Array<Verification & { competency_id: string }>) if (!latestCheck.has(c.competency_id)) latestCheck.set(c.competency_id, c);
  const evidence = await Promise.all((engagements.data ?? []).map(async (e) =>
    (await db.rpc("engagement_evidence", { p_engagement_id: e.id })).data?.evidence as EvidenceLine[] | undefined));
  const active = (rels.data ?? []).filter((r) => r.status === "active");
  const accountable = (admins.data ?? []).find((a) => a.role === "accountable");
  const deputy = (admins.data ?? []).find((a) => a.role === "deputy");
  const nonAdmins = active.filter((r) => !(admins.data ?? []).some((a) => a.person_id === r.person_id));
  const personDocVersions = (docs.data ?? []).filter((d) => d.owner_kind === "person" && latest.has(d.id));
  const k = () => randomUUID();

  return (
    <>
      <h1>{org.legal_name}</h1>
      {myAdminRole ? <OrganisationDashboard organisationId={id} /> : null}

      <h2>Engagements</h2>
      {(engagements.data ?? []).map((e, n) => (
        <div className="panel" key={e.id}>
          <p>{e.capacity_code.replace("_", " ")} — recorded state: <strong>{e.status}</strong></p>
          <EvidenceList lines={evidence[n] ?? []} />
        </div>
      ))}

      <h2>Administrators</h2>
      <p className="muted">Organisation administrators manage this organisation&apos;s people and documents. It gives them no authority to approve or carry out work.</p>
      <ul>
        <li>Accountable administrator: <strong>{accountable ? name.get(accountable.person_id) ?? "Someone" : "none"}</strong></li>
        <li>Deputy: {deputy ? name.get(deputy.person_id) ?? "Someone" : "none"}</li>
      </ul>
      {!accountable ? <p className="notice notice-blocked">This organisation has no accountable administrator. The venue&apos;s administrator sets one from the people who work with it.</p> : null}
      {myAdminRole && !deputy && nonAdmins.length > 0 ? (
        <ActionForm action={appointDeputy} what="Naming a deputy" submitLabel="Name as deputy">
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="organisation_id" value={id} />
          <label>Deputy administrator
            <select name="person_id" required>{nonAdmins.map((r) => <option key={r.person_id} value={r.person_id}>{name.get(r.person_id)}</option>)}</select>
          </label>
        </ActionForm>
      ) : null}
      {myAdminRole && deputy ? (
        <ActionForm action={revokeDeputy} what="Removing the deputy" submitLabel="Remove the deputy" secondary>
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="organisation_id" value={id} />
        </ActionForm>
      ) : null}
      {myAdminRole === "accountable" && active.length > 1 ? (
        <>
          <h3>Hand over the accountable role</h3>
          <ActionForm action={transferAccountable} what="Handing over the accountable role" submitLabel="Hand over">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="organisation_id" value={id} />
            <label>New accountable administrator
              <select name="person_id" required>{active.filter((r) => r.person_id !== accountable?.person_id).map((r) => <option key={r.person_id} value={r.person_id}>{name.get(r.person_id)}</option>)}</select>
            </label>
            <p className="muted">You will no longer be an administrator of this organisation.</p>
          </ActionForm>
        </>
      ) : null}
      {tenantAdmin && active.length > 0 ? (
        <>
          <h3>Set the accountable administrator (venue)</h3>
          <ActionForm action={setAccountable} what="Setting the accountable administrator" submitLabel="Set as accountable administrator">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="organisation_id" value={id} />
            <label>Person
              <select name="person_id" required>{active.map((r) => <option key={r.person_id} value={r.person_id}>{name.get(r.person_id)}</option>)}</select>
            </label>
            <p className="muted">Only on a verified request: never on an unverified call or email (Q28).</p>
          </ActionForm>
        </>
      ) : null}

      <h2>People</h2>
      {(rels.data ?? []).length === 0 ? <p>None yet.</p> : null}
      {(rels.data ?? []).map((r) => (
        <div className="panel" key={r.id}>
          <p><strong>{name.get(r.person_id) ?? "Person"}</strong> — {RELATIONSHIP_KIND[r.kind] ?? r.kind} — {RELATIONSHIP_STATE[r.status] ?? r.status}
            {r.acceptance_method === "facilitated" ? <span className="muted"> (acceptance recorded by the venue)</span> : null}</p>
          {r.status === "invited" && tenantAdmin ? (
            <ActionForm action={confirmFacilitated} what="Recording this acceptance" submitLabel="Record their acceptance">
              <input type="hidden" name="key" value={k()} />
              <input type="hidden" name="relationship_id" value={r.id} />
              <input type="hidden" name="row_version" value={r.row_version} />
              <label>How the person&apos;s acceptance was obtained (for someone without a login)
                <textarea name="note" required minLength={10} rows={2} placeholder="e.g. Confirmed in person at the site office, ID checked" /></label>
            </ActionForm>
          ) : null}
          {r.status === "active" && (myAdminRole || tenantAdmin) ? (
            <ActionForm action={endRelationship} what="Ending this relationship" submitLabel="End relationship" secondary>
              <input type="hidden" name="key" value={k()} />
              <input type="hidden" name="relationship_id" value={r.id} />
              <input type="hidden" name="row_version" value={r.row_version} />
              <input type="hidden" name="by" value={myAdminRole ? "organisation" : "venue"} />
              <label>Reason<input name="reason" required /></label>
            </ActionForm>
          ) : null}
        </div>
      ))}

      {tenantAdmin ? (
        <>
          <h3>Record someone without a login (venue)</h3>
          <p className="muted">For people who cannot use email or a phone (Q33). Their relationship waits until you record how they accepted it.</p>
          <ActionForm action={recordPersonWithoutLogin} what="Recording this person" submitLabel="Record person">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="key2" value={k()} />
            <input type="hidden" name="customer_id" value={org.customer_id} />
            <input type="hidden" name="organisation_id" value={id} />
            <label>First name<input name="given_name" required /></label>
            <label>Last name<input name="family_name" required /></label>
            <label>Email (optional)<input name="email" type="email" /></label>
            <label>Relationship
              <select name="kind" defaultValue="employee">
                {Object.entries(RELATIONSHIP_KIND).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
            </label>
          </ActionForm>
        </>
      ) : null}

      <h2>Competencies</h2>
      <p className="muted">A competency is declared by the person or this organisation. A venue check records what source was checked for what scope; it does not certify competence.</p>
      {(comps.data ?? []).length === 0 ? <p>None declared.</p> : (
        <div className="table-wrap"><table>
          <thead><tr><th scope="col">Person</th><th scope="col">Competency</th><th scope="col">Card or certificate</th><th scope="col">Venue check</th></tr></thead>
          <tbody>{(comps.data ?? []).map((c) => (
            <tr key={c.id}>
              <td>{name.get(c.person_id) ?? "Person"}</td>
              <td>{compLabel.get(c.competency_type_id) ?? "Competency"}</td>
              <td>{c.issuer} {c.number}<div className="muted">{c.expires_on ? `Expires ${date(c.expires_on)}` : "No expiry date given"}</div></td>
              <td>{verificationText(latestCheck.get(c.id))}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
      {myAdminRole && active.length > 0 && (compTypes.data ?? []).length > 0 ? (
        <>
          <h3>Declare a competency for one of your people</h3>
          <ActionForm action={declareCompetency} what="Declaring this competency" submitLabel="Declare">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="organisation_id" value={id} />
            <label>Person
              <select name="person_id" required>{active.map((r) => <option key={r.person_id} value={r.person_id}>{name.get(r.person_id)}</option>)}</select>
            </label>
            <label>Competency
              <select name="competency_type_id" required>{(compTypes.data ?? []).map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}</select>
            </label>
            <label>Issuer<input name="issuer" required /></label>
            <label>Card or certificate number<input name="number" required /></label>
            <label>Expires on<input name="expires_on" type="date" /></label>
            {personDocVersions.length > 0 ? (
              <label>Supporting document (optional)
                <select name="document_version_id" defaultValue="">
                  <option value="">—</option>
                  {personDocVersions.map((d) => <option key={d.id} value={latest.get(d.id)!.id}>{d.title} — {name.get(d.person_id) ?? "person"}</option>)}
                </select>
              </label>
            ) : null}
          </ActionForm>
        </>
      ) : null}

      <h2>Documents</h2>
      <div className="table-wrap"><table>
        <thead><tr><th scope="col">Document</th><th scope="col">For</th><th scope="col">Latest version</th><th scope="col">Review</th></tr></thead>
        <tbody>{(docs.data ?? []).map((d) => {
          const v = latest.get(d.id);
          const r = (reviews ?? []).find((x) => x.document_version_id === v?.id);
          return (
            <tr key={d.id}>
              <td>{d.title}<div className="muted">{typeLabel.get(d.document_type_id)}</div></td>
              <td>{d.owner_kind === "organisation" ? "Organisation" : name.get(d.person_id) ?? "Person"}</td>
              <td>v{v?.version_no} — {SCAN_TEXT[v?.scan_status ?? "pending"]}
                {v && (v.scan_status === "clean" || v.scan_status === "not_scanned") ? <> · <a href={`/api/documents/${v.id}`}>Download</a></> : null}</td>
              <td>{r ? <>{REVIEW_TEXT[r.outcome]}<div className="muted">{r.scope_wording}</div>{r.conditions ? <div>Conditions: {r.conditions}</div> : null}</> : "Not yet reviewed"}</td>
            </tr>
          );
        })}</tbody>
      </table></div>

      {myAdminRole ? (
        <>
          <h3>Upload a document</h3>
          <ActionForm action={uploadDocumentAction} what="Uploading this document" submitLabel="Upload">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="organisation_id" value={id} />
            <label>Document type
              <select name="document_type_id" required>
                {(types.data ?? []).map((t) => <option key={t.id} value={t.id}>{t.label} ({t.owner_level})</option>)}
              </select>
            </label>
            <label>It belongs to
              <select name="owner_kind" defaultValue="organisation">
                <option value="organisation">The organisation</option>
                <option value="person">One of our people (choose below)</option>
              </select>
            </label>
            <label>Person (for a person document)
              <select name="person_id" defaultValue="">
                <option value="">—</option>
                {active.map((r) => <option key={r.person_id} value={r.person_id}>{name.get(r.person_id)}</option>)}
              </select>
            </label>
            <label>Title<input name="title" /></label>
            <label>Issuer<input name="issuer" /></label>
            <label>Reference<input name="reference" /></label>
            <label>Expires on<input name="expires_on" type="date" /></label>
            <label>File (PDF, JPEG or PNG, up to 20 MB)<input name="file" type="file" accept="application/pdf,image/jpeg,image/png" required /></label>
          </ActionForm>
        </>
      ) : null}

      {publishedCourses.length > 0 && active.length > 0 && (myAdminRole || tenantAdmin) ? (
        <>
          <h2>Send someone their induction</h2>
          <ActionForm action={sendLink} what="Sending this induction link" submitLabel="Email the link">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="organisation_id" value={id} />
            <label>Induction
              <select name="course_id" required>{publishedCourses.map((c) => <option key={c.id} value={c.id}>{c.title}</option>)}</select>
            </label>
            <label>Person
              <select name="person_id" required>{active.map((r) => <option key={r.person_id} value={r.person_id}>{name.get(r.person_id)}</option>)}</select>
            </label>
            <label>Link valid for (days)<input name="days" type="number" min={1} max={60} required defaultValue={14} /></label>
          </ActionForm>
        </>
      ) : null}

      {myAdminRole ? (
        <>
          <h2>Invite someone to join</h2>
          <ActionForm action={invitePerson} what="Inviting this person" submitLabel="Invite">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="organisation_id" value={id} />
            <label>First name<input name="given_name" required /></label>
            <label>Last name<input name="family_name" required /></label>
            <label>Email<input name="email" type="email" required /></label>
            <label>Relationship
              <select name="kind" defaultValue="employee">
                {Object.entries(RELATIONSHIP_KIND).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
            </label>
          </ActionForm>
        </>
      ) : null}
      {(invites.data ?? []).length > 0 ? (
        <>
          <h3>Invitations</h3>
          {(invites.data ?? []).map((i) => (
            <div className="panel" key={i.id}>
              <p>{i.invitee_email} — {i.status.replace("_", " ")}{i.status === "pending" ? <> · expires {date(i.expires_at)}</> : null}</p>
              {i.status === "pending" && myAdminRole ? (
                <ActionForm action={cancelInvitation} what="Cancelling this invitation" submitLabel="Cancel invitation" secondary>
                  <input type="hidden" name="key" value={k()} />
                  <input type="hidden" name="invitation_id" value={i.id} />
                  <input type="hidden" name="row_version" value={i.row_version} />
                </ActionForm>
              ) : null}
            </div>
          ))}
        </>
      ) : null}
    </>
  );
}
