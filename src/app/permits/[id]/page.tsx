import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { Blocked, type Denial } from "@/components/Blocked";
import { HistoryPanel } from "@/components/history-panel";
import { PermitEvidence } from "@/components/permit-evidence";
import { OUTCOME, PERMIT_STATE, type PermitDetail, STEP_KIND, toVenueLocal, venueTime } from "@/lib/permits";
import { answersOf } from "@/lib/screening/content";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { organisationPeople } from "../../jobs/data";
import {
  cancelPermit, decideException, issuePermit, reopenStep, requestException, respondToRfi, setTeam, submitPermit,
} from "../actions";
import { DraftForm, StepDecisionForm } from "./forms";
import { LivePermit } from "./live";

export const metadata = { title: "Permit" };

export default async function Permit({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const session = await getSession();
  if (!session) redirect(`/sign-in?next=/permits/${id}`);
  const db = await supabaseServer();
  const { data } = await db.rpc("permit_detail", { p_permit_id: id });
  if (!data?.ok) return <Blocked what="This permit" denial={data as Denial} />;
  const p = data as PermitDetail;
  const tz = p.venue_timezone;
  const k = () => randomUUID();
  const party = session.organisationAdmin.some((o) => o.organisation_id === p.performing_organisation_id);
  const appointee = session.appointmentVenueIds.includes(p.venue_id);
  const preparing = party && (p.status === "draft" || p.status === "more_information_required" || p.reissue_pending);
  const questions = p.class_version?.content.questions ?? [];
  const answersFor = (a: Record<string, string[]>) => questions.filter((q) => a[q.key]?.length)
    .map((q) => ({ q: q.text, a: a[q.key]!.map((x) => answersOf(q).find((o) => o.key === x)?.text ?? x).join(", ") }));

  const [people, docs] = preparing || (party && p.status !== "cancelled") ? await Promise.all([
    organisationPeople(db, p.performing_organisation_id),
    db.from("document").select("id, title").or(`organisation_id.eq.${p.performing_organisation_id},provided_via_organisation_id.eq.${p.performing_organisation_id}`),
  ]) : [[], { data: [] }];
  const { data: docVersions } = await db.from("document_version").select("id, document_id, version_no")
    .in("document_id", ((docs as { data: Array<{ id: string }> | null }).data ?? []).map((d) => d.id)).order("version_no", { ascending: false });
  const latestDocs = new Map<string, { id: string; title: string }>();
  for (const v of docVersions ?? []) {
    const d = ((docs as { data: Array<{ id: string; title: string }> | null }).data ?? []).find((x) => x.id === v.document_id);
    if (d && !latestDocs.has(d.id)) latestDocs.set(d.id, { id: v.id, title: `${d.title} (v${v.version_no})` });
  }
  const openRfi = p.status === "more_information_required" ? p.rfis.find((r) => !r.responses) : null;

  // ---- The live permit (Q104, phase 6): the supervisor's view on a phone, and each authority's actions ----
  if (p.snapshot && ["issued_awaiting_acceptance", "active", "suspended", "hand_back_pending", "expired", "closed"].includes(p.status)) {
    const [team, { data: systems }, { data: areas }] = await Promise.all([
      organisationPeople(db, p.performing_organisation_id),
      db.from("system").select("id, name").eq("venue_id", p.venue_id).is("retired_at", null).order("name"),
      db.from("area").select("id, name").in("id", p.close_out.live_area_ids),
    ]);
    return (
      <>
        <LivePermit p={p} session={session} k={k} people={team} systems={systems ?? []}
          areaNames={new Map((areas ?? []).map((a) => [a.id, a.name]))} />
        {preparing ? (
          <section className="mx-auto mt-6 max-w-xl">
            <h2>Prepare the request again</h2>
            {p.draft_problems?.length ? <ul className="notice notice-blocked">{p.draft_problems.map((x) => <li key={x}>{x}</li>)}</ul> : null}
            <DraftForm permitId={p.id} newKey={k()} questions={questions} answers={p.draft.answers}
              windowFrom={toVenueLocal(p.draft.window_from, tz)} windowTo={toVenueLocal(p.draft.window_to, tz)}
              documents={[...latestDocs.values()]} chosenDocuments={p.draft.document_version_ids} tz={tz} />
          </section>
        ) : null}
        <div className="mx-auto max-w-3xl">
          <PermitEvidence permitId={p.id} tz={tz} />
          <HistoryPanel kind="permit" id={p.id} />
        </div>
      </>
    );
  }

  // ---- Everyone else: the request, its route and its decisions ----------------------------
  return (
    <>
      <p><Link href={`/jobs/${p.work_package_id}`}>{p.job_reference} — {p.job_title}</Link></p>
      <h1>{p.class.name}{p.kind === "work_approval" ? "" : " permit"}</h1>
      <p>Recorded state: <strong>{PERMIT_STATE[p.status] ?? p.status}</strong>{p.version ? ` · version ${p.version.no}` : ""} · {p.performing_organisation}</p>
      {p.parent ? <p className="muted">Part of the job&apos;s <Link href={`/permits/${p.parent.id}`}>{p.parent.class_name}</Link> ({PERMIT_STATE[p.parent.status]}).</p> : null}
      {p.children.length ? <p className="muted">Linked permits: {p.children.map((c, i) => <span key={c.id}>{i ? ", " : ""}<Link href={`/permits/${c.id}`}>{c.class_name}</Link> ({PERMIT_STATE[c.status]})</span>)}</p> : null}

      <div className="notice">
        <p className="m-0">A permit records that the defined work may proceed under stated conditions once it is issued and accepted. It is not permission to enter the venue, and it does not apply isolations.</p>
      </div>

      {p.notice.known ? (
        <p>Notice: {p.notice.compliant ? "met" : <strong>not met</strong>}. Earliest start allowed: {venueTime(p.notice.earliest_start, tz)}.</p>
      ) : <p className="notice notice-blocked">{p.notice.problem}</p>}

      {preparing ? (
        <>
          <h2>{p.status === "draft" ? "Prepare the request" : "Update the request for the information asked"}</h2>
          {p.draft_problems?.length ? <ul className="notice notice-blocked">{p.draft_problems.map((x) => <li key={x}>{x}</li>)}</ul> : null}
          <DraftForm permitId={p.id} newKey={k()} questions={questions} answers={p.draft.answers}
            windowFrom={toVenueLocal(p.draft.window_from, tz)} windowTo={toVenueLocal(p.draft.window_to, tz)}
            documents={[...latestDocs.values()]} chosenDocuments={p.draft.document_version_ids} tz={tz} />
        </>
      ) : null}

      {party && !["cancelled", "refused", "expired"].includes(p.status) ? (
        <>
          <h2>Supervisor and team</h2>
          {p.team.length ? <p>{p.team.map((t) => `${t.name}${t.role === "supervisor" ? " (supervisor)" : ""}`).join(", ")}</p> : <p>Not named yet. A permit cannot be issued without a supervisor.</p>}
          {people.length > 0 && p.status !== "issued_awaiting_acceptance" ? (
            <details><summary>Name the team</summary>
              <ActionForm action={setTeam} what="Saving the team" submitLabel="Save team">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="permit_id" value={p.id} />
                <label>Supervisor
                  <select name="supervisor" required defaultValue={p.team.find((t) => t.role === "supervisor")?.person_id}>
                    {people.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
                  </select>
                </label>
                <fieldset className="stack"><legend>Operatives</legend>
                  {people.map((x) => <label className="inline" key={x.id}><input type="checkbox" name="operatives" value={x.id} defaultChecked={p.team.some((t) => t.person_id === x.id && t.role === "operative")} /> {x.name}</label>)}
                </fieldset>
              </ActionForm>
            </details>
          ) : null}
        </>
      ) : null}

      {party && p.status === "draft" ? (
        <>
          <h2>Submit</h2>
          <ActionForm action={submitPermit} what="Submitting this request" submitLabel="Submit to the venue">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="permit_id" value={p.id} />
            <input type="hidden" name="row_version" value={p.row_version} />
            <ul>{(p.class_version?.content.submission_declaration ?? []).map((d, i) => <li key={i}>{d}</li>)}</ul>
            <label className="inline"><input type="checkbox" name="confirm" /> I make this declaration for {p.performing_organisation} (Q68)</label>
          </ActionForm>
        </>
      ) : null}

      {party && openRfi ? (
        <>
          <h2>Information asked for</h2>
          <p><strong>{openRfi.asked_by}</strong> ({openRfi.step}): {openRfi.message}</p>
          <ActionForm action={respondToRfi} what="Sending the response" submitLabel="Send response and resubmit">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="permit_id" value={p.id} />
            <input type="hidden" name="row_version" value={p.row_version} />
            {openRfi.items.map((it, i) => <label key={i}>{it.text}<textarea name="responses" required rows={2} /></label>)}
            <p className="muted">Save any changes to the request above first. The response becomes a new version, and every step decides again.</p>
            <label className="inline"><input type="checkbox" name="confirm" /> I make the submission declaration again for {p.performing_organisation}</label>
          </ActionForm>
        </>
      ) : null}

      {p.version ? (
        <>
          <h2>The request (version {p.version.no})</h2>
          <p className="muted">Submitted by {p.version.declared_by} at {venueTime(p.version.submitted_at, tz)}. Window {venueTime(p.version.window_from, tz)} to {venueTime(p.version.window_to, tz)}.</p>
          {answersFor(p.version.answers).length ? <ul>{answersFor(p.version.answers).map((x) => <li key={x.q}>{x.q} — <strong>{x.a}</strong></li>)}</ul> : null}
          {p.version.documents.length ? <p>Documents: {p.version.documents.map((d) => `${d.title} (v${d.version_no})`).join(", ")}</p> : null}

          <h2>Approval route</h2>
          {p.steps.map((s) => (
            <div className="panel" key={s.id}>
              <p className="m-0"><strong>{s.name}</strong> <span className="muted">· {STEP_KIND[s.kind]} · group {s.group}{s.party ? ` · ${s.party}` : ""} · {s.areas.join(", ")}</span></p>
              {s.decision && s.decision.outcome !== "reopened" ? (
                <>
                  <p className="m-0">{OUTCOME[s.decision.outcome]} — {s.decision.by}, {venueTime(s.decision.at, tz)}</p>
                  {s.decision.scope_wording ? <p className="m-0 muted">{s.decision.scope_wording}</p> : null}
                  <p className="m-0 muted">Reason: {s.decision.reason}</p>
                  {s.decision.conditions.length ? <ul>{s.decision.conditions.map((c) => <li key={c.id}>{c.text}{c.acknowledge ? " (acknowledged at acceptance)" : ""}</li>)}</ul> : null}
                  {session.personIds.includes(s.decision.by_person_id) && ["no_further_comments", "conditions", "not_applicable"].includes(s.decision.outcome)
                    && ["submitted", "under_review", "approved_for_issue"].includes(p.status) ? (
                    <details><summary>Withdraw my decision (Q83)</summary>
                      <ActionForm action={reopenStep} what="Withdrawing this decision" submitLabel="Withdraw" secondary>
                        <input type="hidden" name="key" value={k()} />
                        <input type="hidden" name="step_id" value={s.id} />
                        <label>Why<input name="reason" required /></label>
                      </ActionForm>
                    </details>
                  ) : null}
                </>
              ) : s.open ? (
                appointee ? <StepDecisionForm stepId={s.id} kind={s.kind} newKey={k()} previous={s.previous} /> : <p className="m-0 muted">Waiting for the venue&apos;s reviewer.</p>
              ) : <p className="m-0 muted">{p.status === "more_information_required" ? "Paused while the applicant answers." : "Waits for an earlier group."}</p>}
            </div>
          ))}
        </>
      ) : null}

      {p.version && !["draft", "cancelled", "refused", "expired"].includes(p.status)
        && (p.exceptions.length > 0 || p.restrictions.length > 0 || (party && p.notice.known && !p.notice.compliant)) ? (
        <>
          <h2>Late notice and restrictions</h2>
          {p.restrictions.map((r) => <p key={r.id}>{r.effect === "no_work" ? "No work allowed" : "A decision is needed"}: {r.reason} ({venueTime(r.from, tz)} to {venueTime(r.to, tz)})</p>)}
          {p.exceptions.map((e) => (
            <div className="panel" key={e.id}>
              <p className="m-0"><strong>{e.kind === "late_notice" ? "Late notice" : `Restriction: ${e.restriction}`}</strong> — asked by {e.by}: {e.reason.replace(/\.$/, "")}. If it waits: {e.consequence}</p>
              {e.decision ? <p className="m-0">{e.decision.outcome === "allowed" ? "Allowed" : "Refused"} by {e.decision.by}: {e.decision.reason}{e.decision.conditions ? ` — ${e.decision.conditions}` : ""}</p>
                : appointee ? (
                  <>
                    <ActionForm action={decideException} what="Allowing this exception" submitLabel="Allow">
                      <input type="hidden" name="key" value={k()} />
                      <input type="hidden" name="request_id" value={e.id} />
                      <input type="hidden" name="outcome" value="allowed" />
                      <label>Reduced scope or conditions (optional)<input name="conditions" /></label>
                      <label>Reason<input name="reason" required /></label>
                    </ActionForm>
                    <ActionForm action={decideException} what="Refusing this exception" submitLabel="Refuse" secondary>
                      <input type="hidden" name="key" value={k()} />
                      <input type="hidden" name="request_id" value={e.id} />
                      <input type="hidden" name="outcome" value="refused" />
                      <label>Reason<input name="reason" required /></label>
                    </ActionForm>
                  </>
                ) : <p className="m-0 muted">Waiting for the venue&apos;s authority.</p>}
            </div>
          ))}
          {party && ((!p.notice.compliant && !p.exceptions.some((e) => e.kind === "late_notice"))
                     || p.restrictions.some((r) => r.effect === "decision_required" && !p.exceptions.some((e) => e.restriction === r.reason))) ? (
            <details><summary>Ask for an exception</summary>
              <ActionForm action={requestException} what="Asking for an exception" submitLabel="Ask">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="permit_id" value={p.id} />
                <label>For
                  <select name="kind_and_window" required defaultValue="">
                    <option value="">— Choose —</option>
                    {!p.notice.compliant && !p.exceptions.some((e) => e.kind === "late_notice") ? <option value="late_notice">Late notice</option> : null}
                    {p.restrictions.filter((r) => r.effect === "decision_required" && !p.exceptions.some((e) => e.restriction === r.reason)).map((r) => <option key={r.id} value={`restriction_conflict:${r.id}`}>Restriction: {r.reason}</option>)}
                  </select>
                </label>
                <label>Why it cannot wait<textarea name="reason" required rows={2} /></label>
                <label>What happens if it waits (Q94)<textarea name="consequence" required rows={2} /></label>
              </ActionForm>
            </details>
          ) : null}
        </>
      ) : null}

      {p.status === "approved_for_issue" ? (
        <>
          <h2>Issue</h2>
          {p.blockers && p.blockers.length > 0 ? (
            <div className="notice notice-blocked">
              <p className="notice-title">Not ready to issue</p>
              <ul>{p.blockers.map((b, i) => <li key={i}>{b.problem} <span className="muted">— {b.who}</span></li>)}</ul>
            </div>
          ) : <p>Every pre-issue check passes (Q99).</p>}
          {appointee ? (
            <ActionForm action={issuePermit} what="Issuing this permit" submitLabel="Issue the permit">
              <input type="hidden" name="key" value={k()} />
              <input type="hidden" name="permit_id" value={p.id} />
              <input type="hidden" name="row_version" value={p.row_version} />
              <p className="muted">Issuing freezes everything above. You cannot issue a permit you reviewed (P5-10).</p>
            </ActionForm>
          ) : null}
        </>
      ) : null}

      {p.rfis.length ? (
        <details><summary>Information requests ({p.rfis.length})</summary>
          {p.rfis.map((r) => (
            <div key={r.id} className="panel">
              <p className="m-0">Version {r.version_no}: {r.asked_by} ({r.step}) — {r.message}</p>
              <ul>{r.items.map((it, i) => <li key={i}>{it.text}{r.responses ? <> — <strong>{r.responses[i]}</strong></> : null}</li>)}</ul>
            </div>
          ))}
        </details>
      ) : null}
      {p.versions.length > 1 ? <p className="muted">Versions: {p.versions.map((v) => `v${v.no} by ${v.by}${v.responds_to_rfi ? " (response)" : ""}`).join(", ")}</p> : null}

      {party && ["draft", "submitted", "under_review", "more_information_required", "approved_for_issue"].includes(p.status) ? (
        <details><summary>Cancel this request</summary>
          <ActionForm action={cancelPermit} what="Cancelling this request" submitLabel="Cancel the request" secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="permit_id" value={p.id} />
            <input type="hidden" name="row_version" value={p.row_version} />
            <label>Reason<input name="reason" required /></label>
          </ActionForm>
        </details>
      ) : null}

      <PermitEvidence permitId={p.id} tz={tz} />
      <HistoryPanel kind="permit" id={p.id} />
    </>
  );
}
