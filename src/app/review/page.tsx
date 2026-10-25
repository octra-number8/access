import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { EvidenceList, type EvidenceLine } from "@/components/Blocked";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { date, verificationText } from "@/lib/labels";
import { approveEngagementAction, reviewDocumentAction } from "../actions";
import { PermitDecisions } from "./permit-decisions";
import { ScreeningDecisions } from "./screening-decisions";
import { decideTypeVersion, imposeRestriction, liftRestriction, verifyCompetency } from "../admin-actions";

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
  const [inductions, courseRows] = await Promise.all([
    db.from("course_version").select("id, course_id, version_no").eq("status", "in_review"),
    db.from("induction_course").select("id, title"),
  ]);
  const [comps, checks, compTypes, typeVersions, apptTypes, restrictions, venues, people] = await Promise.all([
    db.from("competency").select("id, person_id, venue_id, competency_type_id, issuer, number, expires_on, document_version_id"),
    db.from("competency_verification").select("competency_id"),
    db.from("competency_type").select("id, label"),
    db.from("appointment_type_version").select("id, appointment_type_id, version_no, allowed_action_codes, is_root_eligible, requires_competence_evidence, effective_from, change_reason, row_version").eq("status", "proposed"),
    db.from("appointment_type").select("id, name"),
    db.from("restriction").select("id, venue_id, subject_kind, person_id, organisation_id, reason, created_at, row_version").eq("status", "active"),
    db.from("venue").select("id, name").in("id", session.appointmentVenueIds),
    db.from("person").select("id, given_name, family_name").order("family_name"),
  ]);
  const checked = new Set((checks.data ?? []).map((c) => c.competency_id));
  const toVerify = (comps.data ?? []).filter((c) => !checked.has(c.id));
  const compLabel = new Map((compTypes.data ?? []).map((t) => [t.id, t.label]));
  const typeName = new Map((apptTypes.data ?? []).map((t) => [t.id, t.name]));
  const personName = new Map((people.data ?? []).map((p) => [p.id, `${p.given_name} ${p.family_name}`]));
  const venueName = new Map((venues.data ?? []).map((v) => [v.id, v.name]));
  const k = () => randomUUID();
  const courseTitle = new Map((courseRows.data ?? []).map((c) => [c.id, c.title]));
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

      <h2>Inductions waiting for publication</h2>
      {(inductions.data ?? []).length === 0 ? <p>None.</p> : (
        <ul>{(inductions.data ?? []).map((v) => <li key={v.id}><Link href={`/venue/inductions/${v.id}`}>{courseTitle.get(v.course_id) ?? "Induction"} — version {v.version_no}</Link></li>)}</ul>
      )}

      <PermitDecisions />

      <ScreeningDecisions />

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
                <input type="hidden" name="key" value={k()} />
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
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="engagement_id" value={e.id} />
            <input type="hidden" name="row_version" value={e.row_version} />
          </ActionForm>
        </div>
      ))}

      <h2>Competencies to check</h2>
      <p className="muted">Record what you checked, against which source, for what scope. A check is not a certificate of competence and is separate from reviewing a document.</p>
      {toVerify.length === 0 ? <p>None.</p> : null}
      {toVerify.map((c) => (
        <div className="panel" key={c.id}>
          <p><strong>{personName.get(c.person_id) ?? "Person"}</strong> — {compLabel.get(c.competency_type_id) ?? "Competency"}: {c.issuer} {c.number}, {c.expires_on ? `expires ${date(c.expires_on)}` : "no expiry date given"}
            {c.document_version_id ? <> · <a href={`/api/documents/${c.document_version_id}`}>Supporting document</a></> : null}</p>
          <ActionForm action={verifyCompetency} what="Recording this check" submitLabel="Record check">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="competency_id" value={c.id} />
            <label>How it was checked
              <select name="method" required defaultValue="">
                <option value="">— Choose —</option>
                <option value="issuer_register">The issuer&apos;s register</option>
                <option value="original_seen">The original, seen in person</option>
                <option value="issuer_confirmation">Confirmation from the issuer</option>
              </select>
            </label>
            <label>Source checked<input name="source_checked" required placeholder="e.g. CSCS Smart Check, 25 Oct 2026" /></label>
            <label>The holder matches the person
              <select name="holder_match" required defaultValue=""><option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option></select>
            </label>
            <label>Scope it was checked for<input name="scope" required placeholder="e.g. Operating MEWPs (3a/3b) at the venue" /></label>
            <label>Outcome
              <select name="outcome" required defaultValue=""><option value="">— Choose —</option><option value="verified">Confirmed</option><option value="not_verified">Could not be confirmed</option></select>
            </label>
            <label>Recorded as valid until (optional)<input name="valid_until" type="date" /></label>
            <label>Notes<textarea name="notes" rows={2} /></label>
          </ActionForm>
        </div>
      ))}

      <h2>Appointment type versions to decide</h2>
      <p className="muted">For root appointees (D-011). The person who proposed a version cannot decide it.</p>
      {(typeVersions.data ?? []).length === 0 ? <p>None.</p> : null}
      {(typeVersions.data ?? []).map((v) => (
        <div className="panel" key={v.id}>
          <p><strong>{typeName.get(v.appointment_type_id) ?? "Appointment type"}</strong> — version {v.version_no}, from {date(v.effective_from)}</p>
          <p>{v.allowed_action_codes.length === 0 ? "Allows no actions." : `Allows: ${v.allowed_action_codes.join(", ")}.`}
            {v.is_root_eligible ? " Can be a root appointment." : ""}{v.requires_competence_evidence ? " Needs competence evidence." : ""}</p>
          <p className="muted">Reason given: {v.change_reason}</p>
          <ActionForm action={decideTypeVersion} what="Approving this version" submitLabel="Approve">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={v.id} />
            <input type="hidden" name="row_version" value={v.row_version} />
            <input type="hidden" name="decision" value="approve" />
            <label>Reason<input name="reason" required /></label>
          </ActionForm>
          <ActionForm action={decideTypeVersion} what="Rejecting this version" submitLabel="Reject" secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={v.id} />
            <input type="hidden" name="row_version" value={v.row_version} />
            <input type="hidden" name="decision" value="reject" />
            <label>Reason<input name="reason" required /></label>
          </ActionForm>
        </div>
      ))}

      <h2>Restrictions</h2>
      <p className="muted">A restriction stops a person&apos;s appointed actions, or an organisation&apos;s engagement, at the venue until it is lifted by its owner or an equivalent authority (D-010).</p>
      {(restrictions.data ?? []).length === 0 ? <p>None in force.</p> : null}
      {(restrictions.data ?? []).map((r) => (
        <div className="panel" key={r.id}>
          <p><strong>{r.subject_kind === "person" ? personName.get(r.person_id ?? "") ?? "A person" : orgName.get(r.organisation_id ?? "") ?? "An organisation"}</strong>
            {" "}restricted at {venueName.get(r.venue_id) ?? "the venue"} since {date(r.created_at)}</p>
          <p>Reason: {r.reason}</p>
          <ActionForm action={liftRestriction} what="Lifting this restriction" submitLabel="Lift restriction" secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="restriction_id" value={r.id} />
            <input type="hidden" name="row_version" value={r.row_version} />
            <label>Reason for lifting<input name="reason" required /></label>
          </ActionForm>
        </div>
      ))}
      <h3>Restrict a person or organisation</h3>
      <ActionForm action={imposeRestriction} what="Recording this restriction" submitLabel="Restrict">
        <input type="hidden" name="key" value={k()} />
        <label>Venue<select name="venue_id" required>{(venues.data ?? []).map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label>
        <label>Who
          <select name="subject" required defaultValue="">
            <option value="">— Choose —</option>
            <optgroup label="Organisations">{(orgs.data ?? []).map((o) => <option key={o.id} value={`organisation:${o.id}`}>{o.legal_name}</option>)}</optgroup>
            <optgroup label="People">{(people.data ?? []).filter((p) => !session.personIds.includes(p.id)).map((p) => <option key={p.id} value={`person:${p.id}`}>{p.given_name} {p.family_name}</option>)}</optgroup>
          </select>
        </label>
        <label>Reason<textarea name="reason" required rows={2} /></label>
      </ActionForm>
    </>
  );
}
