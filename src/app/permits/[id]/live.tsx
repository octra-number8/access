import Link from "next/link";
import { ActionForm } from "@/components/ActionForm";
import {
  CONTROL_KIND, CONTROL_STATE, PERMIT_STATE, type PermitDetail, STOP_CATEGORY, SUSPENSION_KIND, timeLeft, toVenueLocal, venueTime,
} from "@/lib/permits";
import type { Session } from "@/lib/session";
import { acceptPermit, submitPermit } from "../actions";
import {
  acknowledgeExtension, addWorker, approveWorker, arrangeFireWatch, briefWorker, cancelIssued, changeSupervisor, checkFireWatch,
  decideAreaReturn, decideHandBack, endFireWatch, excludeWorker, extendPermit, flagAbandoned, handBack, liftSuspension, lockOff, lockOn,
  reacceptPermit, removeZone, reportFailure, requestControl, returnAreas, revalidatePermit, setUpZone, startFireWatch, stopWork,
} from "../live-actions";

type Option = { id: string; name: string };

/** What a recorded state means for the work, in words (CLAUDE.md §2: a status records a decision). */
const HEADLINE: Record<string, [string, string]> = {
  active: ["Active", "The defined work may proceed within the scope, limits and conditions below. Stop if anything changes."],
  issued_awaiting_acceptance: ["Issued, awaiting acceptance", "No work yet: the named supervisor accepts it at the workface after briefing the team."],
  suspended: ["Stopped", "Do not work. The work restarts only when every stop below is lifted and the supervisor re-accepts."],
  hand_back_pending: ["Handed back", "No work. Waiting for the hand-back to be accepted."],
  expired: ["Expired", "No work. The permit's time has ended; anything still outstanding must be closed out."],
  closed: ["Closed", "Handed back and accepted. This permit authorises nothing."],
  cancelled: ["Cancelled", "This permit authorises nothing."],
};

