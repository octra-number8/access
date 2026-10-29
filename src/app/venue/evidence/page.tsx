import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { createCompetencyType } from "../../admin-actions";
import { createDocumentType, createEvidenceRequirement, publishRequirementVersion, publishReviewCriteria } from "../../events-evidence-actions";

export const metadata = { title: "Evidence settings" };

type VersionState = "current" | "scheduled" | "superseded";
interface CriteriaVersion {
  id: string; version_no: number; criteria: Array<{ code: string; label: string }>; owner: string; effective_from: string;
  change_reason: string; state: VersionState;
}
interface DocumentType { id: string; code: string; label: string; owner_level: "organisation" | "person"; criteria: CriteriaVersion[] }
interface RequirementVersion { version_no: number; in_force: boolean; owner: string; effective_from: string; change_reason: string; state: VersionState }
interface Requirement { id: string; code: string; label: string; applies_to: string; requires: string; in_force: boolean; versions: RequirementVersion[] }
interface Settings {
  ok: true; venue: { id: string; name: string; timezone: string }; can_manage: boolean;
  capacities: Array<{ code: string; label: string }>; appointment_types: Array<{ id: string; name: string }>;
  competency_types: Array<{ id: string; code: string; label: string }>; document_types: DocumentType[]; requirements: Requirement[];
  people: Array<{ id: string; name: string }> | null;
}

const STATE: Record<VersionState, string> = { current: "current", scheduled: "takes effect later", superseded: "superseded" };
const CODE_HINT = "Letters, numbers, - and _ only, up to 40 characters. It cannot be changed later.";

