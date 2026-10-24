import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { EvidenceList, type EvidenceLine } from "@/components/Blocked";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { approveEngagementAction, reviewDocumentAction } from "../actions";

export default async function Review() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/review");
  const db = await supabaseServer();
  const [versions, reviews, docs, criteria, engagements, orgs] = await Promise.all([
    db.from("document_version").select("id, document_id, version_no, expires_on, issuer, reference, scan_status").in("scan_status", ["clean", "not_scanned"]),
    db.from("review_decision").select("document_version_id"),
    db.from("document").select("id, title, document_type_id, owner_kind, organisation_id, person_id"),
    db.from("review_criteria_version").select("id, document_type_id, criteria, effective_from").lte("effective_from", new Date().toISOString()).order("effective_from", { ascending: false }),
    db.from("engagement").select("id, organisation_id, capacity_code, row_version").eq("status", "proposed"),
    db.from("organisation").select("id, legal_name"),
  ]);
  const reviewed = new Set((reviews.data ?? []).map((r) => r.document_version_id));
  const doc = new Map((docs.data ?? []).map((d) => [d.id, d]));
  const currentCriteria = new Map<string, { id: string; criteria: Array<{ code: string; label: string }> }>();
  for (const c of criteria.data ?? []) if (!currentCriteria.has(c.document_type_id)) currentCriteria.set(c.document_type_id, c);
  const orgName = new Map((orgs.data ?? []).map((o) => [o.id, o.legal_name]));
  const waiting = (versions.data ?? []).filter((v) => !reviewed.has(v.id) && doc.has(v.document_id));
  const evidence = await Promise.all((engagements.data ?? []).map(async (e) =>
    (await db.rpc("engagement_evidence", { p_engagement_id: e.id })).data?.evidence as EvidenceLine[] | undefined));

  return (
    <>
      <h1>Decisions waiting for you</h1>
      <p className="muted">A review records that a document was checked against the stated criteria for a stated scope. It is not an approval of the work, a certificate of competence or a statement of compliance.</p>

      <h2>Documents to review</h2>
      {waiting.length === 0 ? <p>None.</p> : null}
      {waiting.map((v) => {
        const d = doc.get(v.document_id)!;
        const c = currentCriteria.get(d.document_type_id);
        return (
          <div className="panel" key={v.id}>
            <p><strong>{d.title}</strong> v{v.version_no} {v.expires_on ? `— expires ${v.expires_on}` : ""} · <a href={`/api/documents/${v.id}`}>Download the file</a></p>
            {v.scan_status === "not_scanned" ? (
              <p className="notice">This file has not been malware-scanned. Open it only on a computer with up-to-date antivirus.</p>
            ) : null}
            {!c ? <p>No review criteria are published for this document type yet.</p> : (
              <ActionForm action={reviewDocumentAction} what="Recording this review" submitLabel="Record review">
                <input type="hidden" name="key" value={randomUUID()} />
                <input type="hidden" name="version_id" value={v.id} />
                <input type="hidden" name="criteria_version_id" value={c.id} />
                <input type="hidden" name="criteria_codes" value={c.criteria.map((k) => k.code).join(",")} />
                <fieldset className="stack"><legend>Declared criteria</legend>
                  {c.criteria.map((k) => <label className="inline" key={k.code}><input type="checkbox" name={`criterion_${k.code}`} /> {k.label}</label>)}
                </fieldset>
                <label>Outcome
                  <select name="outcome" required defaultValue="reviewed_no_further_comments">
                    <option value="reviewed_no_further_comments">Reviewed for the stated scope, no further comments</option>
                    <option value="more_information_required">More information required</option>
                    <option value="not_accepted">Not accepted</option>
                  </select>
                </label>
                <label>Scope this review covers<textarea name="scope_wording" required rows={2} placeholder="e.g. Public liability cover for electrical installation work at the venue" /></label>
                <label>Conditions or comments<textarea name="conditions" rows={2} /></label>
              </ActionForm>
            )}
          </div>
        );
      })}

      <h2>Engagements to approve</h2>
      {(engagements.data ?? []).length === 0 ? <p>None.</p> : null}
      {(engagements.data ?? []).map((e, n) => (
        <div className="panel" key={e.id}>
          <p><strong>{orgName.get(e.organisation_id) ?? "Organisation"}</strong> — {e.capacity_code.replace("_", " ")}</p>
          <EvidenceList lines={evidence[n] ?? []} />
          <ActionForm action={approveEngagementAction} what="Approving this engagement" submitLabel="Approve engagement">
            <input type="hidden" name="key" value={randomUUID()} />
            <input type="hidden" name="engagement_id" value={e.id} />
            <input type="hidden" name="row_version" value={e.row_version} />
          </ActionForm>
        </div>
      ))}
    </>
  );
}
