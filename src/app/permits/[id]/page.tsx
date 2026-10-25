import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { Blocked, type Denial } from "@/components/Blocked";
import { OUTCOME, PERMIT_STATE, type PermitDetail, STEP_KIND, toVenueLocal, venueTime } from "@/lib/permits";
import { answersOf } from "@/lib/screening/content";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { organisationPeople } from "../../jobs/data";
import {
  acceptPermit, cancelPermit, decideException, issuePermit, reopenStep, requestException, respondToRfi, setTeam, submitPermit,
} from "../actions";
import { DraftForm, StepDecisionForm } from "./forms";

export const metadata = { title: "Permit" };

function timeLeft(to: string): string {
  const ms = new Date(to).getTime() - Date.now();
  if (ms <= 0) return "ended";
  const h = Math.floor(ms / 3_600_000);
  return h >= 48 ? `${Math.floor(h / 24)} days left` : `${h} h ${Math.floor((ms % 3_600_000) / 60_000)} min left`;
}

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
  const supervisorId = p.snapshot?.content.team.find((t) => t.role === "supervisor")?.person_id;
  const isSupervisor = Boolean(supervisorId && session.personIds.includes(supervisorId));
  const preparing = party && (p.status === "draft" || p.status === "more_information_required");
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
  const conditions = p.snapshot ? p.snapshot.content.steps.flatMap((s) => s.decision?.conditions ?? []) : [];

  // ---- The supervisor's view of an issued or active permit (Q104), phone first ----------
  if (p.snapshot && (p.status === "issued_awaiting_acceptance" || p.status === "active" || p.status === "expired")) {
    const s = p.snapshot.content;
    return (
      <section className="mx-auto flex max-w-xl flex-col gap-4">
        <p className="m-0"><Link href={`/jobs/${p.work_package_id}`}>{p.job_reference}</Link> · {p.performing_organisation}</p>
        <div className={`rounded-2xl p-5 ${p.status === "active" ? "bg-surface border-2 border-ink" : "bg-surface border border-line"}`}>
          <p className="m-0 text-sm text-muted">{p.class.name}</p>
          <h1 className="m-0 text-2xl font-extrabold text-ink">{p.status === "active" ? "Active" : PERMIT_STATE[p.status]}</h1>
          <p className="m-0">{s.job.title}</p>
          {p.status === "active" ? <p className="m-0 text-sm">The defined work may proceed within the conditions below. Stop if anything changes.</p> : null}
        </div>
        <dl className="stack m-0">
          <div><dt className="muted">Scope and limits</dt><dd className="m-0">{s.job.scope}{s.job.method ? ` — ${s.job.method}` : ""}</dd></div>
          <div><dt className="muted">Where</dt><dd className="m-0">{s.job.areas.map((a) => a.name).join(", ")}</dd></div>
          <div><dt className="muted">When</dt><dd className="m-0">{venueTime(s.version.window_from, tz)} to {venueTime(s.version.window_to, tz)} · <strong>{timeLeft(s.version.window_to)}</strong></dd></div>
          <div><dt className="muted">Team</dt><dd className="m-0">{s.team.map((t) => `${t.name}${t.role === "supervisor" ? " (supervisor)" : ""}`).join(", ")}</dd></div>
          <div><dt className="muted">Conditions</dt><dd className="m-0">{conditions.length === 0 ? "None" : <ul>{conditions.map((c) => <li key={c.id}>{c.text}</li>)}</ul>}</dd></div>
          {s.exceptions.length ? <div><dt className="muted">Exceptions</dt><dd className="m-0">{s.exceptions.map((e, i) => <p key={i} className="m-0">{e.kind === "late_notice" ? "Late notice" : "Restriction"}: {e.outcome}{e.conditions ? ` — ${e.conditions}` : ""}</p>)}</dd></div> : null}
          <div><dt className="muted">Linked permits</dt><dd className="m-0">{p.parent ? `${p.parent.class_name}: ${PERMIT_STATE[p.parent.status]}` : p.children.length === 0 ? "None" : p.children.map((c) => `${c.class_name}: ${PERMIT_STATE[c.status]}`).join("; ")}</dd></div>
          <div><dt className="muted">Issued</dt><dd className="m-0">by {p.snapshot.issuer} at {venueTime(p.snapshot.issued_at, tz)}</dd></div>
          <div><dt className="muted">Stop work</dt><dd className="m-0">Anyone may stop unsafe work. Tell the venue&apos;s control room and your supervisor at once.</dd></div>
        </dl>
        {p.acceptance ? <p className="notice m-0">Accepted by {p.acceptance.by} at {venueTime(p.acceptance.accepted_at, tz)} after briefing {p.acceptance.briefed.join(", ")}.</p> : null}
        {p.status === "issued_awaiting_acceptance" && isSupervisor ? (
          <ActionForm action={acceptPermit} what="Accepting this permit" submitLabel="Accept the permit">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="permit_id" value={p.id} />
            <input type="hidden" name="row_version" value={p.row_version} />
            {conditions.filter((c) => c.acknowledge).length > 0 ? (
              <fieldset className="stack"><legend>Acknowledge each condition</legend>
                {conditions.filter((c) => c.acknowledge).map((c) => <label key={c.id} className="flex min-h-11 items-center gap-3"><input type="checkbox" name="acknowledged" value={c.id} required /> {c.text}</label>)}
              </fieldset>
            ) : null}
            <fieldset className="stack"><legend>Who did you brief at the workface? (Q103)</legend>
              {s.team.map((t) => <label key={t.person_id} className="flex min-h-11 items-center gap-3"><input type="checkbox" name="briefed" value={t.person_id} /> {t.name}</label>)}
            </fieldset>
            <fieldset className="stack"><legend>Declaration</legend>
              {s.class_version.acceptance_declaration.map((d, i) => <label key={i} className="flex min-h-11 items-center gap-3"><input type="checkbox" required /> {d}</label>)}
            </fieldset>
            <p className="text-sm muted m-0">Acceptance uses the live record: it cannot be done offline.</p>
          </ActionForm>
        ) : p.status === "issued_awaiting_acceptance" ? <p className="muted">Waiting for the named supervisor to accept it at the workface.</p> : null}
      </section>
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
    </>
  );
}
