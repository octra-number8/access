import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { ConfigView } from "@/components/permits/config-view";
import type { ClassConfig } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { venueAreas } from "../../jobs/data";
import { QuestionForm } from "../screening/forms";
import {
  addClassQuestion, createRestriction, createWorkApprovalClass, endRestriction, proposeClass, publishCalendar, recordOccupation,
  removeClassQuestion, startClassDraft,
} from "./actions";
import { ConfigForm } from "./config-form";

export const metadata = { title: "Permit set-up" };

const STATE: Record<string, string> = {
  draft: "draft", proposed: "proposed, waiting for the technical authority", approved: "approved and in use", rejected: "rejected",
  superseded: "replaced by a later version",
};
const WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

export default async function PermitSetup() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/permits");
  if (session.tenantAdminCustomerIds.length === 0) return <p>Permit set-up is available to tenant administrators only.</p>;
  const db = await supabaseServer();
  const { data: venues } = await db.from("venue").select("id, name, timezone").in("customer_id", session.tenantAdminCustomerIds).order("name");
  const venue = (venues ?? [])[0];
  if (!venue) return <p>No venue yet.</p>;
  const [classes, versions, calendars, windows, occupations, orgs, phases, systemTypes, courses, competencies, areas] = await Promise.all([
    db.from("permit_class").select("id, code, name, handling, retired_at").eq("venue_id", venue.id).neq("handling", "external_reference").order("name"),
    db.from("permit_class_version").select("id, permit_class_id, version_no, status, content, source_ref, row_version, decision_reason")
      .eq("venue_id", venue.id).order("version_no", { ascending: false }),
    db.from("venue_calendar_version").select("working_weekdays, closures, cutoff_time, effective_from, change_reason").eq("venue_id", venue.id)
      .order("effective_from", { ascending: false }).limit(1),
    db.from("restriction_window").select("id, area_ids, starts_at, ends_at, effect, reason").eq("venue_id", venue.id).is("ended_at", null).order("starts_at"),
    db.from("area_occupation").select("id, area_id, organisation_id, valid_during, evidence_ref").eq("venue_id", venue.id).is("ended_at", null),
    db.from("organisation").select("id, legal_name").order("legal_name"),
    db.from("event_phase").select("id, phase, event_id").eq("venue_id", venue.id),
    db.from("system_type").select("id, label").eq("venue_id", venue.id),
    db.from("induction_course").select("id, title").eq("venue_id", venue.id),
    db.from("competency_type").select("id, label").eq("venue_id", venue.id).is("retired_at", null),
    venueAreas(db, venue.id),
  ]);
  const names = new Map<string, string>([
    ...(systemTypes.data ?? []).map((t) => [t.id, t.label] as [string, string]),
    ...(courses.data ?? []).map((c) => [c.id, c.title] as [string, string]),
    ...(competencies.data ?? []).map((c) => [c.id, c.label] as [string, string]),
  ]);
  const areaName = new Map(areas.map((a) => [a.id, a.name]));
  const orgName = new Map((orgs.data ?? []).map((o) => [o.id, o.legal_name]));
  const cal = (calendars.data ?? [])[0];
  const hasWa = (classes.data ?? []).some((c) => c.handling === "work_approval");
  const k = () => randomUUID();

  return (
    <>
      <p><Link href="/venue">Venue administration</Link> · <Link href="/venue/screening">Activity screening</Link></p>
      <h1>Permit set-up — {venue.name}</h1>
      <div className="notice">
        <p className="notice-title">Content for the technical authority</p>
        <p>Each class&apos;s questions, approval route, notice and declarations are proposed here and approved by the venue&apos;s technical authority (Q55–Q104). None has a default, and a class cannot be requested until it has an approved configuration.</p>
      </div>

      <h2>Working calendar</h2>
      {cal ? (
        <p>In force from {new Date(cal.effective_from).toLocaleDateString("en-GB")}: {(cal.working_weekdays as number[]).map((d) => WEEKDAYS[d - 1]).join(", ")};
          cut-off {String(cal.cutoff_time).slice(0, 5)} ({venue.timezone}); {(cal.closures as string[]).length === 0 ? "no closure dates" : `closed ${(cal.closures as string[]).join(", ")}`}.
          <span className="muted"> {cal.change_reason}</span></p>
      ) : <p className="notice notice-blocked">No calendar is published, so notice cannot be measured and no permit can be submitted (P5-8).</p>}
      <details><summary>Publish a new calendar version</summary>
        <ActionForm action={publishCalendar} what="Publishing the calendar" submitLabel="Publish calendar">
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
          <input type="hidden" name="tz" value={venue.timezone} />
          <fieldset className="stack"><legend>Working days</legend>
            {WEEKDAYS.map((d, i) => <label className="inline" key={d}><input type="checkbox" name="weekdays" value={i + 1} /> {d}</label>)}
          </fieldset>
          <label>Cut-off time ({venue.timezone})<input name="cutoff" type="time" required /></label>
          <label>Closure dates (YYYY-MM-DD, separated by commas; may be empty)<input name="closures" /></label>
          <label>Takes effect from<input name="effective_from" type="datetime-local" required /></label>
          <label>Reason<input name="reason" required /></label>
        </ActionForm>
      </details>

      <h2>Permit classes</h2>
      {!hasWa ? (
        <ActionForm action={createWorkApprovalClass} what="Adding the Work Approval class" submitLabel="Add the Work Approval class">
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
          <input type="hidden" name="tz" value={venue.timezone} />
          <p className="muted">Every job that needs a permit gets one Work Approval as the parent of its permits (P5-2).</p>
          <label>Code<input name="code" required defaultValue="WA" /></label>
          <label>Name<input name="name" required defaultValue="Work Approval" /></label>
        </ActionForm>
      ) : null}
      {(classes.data ?? []).map((c) => {
        const vs = (versions.data ?? []).filter((v) => v.permit_class_id === c.id);
        const approved = vs.find((v) => v.status === "approved");
        const current = vs.find((v) => v.status === "draft" || v.status === "proposed");
        return (
          <details className="panel" key={c.id}>
            <summary><strong>{c.name}</strong> <span className="muted">({c.code}{c.handling === "work_approval" ? ", Work Approval" : ""})</span> —{" "}
              {approved ? `version ${approved.version_no} in use` : "no approved configuration: cannot be requested"}{current ? `; version ${current.version_no} ${STATE[current.status]}` : ""}</summary>
            {approved ? (
              <>
                {approved.source_ref ? <p className="muted">Source: {approved.source_ref}</p> : null}
                <ConfigView config={approved.content as ClassConfig} names={names} />
              </>
            ) : null}
            {current?.status === "draft" ? (
              <div className="stack">
                <h3>Draft version {current.version_no}</h3>
                <ConfigForm versionId={current.id} config={current.content as ClassConfig} newKey={k()}
                  systemTypes={systemTypes.data ?? []} courses={courses.data ?? []} competencies={competencies.data ?? []} />
                <h4>Questions for the applicant</h4>
                <ul>{(current.content as ClassConfig).questions.map((q) => (
                  <li key={q.key}>{q.text}
                    <ActionForm action={removeClassQuestion} what="Removing this question" submitLabel="Remove" secondary>
                      <input type="hidden" name="key" value={k()} />
                      <input type="hidden" name="version_id" value={current.id} />
                      <input type="hidden" name="question_key" value={q.key} />
                    </ActionForm></li>
                ))}</ul>
                <details><summary>Add a question</summary>
                  <QuestionForm versionId={current.id} content={current.content as ClassConfig} newKey={k()} action={addClassQuestion} />
                </details>
                <ActionForm action={proposeClass} what="Proposing this configuration" submitLabel="Propose to the technical authority">
                  <input type="hidden" name="key" value={k()} />
                  <input type="hidden" name="version_id" value={current.id} />
                  <input type="hidden" name="row_version" value={current.row_version} />
                  <p className="muted">Once proposed it cannot be edited. The person who proposes it cannot approve it.</p>
                </ActionForm>
              </div>
            ) : current?.status === "proposed" ? (
              <>
                <h3>Proposed version {current.version_no}</h3>
                <ConfigView config={current.content as ClassConfig} names={names} />
              </>
            ) : (
              <ActionForm action={startClassDraft} what="Starting a draft" submitLabel={approved ? "Start a new version from this one" : "Start the first version"}>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="class_id" value={c.id} />
              </ActionForm>
            )}
          </details>
        );
      })}
      <p className="muted">Deferred specialist classes are handled by external reference and are not configured here (CLAUDE.md §7). Add classes on the <Link href="/venue/screening">screening set-up</Link> page.</p>

      <h2>Restrictions on work</h2>
      <p className="muted">Periods when work in some areas is barred, or needs a recorded decision, for example during an event&apos;s live phase.</p>
      {(windows.data ?? []).length === 0 ? <p>None in force.</p> : (windows.data ?? []).map((w) => (
        <div className="panel" key={w.id}>
          <p><strong>{w.effect === "no_work" ? "No work" : "Work needs a decision"}</strong> in {(w.area_ids as string[]).map((a) => areaName.get(a) ?? "an area").join(", ")},{" "}
            {new Date(w.starts_at).toLocaleString("en-GB", { timeZone: venue.timezone })} to {new Date(w.ends_at).toLocaleString("en-GB", { timeZone: venue.timezone })}: {w.reason}</p>
          <ActionForm action={endRestriction} what="Ending this restriction" submitLabel="End it now" secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="window_id" value={w.id} />
          </ActionForm>
        </div>
      ))}
      <details><summary>Add a restriction</summary>
        <ActionForm action={createRestriction} what="Recording this restriction" submitLabel="Record restriction">
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
          <input type="hidden" name="tz" value={venue.timezone} />
          <fieldset className="stack"><legend>Areas</legend>
            {areas.map((a) => <label className="inline" key={a.id} style={{ paddingLeft: `${a.depth * 1.25}rem` }}><input type="checkbox" name="area_ids" value={a.id} /> {a.name}</label>)}
          </fieldset>
          <label>Effect
            <select name="effect" required defaultValue=""><option value="">— Choose —</option><option value="no_work">No work at all</option><option value="decision_required">Work needs a recorded decision</option></select>
          </label>
          {(phases.data ?? []).length > 0 ? (
            <label>During an event phase (or give times below)
              <select name="event_phase_id" defaultValue=""><option value="">— Times below —</option>
                {(phases.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.phase}</option>)}</select>
            </label>
          ) : null}
          <label>From<input name="from" type="datetime-local" /></label>
          <label>To<input name="to" type="datetime-local" /></label>
          <label>Reason<input name="reason" required /></label>
        </ActionForm>
      </details>

      <h2>Who occupies which areas</h2>
      <p className="muted">Used to scope occupier approval steps (P5-6). Visible to the venue and its appointees only, never to contractors.</p>
      {(occupations.data ?? []).length === 0 ? <p>Nothing recorded.</p> : (
        <ul>{(occupations.data ?? []).map((o) => <li key={o.id}>{areaName.get(o.area_id) ?? "An area"}: {orgName.get(o.organisation_id) ?? "an organisation"}{o.evidence_ref ? ` (${o.evidence_ref})` : ""}</li>)}</ul>
      )}
      <details><summary>Record an occupation</summary>
        <ActionForm action={recordOccupation} what="Recording this occupation" submitLabel="Record">
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="tz" value={venue.timezone} />
          <label>Area<select name="area_id" required>{areas.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
          <label>Organisation<select name="organisation_id" required>{(orgs.data ?? []).map((o) => <option key={o.id} value={o.id}>{o.legal_name}</option>)}</select></label>
          <label>From<input name="from" type="date" required /></label>
          <label>To (optional)<input name="to" type="date" /></label>
          <label>Lease or agreement reference (optional)<input name="evidence_ref" /></label>
        </ActionForm>
      </details>
    </>
  );
}