// S1c (D-026, S1-10): what evidence the venue asks of organisations and appointees, and the
// criteria its reviewers apply. Nothing has a default: a venue with no requirements asks for no
// evidence. Recording a requirement or criteria says what is asked; it does not decide whether
// any document or competency is adequate, which stays with the appointed reviewer.
export default async function EvidenceSettings({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/evidence");
  const db = await supabaseServer();
  const { data: scopes } = await db.rpc("report_scopes");
  const venues = ((scopes as { venues?: Array<{ id: string; name: string }> } | null)?.venues ?? []);
  const { venue: chosen } = await searchParams;
  const venueId = venues.some((v) => v.id === chosen) ? chosen! : venues[0]?.id;
  const { data } = venueId ? await db.rpc("evidence_settings", { p_venue_id: venueId }) : { data: null };
  if (!data?.ok) {
    return <><h1>Evidence settings</h1><p>This page is for a venue&apos;s administrators and the people it has appointed, and you are neither at any venue. If you need to see it, ask the venue&apos;s administrator.</p></>;
  }
  const o = data as Settings;
  const tz = o.venue.timezone;
  const k = () => randomUUID();
  const me = o.people?.find((p) => session.personIds.includes(p.id))?.id ?? "";

  // The owner, effective date and reason every published version carries.
  const versionFields = (id: string) => (
    <>
      <input type="hidden" name="tz" value={tz} />
      <label>Owner<select name="owner_person_id" required defaultValue={me}>
        <option value="" disabled>Choose the person accountable for it</option>
        {(o.people ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
      <label>Takes effect (leave empty for now)<input type="datetime-local" name="effective_from" aria-describedby={`eff-${id}`} /></label>
      <p id={`eff-${id}`} className="muted text-sm m-0">It must be later than the latest version already published. Published versions cannot be changed; publish a new one instead.</p>
      <label>Reason<input name="reason" required maxLength={1000} placeholder="For example: agreed with the insurer" /></label>
    </>
  );

  return (
    <>
      <p><Link href="/venue">Venue administration</Link> · <Link href="/venue/setup">Set-up</Link></p>
      <h1>Evidence settings — {o.venue.name}</h1>
      <div className="notice">
        <p>Octra asks for no evidence by default. A requirement says which organisations or appointees must provide which document or competency; it applies only once a version putting it in force takes effect. Review criteria are what the venue&apos;s reviewers record a result against for each document.</p>
        <p className="m-0">These settings say what is asked for. They do not make any document or competency adequate: that is the judgement of the person appointed to review it.</p>
      </div>
      {venues.length > 1 ? (
        <form className="no-print"><label>Venue <select name="venue" defaultValue={o.venue.id}>{venues.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label> <button type="submit" className="secondary">Show</button></form>
      ) : null}
      {!o.can_manage ? <p className="muted">You can see these records. Only the venue&apos;s tenant administrators can change them.</p> : null}

      <h2>Evidence requirements</h2>
      {o.requirements.length === 0 ? <p><strong>None defined.</strong> No evidence is asked of organisations or appointees at this venue.</p> : null}
      {o.requirements.map((r) => (
        <section key={r.id} className="panel" style={{ maxWidth: "none" }} aria-labelledby={`rq-${r.id}`}>
          <h3 id={`rq-${r.id}`} className="m-0">{r.label} <span className="muted text-sm">({r.code})</span></h3>
          <p className="m-0">{r.applies_to} must provide: <strong>{r.requires}</strong></p>
          <p><strong>{r.in_force ? "In force" : "Not in force"}</strong>{r.versions.length === 0 ? <span className="muted"> — no version published, so nothing is asked yet</span> : null}</p>
          {r.versions.length ? (
            <ul>{r.versions.map((v) => (
              <li key={v.version_no} className="text-sm">Version {v.version_no}: {v.in_force ? "in force" : "not in force"} from {venueTime(v.effective_from, tz)} ({STATE[v.state]}) · owner {v.owner} · {v.change_reason}</li>
            ))}</ul>
          ) : null}
          {o.can_manage ? (
            <details><summary className="text-sm" aria-label={`Publish a version of ${r.label}`}>Publish a version</summary>
              <ActionForm action={publishRequirementVersion} what="Publishing the version" submitLabel="Publish version">
                <input type="hidden" name="key" value={k()} /><input type="hidden" name="requirement_id" value={r.id} />
                <label>From then on, this requirement is<select name="in_force" required defaultValue="">
                  <option value="" disabled>Choose</option><option value="yes">In force</option><option value="no">Not in force</option></select></label>
                {versionFields(r.id)}
              </ActionForm>
            </details>
          ) : null}
        </section>
      ))}
      {o.can_manage ? (
        <details className="panel" style={{ maxWidth: "none" }}><summary><strong>Define an evidence requirement</strong></summary>
          {o.document_types.length + o.competency_types.length === 0 ? <p>Add a document type or competency type first (below).</p> : (
            <ActionForm action={createEvidenceRequirement} what="Defining the requirement" submitLabel="Define requirement">
              <input type="hidden" name="key" value={k()} /><input type="hidden" name="venue_id" value={o.venue.id} />
              <label>Applies to<select name="applies_to" required defaultValue="">
                <option value="" disabled>Choose who must provide it</option>
                <optgroup label="Organisations engaged as">{o.capacities.map((c) => <option key={c.code} value={`capacity:${c.code}`}>{c.label}</option>)}</optgroup>
                {o.appointment_types.length ? <optgroup label="People appointed as">{o.appointment_types.map((t) => <option key={t.id} value={`appointment:${t.id}`}>{t.name}</option>)}</optgroup> : null}
              </select></label>
              <label>Asks for<select name="requires" required defaultValue="">
                <option value="" disabled>Choose what they must provide</option>
                {o.document_types.length ? <optgroup label="A document">{o.document_types.map((t) => <option key={t.id} value={`document:${t.id}`}>{t.label} ({t.owner_level === "organisation" ? "organisation" : "person"} document)</option>)}</optgroup> : null}
                {o.competency_types.length ? <optgroup label="A competency (appointees only)">{o.competency_types.map((t) => <option key={t.id} value={`competency:${t.id}`}>{t.label}</option>)}</optgroup> : null}
              </select></label>
              <p className="muted text-sm m-0">Organisations provide organisation documents. Appointees provide their own documents or competencies.</p>
              <label>Name<input name="label" required maxLength={200} placeholder="For example: Public liability insurance for contractors" /></label>
              <label>Code<input name="code" required pattern="[A-Za-z0-9_\-]{1,40}" maxLength={40} aria-describedby="code-rq" /></label>
              <p id="code-rq" className="muted text-sm m-0">{CODE_HINT} The requirement asks for nothing until you publish a version putting it in force.</p>
            </ActionForm>
          )}
        </details>
      ) : null}

      <h2>Document types and review criteria</h2>
      {o.document_types.length === 0 ? <p>None yet.</p> : null}
      {o.document_types.map((t) => {
        const current = t.criteria.find((c) => c.state === "current");
        const latest = t.criteria[0];
        return (
          <section key={t.id} className="panel" style={{ maxWidth: "none" }} aria-labelledby={`dt-${t.id}`}>
            <h3 id={`dt-${t.id}`} className="m-0">{t.label} <span className="muted text-sm">({t.code}) · held by {t.owner_level === "organisation" ? "an organisation" : "a person"}</span></h3>
            {current ? (
              <>
                <p className="m-0">Reviewers record a result against each of these (version {current.version_no}, from {venueTime(current.effective_from, tz)}, owner {current.owner}):</p>
                <ul>{current.criteria.map((c) => <li key={c.code}>{c.label}</li>)}</ul>
              </>
            ) : <p><strong>No review criteria in force.</strong> Documents of this type cannot be reviewed until criteria are published.</p>}
            {t.criteria.filter((c) => c.state !== "current").length ? (
              <details><summary className="text-sm">Other versions</summary>
                <ul>{t.criteria.filter((c) => c.state !== "current").map((c) => (
                  <li key={c.id} className="text-sm">Version {c.version_no} from {venueTime(c.effective_from, tz)} ({STATE[c.state]}) · owner {c.owner} · {c.change_reason}
                    <div className="muted">{c.criteria.map((x) => x.label).join("; ")}</div></li>
                ))}</ul>
              </details>
            ) : null}
            {o.can_manage ? (
              <details><summary className="text-sm" aria-label={`Publish review criteria for ${t.label}`}>Publish review criteria</summary>
                <ActionForm action={publishReviewCriteria} what="Publishing the criteria" submitLabel="Publish criteria">
                  <input type="hidden" name="key" value={k()} /><input type="hidden" name="document_type_id" value={t.id} />
                  <label>Criteria, one per line<textarea name="criteria" required rows={4} maxLength={5000} aria-describedby={`crit-${t.id}`}
                    defaultValue={(latest?.criteria ?? []).map((c) => c.label).join("\n")} /></label>
                  <p id={`crit-${t.id}`} className="muted text-sm m-0">Write each as something a reviewer can check, for example: &quot;Cover is in date for the whole engagement&quot;.</p>
                  {versionFields(t.id)}
                </ActionForm>
              </details>
            ) : null}
          </section>
        );
      })}
      {o.can_manage ? (
        <details className="panel" style={{ maxWidth: "none" }}><summary><strong>Add a document type</strong></summary>
          <ActionForm action={createDocumentType} what="Adding the document type" submitLabel="Add document type">
            <input type="hidden" name="key" value={k()} /><input type="hidden" name="venue_id" value={o.venue.id} />
            <label>Name<input name="label" required maxLength={200} placeholder="For example: Public liability insurance" /></label>
            <label>Held by<select name="owner_level" required defaultValue="">
              <option value="" disabled>Choose</option><option value="organisation">An organisation</option><option value="person">A person</option></select></label>
            <label>Code<input name="code" required pattern="[A-Za-z0-9_\-]{1,40}" maxLength={40} aria-describedby="code-dt" /></label>
            <p id="code-dt" className="muted text-sm m-0">{CODE_HINT}</p>
          </ActionForm>
        </details>
      ) : null}

      <h2>Competency types</h2>
      <p className="muted">The cards and qualifications people can declare, for example CSCS or IPAF. Checking them is a separate act by an appointed person.</p>
      <p>{o.competency_types.length ? o.competency_types.map((t) => `${t.label} (${t.code})`).join(", ") : <span className="muted">None yet.</span>}</p>
      {o.can_manage ? (
        <details className="panel" style={{ maxWidth: "none" }}><summary><strong>Add a competency type</strong></summary>
          <ActionForm action={createCompetencyType} what="Adding this competency type" submitLabel="Add competency type">
            <input type="hidden" name="key" value={k()} /><input type="hidden" name="venue_id" value={o.venue.id} />
            <label>Name<input name="label" required maxLength={200} placeholder="For example: IPAF 3a/3b" /></label>
            <label>Code<input name="code" required pattern="[A-Za-z0-9_\-]{1,40}" maxLength={40} aria-describedby="code-ct" /></label>
            <p id="code-ct" className="muted text-sm m-0">{CODE_HINT}</p>
          </ActionForm>
        </details>
      ) : null}
    </>
  );
}