/** The live permit: the supervisor's view on a phone, and each authority's actions on it. */
export function LivePermit({ p, session, k, people, systems, areaNames }: {
  p: PermitDetail; session: Session; k: () => string; people: Option[]; systems: Option[]; areaNames: Map<string, string>;
}) {
  const tz = p.venue_timezone;
  const s = p.snapshot!.content;
  const me = (id: string) => session.personIds.includes(id);
  const live = p.team_live.filter((m) => !m.removed_at);
  const isSupervisor = live.some((m) => m.role === "supervisor" && me(m.person_id));
  const onTeam = live.some((m) => me(m.person_id));
  const appointee = session.appointmentVenueIds.includes(p.venue_id);
  const party = session.organisationAdmin.some((o) => o.organisation_id === p.performing_organisation_id);
  const isLive = ["issued_awaiting_acceptance", "active", "suspended"].includes(p.status);
  const conditions = s.steps.flatMap((x) => x.decision?.conditions ?? []);
  const liftConditions = p.open_lifts.filter((l) => l.conditions.length > 0);
  const holding = p.suspensions.filter((x) => x.holding);
  const [title, meaning] = HEADLINE[p.status] ?? [PERMIT_STATE[p.status] ?? p.status, ""];
  const pendingExtension = p.extensions.find((e) => !e.acknowledged_at);
  const liveAreas = p.close_out.live_area_ids.map((id) => ({ id, name: areaNames.get(id) ?? "An area" }));
  const counted = live.filter((m) => m.counts);
  const hidden = (name: string, value: string | number) => <input type="hidden" name={name} value={value} />;
  const ids = <>{hidden("permit_id", p.id)}{hidden("row_version", p.row_version)}</>;

  return (
    <section className="mx-auto flex max-w-xl flex-col gap-4">
      <p className="m-0"><Link href={`/jobs/${p.work_package_id}`}>{p.job_reference}</Link> · {p.performing_organisation}</p>

      <div className={`rounded-2xl p-5 bg-surface ${p.status === "active" ? "border-2 border-ink" : "border border-line"}`}>
        <p className="m-0 text-sm text-muted">{p.class.name}{p.kind === "work_approval" ? "" : " permit"}</p>
        <h1 className="m-0 text-2xl font-extrabold text-ink">{title}</h1>
        <p className="m-0">{s.job.title}</p>
        <p className="m-0 text-sm">{meaning}</p>
        {p.close_out.emergency ? <p className="m-0 text-sm"><strong>Retrospective:</strong> follows emergency work {p.close_out.emergency.reference}.</p> : null}
      </div>

      {p.status === "suspended" && !p.held && !p.reissue_pending ? (
        <p className="notice m-0" role="status">Every stop is lifted. Work restarts when the supervisor re-briefs the team and re-accepts the permit{p.parent && p.parent.status !== "active" ? ", after its Work Approval" : ""}.</p>
      ) : null}
      {holding.length ? (
        <div className="notice notice-blocked" role="status">
          <p className="notice-title">Holding this permit</p>
          <ul>{holding.map((x) => <li key={x.id}>{SUSPENSION_KIND[x.kind] ?? x.kind}: {x.reason}<br /><span className="muted">Who lifts it: {x.who_lifts}</span></li>)}</ul>
        </div>
      ) : null}

      {isLive && (onTeam || appointee || session.organisationAdmin.length > 0) ? (
        <details className="panel" open={p.status === "active"}>
          <summary><strong>Stop work</strong></summary>
          <ActionForm action={stopWork} what="Stopping work" submitLabel="Stop work now">
            {hidden("key", k())}{hidden("permit_id", p.id)}
            <label>Why
              <select name="category" required defaultValue="">
                <option value="">— Choose —</option>
                {Object.entries(STOP_CATEGORY).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
            </label>
            <label>What has happened<input name="reason" required /></label>
            <p className="m-0 text-sm muted">This stops every permit on the job at once. Only the authority that owns the stop can lift it.</p>
          </ActionForm>
        </details>
      ) : null}

      <dl className="stack m-0">
        <div><dt className="muted">Scope and limits</dt><dd className="m-0">{s.job.scope}{s.job.method ? ` — ${s.job.method}` : ""}</dd></div>
        <div><dt className="muted">Where</dt><dd className="m-0">{liveAreas.length ? liveAreas.map((a) => a.name).join(", ") : s.job.areas.map((a) => a.name).join(", ")}
          {p.close_out.area_returns.some((r) => r.outcome === "accepted") ? <span className="muted"> (some areas handed back)</span> : null}</dd></div>
        <div><dt className="muted">When</dt><dd className="m-0">until {venueTime(p.window_end, tz)} · <strong>{timeLeft(p.window_end)}</strong>
          {p.extensions.some((e) => e.acknowledged_at) ? <span className="muted"> (extended)</span> : null}</dd></div>
        <div><dt className="muted">Team</dt><dd className="m-0">{counted.map((m) => `${m.name}${m.role === "supervisor" ? " (supervisor)" : ""}`).join(", ") || "Nobody"}</dd></div>
        <div><dt className="muted">Conditions</dt><dd className="m-0">{conditions.length === 0 && liftConditions.length === 0 ? "None" : (
          <ul>{conditions.map((c) => <li key={c.id}>{c.text}</li>)}{p.open_lifts.flatMap((l) => l.conditions.map((c, i) => <li key={`${l.id}${i}`}>{c} <span className="muted">(set when a stop was lifted)</span></li>))}</ul>
        )}</dd></div>
        <div><dt className="muted">Linked permits</dt><dd className="m-0">{p.parent ? <Link href={`/permits/${p.parent.id}`}>{p.parent.class_name}: {PERMIT_STATE[p.parent.status]}</Link>
          : p.children.length === 0 ? "None" : p.children.map((c, i) => <span key={c.id}>{i ? "; " : ""}<Link href={`/permits/${c.id}`}>{c.class_name}</Link>: {PERMIT_STATE[c.status]}</span>)}</dd></div>
        <div><dt className="muted">Physical controls</dt><dd className="m-0">{p.controls.required === null ? "Not chosen for this class version"
          : p.controls.required.length === 0 ? "None needed" : p.controls.required.map((c) => CONTROL_KIND[c.kind]).join(", ")}
          {p.controls.blockers.length ? <ul className="m-0">{p.controls.blockers.map((b, i) => <li key={i}>{b.problem} <span className="muted">— {b.who}</span></li>)}</ul>
            : p.controls.required?.length ? <span className="muted"> — in place</span> : null}</dd></div>
        {p.revalidation.required ? (
          <div><dt className="muted">Revalidation</dt><dd className="m-0">Every {p.revalidation.every_hours} hours. {p.revalidation.overdue
            ? <strong>Overdue since {venueTime(p.revalidation.due_at, tz)}: work must not continue until the supervisor confirms.</strong>
            : `Next due ${venueTime(p.revalidation.due_at, tz)}.`}</dd></div>
        ) : null}
        <div><dt className="muted">Emergency contacts</dt><dd className="m-0">{p.emergency_contacts?.length
          ? <ul className="m-0">{p.emergency_contacts.map((c) => <li key={c.label}>{c.label}: <a href={`tel:${c.phone.replace(/[^+0-9]/g, "")}`}>{c.phone}</a></li>)}</ul>
          : "The venue has not published its emergency contacts. Ask the venue's control room for them before work starts."}</dd></div>
        <div><dt className="muted">Issued</dt><dd className="m-0">by {p.snapshot!.issuer} at {venueTime(p.snapshot!.issued_at, tz)}</dd></div>
      </dl>

      {/* ---- Acceptance and re-acceptance -------------------------------------------------- */}
      {p.status === "issued_awaiting_acceptance" && isSupervisor ? (
        <ActionForm action={acceptPermit} what="Accepting this permit" submitLabel="Accept the permit">
          {hidden("key", k())}{ids}
          <ConditionAndBriefing conditions={conditions.filter((c) => c.acknowledge)} lifts={[]} team={counted} declaration={s.class_version.acceptance_declaration} />
        </ActionForm>
      ) : null}
      {p.status === "suspended" && isSupervisor && !p.held && !p.reissue_pending ? (
        <div className="panel stack">
          <h2 className="m-0">Restart the work</h2>
          <p className="m-0 text-sm">Every stop is lifted. Re-brief the team on the conditions, including any set when the stop was lifted, then re-accept.</p>
          <ActionForm action={reacceptPermit} what="Re-accepting this permit" submitLabel="Re-accept and restart">
            {hidden("key", k())}{ids}
            <ConditionAndBriefing conditions={conditions.filter((c) => c.acknowledge)} lifts={liftConditions} team={counted} declaration={s.class_version.acceptance_declaration} />
          </ActionForm>
        </div>
      ) : null}
      {p.reissue_pending ? (
        <p className="notice m-0">The job changed, so this permit must be prepared and submitted again, then reissued. {party ? "Prepare it below, then submit it again." : "The applicant does this."}</p>
      ) : null}
      {party && p.reissue_pending ? (
        <ActionForm action={submitPermit} what="Submitting this permit again" submitLabel="Submit again for review">
          {hidden("key", k())}{ids}
          <p className="m-0 text-sm">Save the changed request first (open it from the job). Submitting starts the full approval route again.</p>
          <ul>{(p.class_version?.content.submission_declaration ?? []).map((d, i) => <li key={i}>{d}</li>)}</ul>
          <label className="inline"><input type="checkbox" name="confirm" /> I make this declaration for {p.performing_organisation}</label>
        </ActionForm>
      ) : null}

      {/* ---- Lifting (authorities) -------------------------------------------------------- */}
      {appointee && holding.some((x) => x.kind === "stop") ? (
        <div className="panel stack">
          <h2 className="m-0">Lift a stop</h2>
          {holding.filter((x) => x.kind === "stop").map((x) => (
            <ActionForm key={x.id} action={liftSuspension} what="Lifting this stop" submitLabel="Lift this stop">
              {hidden("key", k())}{hidden("suspension_id", x.id)}
              <p className="m-0">{STOP_CATEGORY[x.category ?? ""] ?? "Stop"}: {x.reason} — {x.by}, {venueTime(x.at, tz)}</p>
              <label>Why it can be lifted<input name="reason" required /></label>
              <label>Conditions for restarting, one per line (optional)<textarea name="conditions" rows={2} /></label>
            </ActionForm>
          ))}
        </div>
      ) : null}

      {/* ---- Revalidation and extension ------------------------------------------------------ */}
      {p.status === "active" && isSupervisor && p.revalidation.required ? (
        <details className="panel"><summary>Revalidate</summary>
          <ActionForm action={revalidatePermit} what="Revalidating" submitLabel="Confirm nothing has changed">
            {hidden("key", k())}{ids}
            <p className="m-0 text-sm">The work, its conditions and its controls are as accepted, and the team is as recorded. If not, stop the work instead.</p>
            <label>Conditions checked (optional, e.g. wind speed)<input name="note" /></label>
          </ActionForm>
        </details>
      ) : null}
      {pendingExtension ? (
        <div className="panel stack">
          <p className="m-0"><strong>Extension to {venueTime(pendingExtension.new_end, tz)}</strong> by {pendingExtension.by}: {pendingExtension.reason}. It counts only once the supervisor acknowledges it, before {venueTime(pendingExtension.previous_end, tz)}.</p>
          {isSupervisor ? (
            <ActionForm action={acknowledgeExtension} what="Acknowledging the extension" submitLabel="Acknowledge the extension">
              {hidden("key", k())}{hidden("extension_id", pendingExtension.id)}
            </ActionForm>
          ) : null}
        </div>
      ) : null}
      {appointee && ["active", "suspended"].includes(p.status) && !pendingExtension ? (
        <details className="panel"><summary>Extend</summary>
          {p.extension_rule ? <p className="m-0 text-sm">This class allows {p.extension_rule.max_count} extension(s), {p.extension_rule.max_total_hours} hours in total.</p>
            : <p className="m-0 text-sm">This class has not set extension limits, so it cannot be extended.</p>}
          <ActionForm action={extendPermit} what="Extending this permit" submitLabel="Extend">
            {hidden("key", k())}{ids}{hidden("tz", tz)}
            <label>New end<input name="new_end" type="datetime-local" required defaultValue={toVenueLocal(p.window_end, tz)} /></label>
            <label>Why<input name="reason" required /></label>
          </ActionForm>
        </details>
      ) : null}

      {/* ---- The team ------------------------------------------------------------------------ */}
      <details className="panel" open={live.some((m) => !m.counts)}>
        <summary><strong>Team</strong> ({counted.length})</summary>
        <ul className="stack m-0">
          {p.team_live.map((m) => (
            <li key={m.member_id}>
              {m.name}{m.role === "supervisor" ? " (supervisor)" : ""}
              {m.removed_at ? <span className="muted"> — removed {venueTime(m.removed_at, tz)}{m.removal_reason ? `: ${m.removal_reason}` : ""}</span>
                : !m.counts ? <span className="muted"> — added, {m.approval_required && !m.approved_at ? "waiting for an issuer's approval" : "not yet briefed"}</span> : null}
              {!m.removed_at && m.approval_required && !m.approved_at && appointee ? (
                <ActionForm action={approveWorker} what="Approving this addition" submitLabel="Approve">{hidden("key", k())}{hidden("member_id", m.member_id)}</ActionForm>
              ) : null}
              {!m.removed_at && m.added_live && !m.briefed_at && (!m.approval_required || m.approved_at) && isSupervisor ? (
                <ActionForm action={briefWorker} what="Recording the briefing" submitLabel="I have briefed them">{hidden("key", k())}{hidden("member_id", m.member_id)}</ActionForm>
              ) : null}
              {!m.removed_at && m.role === "operative" && isLive && (isSupervisor || appointee) ? (
                <details><summary>Remove from the team</summary>
                  <ActionForm action={excludeWorker} what="Removing this person" submitLabel="Remove" secondary>
                    {hidden("key", k())}{hidden("member_id", m.member_id)}
                    <label>Why<input name="reason" required /></label>
                  </ActionForm>
                </details>
              ) : null}
            </li>
          ))}
        </ul>
        {isSupervisor && isLive ? (
          <ActionForm action={addWorker} what="Adding someone" submitLabel="Add to the team">
            {hidden("key", k())}{ids}
            <label>Person
              <select name="person_id" required defaultValue="">
                <option value="">— Choose —</option>
                {people.filter((x) => !live.some((m) => m.person_id === x.id)).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
              </select>
            </label>
            <p className="m-0 text-sm muted">{p.worker_add_rule === "issuer_approval" ? "An issuer approves each addition, then you brief them." : p.worker_add_rule === "supervisor" ? "They join once you have briefed them." : "This class has not said who approves additions, so nobody can be added."}</p>
          </ActionForm>
        ) : null}
        {appointee && isLive ? (
          <details><summary>Change the supervisor</summary>
            <ActionForm action={changeSupervisor} what="Changing the supervisor" submitLabel="Change supervisor">
              {hidden("key", k())}{ids}
              <label>New supervisor
                <select name="person_id" required defaultValue="">
                  <option value="">— Choose —</option>
                  {people.filter((x) => !live.some((m) => m.person_id === x.id && m.role === "supervisor")).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
                </select>
              </label>
              <label className="inline"><input type="checkbox" name="keep" defaultChecked /> Keep the current supervisor on the team as an operative</label>
              <label>Why<input name="reason" required /></label>
              <p className="m-0 text-sm muted">The permit is suspended until the new supervisor re-accepts it.</p>
            </ActionForm>
          </details>
        ) : null}
      </details>

      {/* ---- Physical controls -------------------------------------------------------------------- */}
      <Controls p={p} k={k} hidden={hidden} isSupervisor={isSupervisor} onTeam={onTeam} canRequest={isSupervisor || party} me={me}
        counted={counted} people={people} systems={systems} liveAreas={liveAreas} />

      {/* ---- Hand-back ------------------------------------------------------------------------------ */}
      <HandBack p={p} k={k} hidden={hidden} ids={ids} isSupervisor={isSupervisor} appointee={appointee} liveAreas={liveAreas} />

      {p.suspensions.length ? (
        <details><summary>Stops and restarts ({p.suspensions.length})</summary>
          <ul>{p.suspensions.map((x) => (
            <li key={x.id}>{venueTime(x.at, tz)} — {SUSPENSION_KIND[x.kind] ?? x.kind}: {x.reason}{x.by ? ` (${x.by})` : ""}
              {x.lift ? <span className="muted"> · lifted {venueTime(x.lift.at, tz)} by {x.lift.by}: {x.lift.reason}</span> : x.holding ? <strong> · still holding</strong> : null}</li>
          ))}</ul>
          {p.reacceptances.length ? <p className="muted">Re-accepted: {p.reacceptances.map((r) => `${venueTime(r.at, tz)} by ${r.by}`).join("; ")}</p> : null}
        </details>
      ) : null}
      {p.acceptance ? <p className="muted m-0">Accepted by {p.acceptance.by} at {venueTime(p.acceptance.accepted_at, tz)} after briefing {p.acceptance.briefed.join(", ")}.</p> : null}
      <p className="text-sm muted m-0">Every action here uses the live record: none can be done offline, and a page loaded before a change is refused.</p>
    </section>
  );
}

function ConditionAndBriefing({ conditions, lifts, team, declaration }: {
  conditions: Array<{ id: string; text: string }>; lifts: Array<{ id: string; conditions: string[] }>;
  team: Array<{ person_id: string; name: string }>; declaration: string[];
}) {
  return (
    <>
      {conditions.length + lifts.length > 0 ? (
        <fieldset className="stack"><legend>Acknowledge each condition</legend>
          {conditions.map((c) => <label key={c.id} className="flex min-h-11 items-center gap-3"><input type="checkbox" name="acknowledged" value={c.id} required /> {c.text}</label>)}
          {lifts.map((l) => <label key={l.id} className="flex min-h-11 items-center gap-3"><input type="checkbox" name="lifts" value={l.id} required /> {l.conditions.join("; ")}</label>)}
        </fieldset>
      ) : null}
      <fieldset className="stack"><legend>Who did you brief at the workface? (Q103)</legend>
        {team.map((t) => <label key={t.person_id} className="flex min-h-11 items-center gap-3"><input type="checkbox" name="briefed" value={t.person_id} /> {t.name}</label>)}
      </fieldset>
      <fieldset className="stack"><legend>Declaration</legend>
        {declaration.map((d, i) => <label key={i} className="flex min-h-11 items-center gap-3"><input type="checkbox" required /> {d}</label>)}
      </fieldset>
    </>
  );
}

type Hidden = (name: string, value: string | number) => React.ReactElement;

function Controls({ p, k, hidden, isSupervisor, onTeam, canRequest, me, counted, people, systems, liveAreas }: {
  p: PermitDetail; k: () => string; hidden: Hidden; isSupervisor: boolean; onTeam: boolean; canRequest: boolean; me: (id: string) => boolean;
  counted: Array<{ person_id: string; name: string }>; people: Option[]; systems: Option[]; liveAreas: Option[];
}) {
  const c = p.controls;
  const tz = p.venue_timezone;
  const needs = (kind: string) => c.required?.some((r) => r.kind === kind) ?? false;
  const open = !["closed", "cancelled"].includes(p.status);
  if (!c.required?.length && !c.isolations.length && !c.impairments.length && !c.fire_watches.length && !c.exclusion_zones.length && !c.custody.length) return null;
  return (
    <details className="panel" open={c.blockers.length > 0}>
      <summary><strong>Physical controls</strong></summary>
      {c.isolations.map((i) => (
        <div key={i.id} className="stack">
          <p className="m-0"><strong>Isolation of {i.system}</strong>: {i.points} — {CONTROL_STATE[i.status] ?? i.status}{i.failure_open ? <strong> · failed, not restored</strong> : null}</p>
          {i.locks.length ? <ul className="m-0">{i.locks.map((l) => (
            <li key={l.id}>{l.name}&apos;s lock {l.lock_ref} on since {venueTime(l.on_at, tz)}
              {isSupervisor || me(l.person_id) ? (
                <ActionForm action={lockOff} what="Taking the lock off" submitLabel="Lock off" secondary>{hidden("key", k())}{hidden("lock_id", l.id)}</ActionForm>
              ) : null}</li>
          ))}</ul> : null}
          {isSupervisor && i.status === "proved" && !i.failure_open ? (
            <ActionForm action={lockOn} what="Recording a personal lock" submitLabel="Record lock on">
              {hidden("key", k())}{hidden("isolation_id", i.id)}
              <label>Whose lock
                <select name="person_id" required defaultValue="">
                  <option value="">— Choose —</option>
                  {counted.filter((m) => !i.locks.some((l) => l.person_id === m.person_id)).map((m) => <option key={m.person_id} value={m.person_id}>{m.name}</option>)}
                </select>
              </label>
              <label>Lock number or tag<input name="lock_ref" required /></label>
            </ActionForm>
          ) : null}
          {onTeam && ["applied", "proved"].includes(i.status) && !i.failure_open ? (
            <details><summary>Report this isolation has failed</summary>
              <ActionForm action={reportFailure} what="Reporting a failure" submitLabel="Report failure and stop the job">
                {hidden("key", k())}{hidden("kind", "isolation")}{hidden("control_id", i.id)}
                <label>What has failed<input name="reason" required /></label>
              </ActionForm>
            </details>
          ) : null}
        </div>
      ))}
      {c.impairments.map((i) => (
        <div key={i.id} className="stack">
          <p className="m-0"><strong>Impairment of {i.system}</strong>: {i.zones} — {CONTROL_STATE[i.status] ?? i.status}
            {i.status === "impaired" ? <> · maximum until {venueTime(i.due_at, tz)}{i.overdue ? <strong> · overdue: needs a fresh authorisation</strong> : null}</> : null}
            {i.failure_open ? <strong> · a measure has failed</strong> : null}</p>
          {onTeam && i.status === "impaired" && !i.failure_open ? (
            <details><summary>Report a compensatory measure has failed</summary>
              <ActionForm action={reportFailure} what="Reporting a failure" submitLabel="Report failure and stop the job">
                {hidden("key", k())}{hidden("kind", "impairment")}{hidden("control_id", i.id)}
                <label>What has failed<input name="reason" required /></label>
              </ActionForm>
            </details>
          ) : null}
        </div>
      ))}
      {canRequest && open && (needs("isolation") || needs("impairment")) ? (
        <details><summary>Ask for an isolation or impairment</summary>
          <ActionForm action={requestControl} what="Asking for a control" submitLabel="Ask the system's authority">
            {hidden("key", k())}{hidden("permit_id", p.id)}{hidden("tz", tz)}
            <label>Control
              <select name="kind" required defaultValue={needs("isolation") ? "isolation" : "impairment"}>
                {needs("isolation") ? <option value="isolation">Isolation</option> : null}
                {needs("impairment") ? <option value="impairment">Impairment</option> : null}
              </select>
            </label>
            <label>System
              <select name="system_id" required defaultValue="">
                <option value="">— Choose —</option>
                {systems.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
              </select>
            </label>
            <label>Isolation points, or zones and devices to impair<input name="detail" required /></label>
            <label>Why<input name="reason" required /></label>
            <div className="grid gap-3 sm:grid-cols-2">
              <label>From<input name="from" type="datetime-local" required defaultValue={toVenueLocal(p.snapshot?.content.version.window_from, tz)} /></label>
              <label>To<input name="to" type="datetime-local" required defaultValue={toVenueLocal(p.window_end, tz)} /></label>
            </div>
          </ActionForm>
        </details>
      ) : null}
      {c.fire_watches.map((w) => (
        <div key={w.id} className="stack">
          <p className="m-0"><strong>Fire watch {w.phase === "during" ? "during" : "after"} the work</strong>: {w.watcher} — {CONTROL_STATE[w.status] ?? w.status}
            {w.status === "started" && w.phase === "post" ? ` · may end from ${venueTime(w.earliest_end, tz)}` : ""}</p>
          {isSupervisor && w.status === "arranged" ? (
            <ActionForm action={startFireWatch} what="Starting the watch" submitLabel="Watch started">{hidden("key", k())}{hidden("fire_watch_id", w.id)}{hidden("row_version", w.row_version)}</ActionForm>
          ) : null}
          {isSupervisor && w.status === "started" ? (
            <>
              <ActionForm action={checkFireWatch} what="Recording a check" submitLabel="Record check" secondary>
                {hidden("key", k())}{hidden("fire_watch_id", w.id)}
                <label>Findings<input name="findings" required /></label>
              </ActionForm>
              <ActionForm action={endFireWatch} what="Ending the watch" submitLabel="Final check: end the watch">
                {hidden("key", k())}{hidden("fire_watch_id", w.id)}{hidden("row_version", w.row_version)}
                <label>Final check findings (from {w.watcher})<input name="findings" required /></label>
              </ActionForm>
            </>
          ) : null}
        </div>
      ))}
      {isSupervisor && open && needs("fire_watch") ? (
        <details><summary>Arrange a fire watch</summary>
          <ActionForm action={arrangeFireWatch} what="Arranging a fire watch" submitLabel="Arrange">
            {hidden("key", k())}{hidden("permit_id", p.id)}
            <label>When
              <select name="phase" required defaultValue="post">
                {c.required?.some((r) => r.kind === "fire_watch" && r.during_work) ? <option value="during">During the work</option> : null}
                <option value="post">After the work</option>
              </select>
            </label>
            <label>Watcher
              <select name="watcher" required defaultValue="">
                <option value="">— Choose —</option>
                {people.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
              </select>
            </label>
          </ActionForm>
        </details>
      ) : null}
      {c.exclusion_zones.map((z) => (
        <div key={z.id} className="stack">
          <p className="m-0"><strong>Exclusion zone</strong>: {z.description}{z.area ? ` (${z.area})` : ""} — {CONTROL_STATE[z.status] ?? z.status}</p>
          {isSupervisor && z.status === "set_up" && !["issued_awaiting_acceptance", "active"].includes(p.status) ? (
            <ActionForm action={removeZone} what="Removing the zone" submitLabel="Zone removed" secondary>
              {hidden("key", k())}{hidden("zone_id", z.id)}{hidden("row_version", z.row_version)}
              <label>Area checked clear<input name="note" required /></label>
            </ActionForm>
          ) : null}
        </div>
      ))}
      {isSupervisor && open && needs("exclusion_zone") ? (
        <details><summary>Record an exclusion zone</summary>
          <ActionForm action={setUpZone} what="Recording the zone" submitLabel="Zone in place">
            {hidden("key", k())}{hidden("permit_id", p.id)}
            <label>Area (optional)
              <select name="area_id" defaultValue=""><option value="">—</option>{liveAreas.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select>
            </label>
            <label>Description<input name="description" required /></label>
          </ActionForm>
        </details>
      ) : null}
      {c.custody.length ? (
        <>
          <p className="m-0"><strong>Keys, passes and certificates</strong></p>
          <ul className="m-0">{c.custody.map((m) => <li key={m.id}>{m.item} ({m.reference}) — {m.holder}{m.returned_at ? `, returned ${venueTime(m.returned_at, tz)}` : ", still out"}</li>)}</ul>
        </>
      ) : null}
    </details>
  );
}

function HandBack({ p, k, hidden, ids, isSupervisor, appointee, liveAreas }: {
  p: PermitDetail; k: () => string; hidden: Hidden; ids: React.ReactElement; isSupervisor: boolean; appointee: boolean; liveAreas: Option[];
}) {
  const h = p.close_out;
  const tz = p.venue_timezone;
  const pendingReturn = h.area_returns.find((r) => !r.outcome);
  const canHandBack = (isSupervisor && ["active", "suspended", "expired"].includes(p.status)) || (appointee && ["suspended", "expired"].includes(p.status));
  return (
    <details className="panel" open={p.status === "hand_back_pending" || p.status === "expired"}>
      <summary><strong>Hand-back</strong>{h.duties.length ? ` (${h.duties.length} outstanding)` : ""}</summary>
      {h.duties.length ? (
        <>
          <p className="m-0">Still outstanding, so the permit cannot close:</p>
          <ul>{h.duties.map((d, i) => <li key={i}>{d.problem} <span className="muted">— {d.who}</span></li>)}</ul>
        </>
      ) : <p className="m-0">Nothing outstanding.</p>}
      {h.transferred.length ? <p className="m-0 muted">Continuing after the work: {h.transferred.map((t) => `${t.kind} owned by ${t.owner ?? "a named authority"}`).join("; ")}.</p> : null}
      {h.abandoned ? <p className="m-0"><strong>Flagged abandoned</strong> by {h.abandoned.by}: {h.abandoned.reason}. It must still be closed out.</p> : null}
      {h.hand_backs.map((x) => (
        <p key={x.id} className="m-0 text-sm">{venueTime(x.at, tz)} — {x.route === "issuer_close_out" ? "close-out started" : "handed back"} by {x.by}: {x.area_state}
          {x.work_complete ? "" : ` (unfinished: ${x.remaining_work})`}{x.decision ? ` · ${x.decision.outcome} by ${x.decision.by} (${x.decision.inspection.replace("_", " ")}): ${x.decision.reason}` : " · waiting"}</p>
      ))}
      {canHandBack ? (
        <ActionForm action={handBack} what="Handing back" submitLabel={isSupervisor ? "Hand back" : "Start the close-out"}>
          {hidden("key", k())}{ids}
          <label>Is the work complete?
            <select name="complete" required defaultValue=""><option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option></select>
          </label>
          <label>What remains, if not complete<input name="remaining" /></label>
          <label>The state the area is left in<input name="area_state" required /></label>
          <label className="inline"><input type="checkbox" name="workers_out" required /> Everyone has left the work area</label>
          {h.hand_back_declaration?.length ? <fieldset className="stack"><legend>Declaration (Q113)</legend>
            {h.hand_back_declaration.map((d, i) => <label key={i} className="inline"><input type="checkbox" required /> {d}</label>)}</fieldset>
            : <p className="m-0 text-sm">This class has no hand-back declaration, so it cannot be handed back yet.</p>}
        </ActionForm>
      ) : null}
      {p.status === "hand_back_pending" && appointee ? (
        <ActionForm action={decideHandBack} what="Deciding the hand-back" submitLabel="Record decision">
          {hidden("key", k())}{ids}
          <label>Decision
            <select name="outcome" required defaultValue=""><option value="">— Choose —</option><option value="accept">Accept: close the permit</option><option value="reject">Reject: back to where it was</option></select>
          </label>
          <label>Inspection (Q114)
            <select name="inspection" required defaultValue="in_person"><option value="in_person">In person</option>
              {h.hand_back_inspection === "remote_allowed" ? <option value="remote">Remote</option> : null}</select>
          </label>
          <label>Reason<input name="reason" required /></label>
          <p className="m-0 text-sm muted">You cannot accept a hand-back on a job you are connected with, or one you started.</p>
        </ActionForm>
      ) : null}
      {pendingReturn ? (
        <div className="stack">
          <p className="m-0"><strong>Areas handed back</strong>: {pendingReturn.areas.join(", ")} by {pendingReturn.by} — {pendingReturn.area_state}</p>
          {appointee ? (
            <ActionForm action={decideAreaReturn} what="Deciding the return of areas" submitLabel="Record decision">
              {hidden("key", k())}{hidden("area_return_id", pendingReturn.id)}
              <label>Decision<select name="outcome" required defaultValue=""><option value="">— Choose —</option><option value="accept">Accept the areas back</option><option value="reject">Reject</option></select></label>
              <label>Reason<input name="reason" required /></label>
            </ActionForm>
          ) : null}
        </div>
      ) : isSupervisor && ["active", "suspended"].includes(p.status) && liveAreas.length > 1 ? (
        <details><summary>Hand back some areas (Q115)</summary>
          <ActionForm action={returnAreas} what="Handing back areas" submitLabel="Hand back these areas">
            {hidden("key", k())}{ids}
            <fieldset className="stack"><legend>Areas</legend>
              {liveAreas.map((a) => <label key={a.id} className="inline"><input type="checkbox" name="area_ids" value={a.id} /> {a.name}</label>)}
            </fieldset>
            <label>The state they are left in<input name="area_state" required /></label>
          </ActionForm>
        </details>
      ) : null}
      {appointee && p.status === "issued_awaiting_acceptance" ? (
        <details><summary>Cancel before acceptance</summary>
          <ActionForm action={cancelIssued} what="Cancelling this permit" submitLabel="Cancel the permit" secondary>
            {hidden("key", k())}{ids}
            <label>Why<input name="reason" required /></label>
          </ActionForm>
        </details>
      ) : null}
      {appointee && ["suspended", "expired"].includes(p.status) && !h.abandoned ? (
        <details><summary>Flag as abandoned</summary>
          <ActionForm action={flagAbandoned} what="Flagging as abandoned" submitLabel="Flag abandoned" secondary>
            {hidden("key", k())}{hidden("permit_id", p.id)}
            <label>Why<input name="reason" required /></label>
            <p className="m-0 text-sm muted">This closes nothing and removes nothing: the permit must still be closed out.</p>
          </ActionForm>
        </details>
      ) : null}
      {h.close_out ? <p className="m-0 muted">Closed {venueTime(h.close_out.at, tz)}. Close-out record {h.close_out.sha256.slice(0, 12)}…</p> : null}
    </details>
  );
}
