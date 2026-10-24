import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { EvidenceList, type EvidenceLine } from "@/components/Blocked";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { invitePerson, uploadDocumentAction } from "../../actions";

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
  const { data: org } = await db.from("organisation").select("id, legal_name, trading_name").eq("id", id).maybeSingle();
  if (!org) return <p>This organisation does not exist or you do not have access to it.</p>;

  const [rels, invites, docs, types, engagements] = await Promise.all([
    db.from("person_organisation_relationship").select("id, person_id, kind, status").eq("organisation_id", id),
    db.from("invitation").select("id, invitee_email, status, expires_at").eq("organisation_id", id),
    db.from("document").select("id, title, owner_kind, person_id, document_type_id").or(`organisation_id.eq.${id},provided_via_organisation_id.eq.${id}`),
    db.from("document_type").select("id, label, owner_level"),
    db.from("engagement").select("id, capacity_code, status").eq("organisation_id", id),
  ]);
  const personIds = (rels.data ?? []).map((r) => r.person_id);
  const docIds = (docs.data ?? []).map((d) => d.id);
  const [people, versions] = await Promise.all([
    db.from("person").select("id, given_name, family_name").in("id", personIds),
    db.from("document_version").select("id, document_id, version_no, scan_status, expires_on, created_at").in("document_id", docIds).order("version_no", { ascending: false }),
  ]);
  const versionIds = (versions.data ?? []).map((v) => v.id);
  const { data: reviews } = await db.from("review_decision").select("document_version_id, outcome, scope_wording, conditions").in("document_version_id", versionIds);
  const name = new Map((people.data ?? []).map((p) => [p.id, `${p.given_name} ${p.family_name}`]));
  const typeLabel = new Map((types.data ?? []).map((t) => [t.id, t.label]));
  const latest = new Map<string, NonNullable<typeof versions.data>[number]>();
  for (const v of versions.data ?? []) if (!latest.has(v.document_id)) latest.set(v.document_id, v);
  const evidence = await Promise.all((engagements.data ?? []).map(async (e) =>
    (await db.rpc("engagement_evidence", { p_engagement_id: e.id })).data?.evidence as EvidenceLine[] | undefined));
  const active = (rels.data ?? []).filter((r) => r.status === "active");

  return (
    <>
      <h1>{org.legal_name}</h1>

      <h2>Engagements</h2>
      {(engagements.data ?? []).map((e, n) => (
        <div className="panel" key={e.id}>
          <p>{e.capacity_code.replace("_", " ")} — recorded state: <strong>{e.status}</strong></p>
          <EvidenceList lines={evidence[n] ?? []} />
        </div>
      ))}

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

      <h3>Upload a document</h3>
      <ActionForm action={uploadDocumentAction} what="Uploading this document" submitLabel="Upload">
        <input type="hidden" name="key" value={randomUUID()} />
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

      <h2>People</h2>
      <ul>{(rels.data ?? []).map((r) => <li key={r.id}>{name.get(r.person_id) ?? "Person"} — {r.kind.replace("_", " ")} — {r.status}</li>)}</ul>
      <h3>Invite someone to join</h3>
      <ActionForm action={invitePerson} what="Inviting this person" submitLabel="Invite">
        <input type="hidden" name="key" value={randomUUID()} />
        <input type="hidden" name="organisation_id" value={id} />
        <label>First name<input name="given_name" required /></label>
        <label>Last name<input name="family_name" required /></label>
        <label>Email<input name="email" type="email" required /></label>
        <label>Relationship
          <select name="kind" defaultValue="employee">
            <option value="employee">Employee</option><option value="agency">Agency worker</option>
            <option value="self_employed">Self-employed</option><option value="subcontractor">Subcontractor</option>
            <option value="volunteer">Volunteer</option><option value="exhibitor">Exhibitor</option>
          </select>
        </label>
      </ActionForm>
      {(invites.data ?? []).length > 0 ? (
        <ul>{(invites.data ?? []).map((i) => <li key={i.id}>{i.invitee_email} — {i.status}</li>)}</ul>
      ) : null}
    </>
  );
}
