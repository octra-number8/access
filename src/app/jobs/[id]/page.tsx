import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { Blocked, type Denial } from "@/components/Blocked";
import { day, HOLD_STATE, isoDay, isoLastDay, JOB_STATE, type JobDetail, lastDay, nextAction, RECOMMENDATION_STATE, requiredClasses, ROLE } from "@/lib/jobs";
import { PERMIT_STATE } from "@/lib/permits";
import { startPermits } from "../../permits/actions";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { acceptRecommendation, addExternalEvidence, cancelJob, challengeRecommendation, reviseJob } from "../actions";
import { organisationPeople, venueAreas } from "../data";
import { JobFields } from "../job-fields";

export const metadata = { title: "Job" };

export default async function Job({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const session = await getSession();
  if (!session) redirect(`/sign-in?next=/jobs/${id}`);
  const db = await supabaseServer();
  const { data } = await db.rpc("work_package_detail", { p_work_package_id: id });
  if (!data?.ok) return <Blocked what="This job" denial={data as Denial} />;
  const j = data as JobDetail;
  const { data: venue } = await db.from("venue").select("customer_id").eq("id", j.venue_id).single();
  const { data: permitRows } = await db.from("permit").select("id, kind, status, permit_class_id").eq("work_package_id", j.id).neq("status", "cancelled");
  const { data: permitClasses } = await db.from("permit_class").select("id, name").in("id", (permitRows ?? []).map((x) => x.permit_class_id));
  const permits = (permitRows ?? []).map((x) => ({ ...x, name: (permitClasses ?? []).find((c) => c.id === x.permit_class_id)?.name ?? "Permit" }))
    .sort((a, b) => (a.kind === "work_approval" ? -1 : b.kind === "work_approval" ? 1 : a.name.localeCompare(b.name)));
  const party = session.organisationAdmin.some((o) => o.organisation_id === j.performing_organisation_id
    || j.revision.parties.some((p) => p.role === "commissioning" && p.organisation_id === o.organisation_id));
  const venueAdmin = Boolean(venue && session.tenantAdminCustomerIds.includes(venue.customer_id));
  const canEdit = (party || venueAdmin) && j.status !== "cancelled";
  const next = nextAction(j);
  const k = () => randomUUID();

  const [areas, people, docs] = canEdit ? await Promise.all([
    venueAreas(db, j.venue_id),
    organisationPeople(db, j.performing_organisation_id),
    db.from("document").select("id, title").or(`organisation_id.eq.${j.performing_organisation_id},provided_via_organisation_id.eq.${j.performing_organisation_id}`),
  ]) : [[], [], { data: [] }];
  const { data: docVersions } = await db.from("document_version").select("id, document_id, version_no")
    .in("document_id", ((docs as { data: Array<{ id: string }> | null }).data ?? []).map((d) => d.id)).order("version_no", { ascending: false });
  const latestDoc = new Map<string, { id: string; title: string }>();
  for (const v of docVersions ?? []) {
    const d = ((docs as { data: Array<{ id: string; title: string }> | null }).data ?? []).find((x) => x.id === v.document_id);
    if (d && !latestDoc.has(d.id)) latestDoc.set(d.id, { id: v.id, title: `${d.title} (v${v.version_no})` });
  }
  const docChoices = [...latestDoc.values()];
  const otherParties = j.revision.parties.filter((p) => p.role !== "performing").map((p) => ({ organisation_id: p.organisation_id, role: p.role }));

  return (
    <>
      <p><Link href="/jobs">All jobs</Link></p>
      <h1>{j.reference} — {j.revision.title}</h1>
      <p>Recorded state: <strong>{JOB_STATE[j.status] ?? j.status}</strong>{j.cancel_reason ? ` (${j.cancel_reason})` : ""}</p>
      {next ? <p>Next: <strong>{next.what}</strong> · <span className="muted">{next.who}</span></p> : null}

      <div className="notice">
        <p className="notice-title">Three separate decisions</p>
        <p>Screening works out which permits this job needs. It does not decide them. <strong>Entry</strong> to the venue is decided at the gate. <strong>Permission to work</strong> comes only from an issued, accepted permit. <strong>Isolations</strong> are applied and proved by a competent person. None of these has been decided here.</p>
      </div>

      {j.status === "draft" && (party || venueAdmin) ? (
        <p><Link href={`/jobs/${j.id}/screening`} className="button">Answer the screening questions</Link></p>
      ) : null}

      <h2>The job</h2>
      <dl className="stack">
        <div><dt className="muted">Performing organisation</dt><dd>{j.performing_organisation}</dd></div>
        <div><dt className="muted">Venue</dt><dd>{j.venue} · {j.work_type}{j.event ? ` · ${j.event}` : ""}</dd></div>
        <div><dt className="muted">Scope</dt><dd>{j.revision.scope}</dd></div>
        {j.revision.method ? <div><dt className="muted">Method</dt><dd>{j.revision.method}</dd></div> : null}
        <div><dt className="muted">When</dt><dd>{day(j.revision.window_from)} to {lastDay(j.revision.window_to)}</dd></div>
        <div><dt className="muted">Where</dt><dd>{j.revision.areas.map((a) => a.name).join(", ")}{j.revision.systems.length ? ` · systems: ${j.revision.systems.map((s) => s.name).join(", ")}` : ""}</dd></div>
        <div><dt className="muted">Contact</dt><dd>{j.revision.contact}</dd></div>
        <div><dt className="muted">Supervisor</dt><dd>{j.revision.supervisor ?? "Not yet named"}</dd></div>
        {otherParties.length ? <div><dt className="muted">Other parties</dt><dd>{j.revision.parties.filter((p) => p.role !== "performing").map((p) => `${p.name} (${ROLE[p.role] ?? p.role})`).join(", ")}</dd></div> : null}
      </dl>

      {j.screening ? (
        <>
          <h2>What screening found</h2>
          <p className="muted">Screened under the venue&apos;s screening version {j.screening.version_no}, approved by {j.screening.approved_by} on {day(j.screening.approved_at)}. Submitted by {j.screening.submitted_by} on {day(j.screening.submitted_at)}.</p>
          {j.recommendations.length === 0 && j.holds.length === 0 ? <p>Screening recommended no permit. That is not a decision: the venue&apos;s screening authority records whether any permit is needed.</p> : null}
          {j.recommendations.map((r) => (
            <div className="panel" key={r.id}>
              <p><strong>{r.class_name}</strong> — {RECOMMENDATION_STATE[r.status] ?? r.status}</p>
              {r.reasons.length > 0 ? <ul>{r.reasons.map((x) => <li key={x.rule_key}>{x.rationale}</li>)}</ul> : null}
              {r.applicant_selected ? <p className="muted">You selected this class yourself.</p> : null}
              {r.challenge ? <p>Challenged by {r.challenge.by} on {day(r.challenge.at)}: {r.challenge.reason}{r.challenge.documents ? ` (${r.challenge.documents} document${r.challenge.documents === 1 ? "" : "s"})` : ""}</p> : null}
              {r.decision ? <p>Decided by {r.decision.by} on {day(r.decision.at)}: {r.decision.reason}</p> : null}
              {r.status === "recommended" && party ? (
                <>
                  <ActionForm action={acceptRecommendation} what="Accepting" submitLabel="Accept: this permit is needed">
                    <input type="hidden" name="key" value={k()} />
                    <input type="hidden" name="recommendation_id" value={r.id} />
                    <input type="hidden" name="row_version" value={r.row_version} />
                  </ActionForm>
                  <details><summary>Challenge this recommendation</summary>
                    <ActionForm action={challengeRecommendation} what="Challenging" submitLabel="Send the challenge" secondary>
                      <input type="hidden" name="key" value={k()} />
                      <input type="hidden" name="recommendation_id" value={r.id} />
                      <input type="hidden" name="row_version" value={r.row_version} />
                      <label>Why you think this permit is not needed<textarea name="reason" required rows={3} /></label>
                      {docChoices.length > 0 ? (
                        <fieldset className="stack"><legend>Supporting documents (optional)</legend>
                          {docChoices.map((d) => <label className="inline" key={d.id}><input type="checkbox" name="document_version_ids" value={d.id} /> {d.title}</label>)}
                        </fieldset>
                      ) : null}
                      <p className="muted">The job stays unresolved until the venue&apos;s authority decides. Waiting never settles it.</p>
                    </ActionForm>
                  </details>
                </>
              ) : null}
            </div>
          ))}
          {j.holds.map((h) => (
            <div className="panel" key={h.id}>
              <p><strong>{h.class_name}</strong> — {HOLD_STATE[h.status] ?? h.status}</p>
              <ul>{h.reasons.map((x) => <li key={x.rule_key}>{x.rationale}</li>)}</ul>
              {h.evidence.map((e, n) => (
                <p key={n} className="muted">Evidence: {e.decider}, {e.organisation}{e.reference ? ` (ref. ${e.reference})` : ""}, {day(e.decided_on)} — {e.scope}{e.conditions ? `. Conditions: ${e.conditions}` : ""}</p>
              ))}
              {h.decision ? <p>Decided by {h.decision.by} on {day(h.decision.at)}: {h.decision.reason}</p> : null}
              {h.status === "open" && party ? (
                <details><summary>Add evidence from the external decision-maker</summary>
                  <ActionForm action={addExternalEvidence} what="Adding evidence" submitLabel="Add evidence">
                    <input type="hidden" name="key" value={k()} />
                    <input type="hidden" name="hold_id" value={h.id} />
                    <label>Who made the decision<input name="decider" required /></label>
                    <label>Their organisation<input name="organisation" required /></label>
                    <label>Their reference (optional)<input name="reference" /></label>
                    <label>What it covers<textarea name="scope" required rows={2} /></label>
                    <label>Date of their decision<input name="decided_on" type="date" required /></label>
                    <label>Their conditions (optional)<textarea name="conditions" rows={2} /></label>
                    {docChoices.length > 0 ? (
                      <fieldset className="stack"><legend>Documents (optional)</legend>
                        {docChoices.map((d) => <label className="inline" key={d.id}><input type="checkbox" name="document_version_ids" value={d.id} /> {d.title}</label>)}
                      </fieldset>
                    ) : null}
                  </ActionForm>
                </details>
              ) : null}
            </div>
          ))}
          {j.no_permit_required.map((n, i) => (
            <div className="panel" key={i}>
              <p><strong>No permit required{n.for_class ? ` (${n.for_class})` : ""}</strong> for: {n.scope}</p>
              <p className="muted">Recorded by {n.by} on {day(n.at)}. Reason: {n.reason}</p>
            </div>
          ))}
          <details><summary>The answers given</summary>
            <ul>{j.screening.answers.map((a, i) => <li key={i}>{a.question} — <strong>{a.answer}</strong></li>)}</ul>
          </details>
        </>
      ) : null}

      {j.status === "routed" ? (
        <>
          <h2>Permits</h2>
          {permits.length === 0 ? (
            requiredClasses(j).length === 0 ? <p>No permit is needed for the job as described.</p> : (
              <>
                <p>The job needs: {requiredClasses(j).join(", ")}, under one Work Approval.</p>
                {party || venueAdmin ? (
                  <ActionForm action={startPermits} what="Starting the permits" submitLabel="Start the permit requests">
                    <input type="hidden" name="key" value={k()} />
                    <input type="hidden" name="work_package_id" value={j.id} />
                  </ActionForm>
                ) : null}
              </>
            )
          ) : (
            <ul>{permits.map((x) => (
              <li key={x.id}><Link href={`/permits/${x.id}`}>{x.name}</Link> — {PERMIT_STATE[x.status] ?? x.status}</li>
            ))}</ul>
          )}
        </>
      ) : null}

      {canEdit ? (
        <details>
          <summary>Change this job</summary>
          <p className="muted">Changing the scope, method, dates, areas or supervisor makes it a different job: any screening result is replaced and it needs screening again. Correcting only the title or contact keeps the result.</p>
          <ActionForm action={reviseJob} what="Changing this job" submitLabel="Save the change">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="work_package_id" value={j.id} />
            <input type="hidden" name="row_version" value={j.row_version} />
            <JobFields areas={areas} people={people} defaults={{
              title: j.revision.title, scope: j.revision.scope, method: j.revision.method,
              start: isoDay(j.revision.window_from), end: isoLastDay(j.revision.window_to),
              contact: j.revision.contact_person_id, supervisor: j.revision.supervisor_person_id,
              areaIds: j.revision.areas.map((a) => a.id), parties: otherParties,
            }} />
            <label>Reason for the change<input name="reason" required /></label>
          </ActionForm>
        </details>
      ) : null}

      <h2>History</h2>
      <ul>{j.revisions.map((r) => (
        <li key={r.no}>Revision {r.no} — {r.kind === "initial" ? "started" : r.kind === "material" ? "changed" : "corrected"} by {r.by} on {day(r.at)}{r.reason ? `: ${r.reason}` : ""}</li>
      ))}</ul>

      {canEdit && (j.status === "draft" || j.status === "screening") ? (
        <details><summary>Cancel this job</summary>
          <ActionForm action={cancelJob} what="Cancelling this job" submitLabel="Cancel the job" secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="work_package_id" value={j.id} />
            <input type="hidden" name="row_version" value={j.row_version} />
            <label>Reason<input name="reason" required /></label>
          </ActionForm>
        </details>
      ) : null}
    </>
  );
}
