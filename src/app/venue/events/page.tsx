import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { addEventPhase, createEvent } from "../../events-evidence-actions";

export const metadata = { title: "Events" };

interface Phase { id: string; phase: string; starts: string; ends: string }
interface Event {
  id: string; code: string; name: string; starts: string; ends: string; ended: boolean; phases: Phase[]; courses: number; jobs: number;
}
interface Overview { ok: true; venue: { id: string; name: string; timezone: string }; can_manage: boolean; events: Event[] }

const PHASE: Record<string, string> = { build: "Build", live: "Live", breakdown: "Breakdown" };
const CODE_HINT = "Letters, numbers, - and _ only, up to 40 characters. It cannot be changed later.";

// S1c (D-026): the venue's events and their build, live and breakdown phases. Entry rules,
// inductions and jobs refer to them. An event's dates and its phases cannot be changed once
// recorded, because what refers to them relies on them.
export default async function Events({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/events");
  const db = await supabaseServer();
  const { data: scopes } = await db.rpc("report_scopes");
  const venues = ((scopes as { venues?: Array<{ id: string; name: string }> } | null)?.venues ?? []);
  const { venue: chosen } = await searchParams;
  const venueId = venues.some((v) => v.id === chosen) ? chosen! : venues[0]?.id;
  const { data } = venueId ? await db.rpc("events_overview", { p_venue_id: venueId }) : { data: null };
  if (!data?.ok) {
    return <><h1>Events</h1><p>This page is for a venue&apos;s administrators and the people it has appointed, and you are neither at any venue. If you need to see it, ask the venue&apos;s administrator.</p></>;
  }
  const o = data as Overview;
  const tz = o.venue.timezone;
  const k = () => randomUUID();
  const current = o.events.filter((e) => !e.ended);
  const past = o.events.filter((e) => e.ended);

  return (
    <>
      <p><Link href="/venue">Venue administration</Link> · <Link href="/venue/setup">Set-up</Link></p>
      <h1>Events — {o.venue.name}</h1>
      <div className="notice">
        <p className="m-0">Entry rules, inductions and jobs can refer to an event or to its build, live or breakdown phase. A phase falls within its event&apos;s dates, and two phases of the same kind cannot overlap. Dates cannot be changed once recorded, because what refers to them relies on them: if dates change, create the event again under a new code. Times are in the venue&apos;s time zone ({tz}).</p>
      </div>
      {venues.length > 1 ? (
        <form className="no-print"><label>Venue <select name="venue" defaultValue={o.venue.id}>{venues.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label> <button type="submit" className="secondary">Show</button></form>
      ) : null}
      {!o.can_manage ? <p className="muted">You can see these records. Only the venue&apos;s tenant administrators can change them.</p> : null}

      <h2>Current and coming events</h2>
      {current.length === 0 ? <p>None recorded.</p> : null}
      {current.map((e) => (
        <section key={e.id} className="panel" style={{ maxWidth: "none" }} aria-labelledby={`ev-${e.id}`}>
          <h3 id={`ev-${e.id}`} className="m-0">{e.name} <span className="muted text-sm">({e.code})</span></h3>
          <p className="m-0">{venueTime(e.starts, tz)} to {venueTime(e.ends, tz)}</p>
          <p className="muted text-sm">Referred to by {e.jobs === 1 ? "1 job" : `${e.jobs} jobs`} and {e.courses === 1 ? "1 induction course" : `${e.courses} induction courses`}.</p>
          {e.phases.length === 0 ? <p>No phases recorded.</p> : (
            <div className="table-wrap"><table className="stacked">
              <thead><tr><th scope="col">Phase</th><th scope="col">From</th><th scope="col">Until</th></tr></thead>
              <tbody>{e.phases.map((p) => (
                <tr key={p.id}><td data-label="Phase">{PHASE[p.phase] ?? p.phase}</td><td data-label="From">{venueTime(p.starts, tz)}</td><td data-label="Until">{venueTime(p.ends, tz)}</td></tr>
              ))}</tbody>
            </table></div>
          )}
          {o.can_manage ? (
            <details><summary className="text-sm" aria-label={`Add a phase to ${e.name}`}>Add a phase</summary>
              <ActionForm action={addEventPhase} what="Adding the phase" submitLabel="Add phase">
                <input type="hidden" name="key" value={k()} /><input type="hidden" name="event_id" value={e.id} />
                <input type="hidden" name="tz" value={tz} />
                <label>Phase<select name="phase" required defaultValue="">
                  <option value="" disabled>Choose</option>
                  {Object.entries(PHASE).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
                <label>From<input type="datetime-local" name="starts" required /></label>
                <label>Until<input type="datetime-local" name="ends" required /></label>
              </ActionForm>
            </details>
          ) : null}
        </section>
      ))}
      {past.length ? (
        <details><summary>Past events ({past.length})</summary>
          <ul>{past.map((e) => (
            <li key={e.id}>{e.name} <span className="muted text-sm">({e.code}) {venueTime(e.starts, tz)} to {venueTime(e.ends, tz)}
              {e.phases.length ? ` · ${e.phases.map((p) => PHASE[p.phase] ?? p.phase).join(", ")}` : ""}</span></li>
          ))}</ul>
        </details>
      ) : null}

      {o.can_manage ? (
        <details className="panel" style={{ maxWidth: "none" }}><summary><strong>Create an event</strong></summary>
          <ActionForm action={createEvent} what="Creating the event" submitLabel="Create event">
            <input type="hidden" name="key" value={k()} /><input type="hidden" name="venue_id" value={o.venue.id} />
            <input type="hidden" name="tz" value={tz} />
            <label>Name<input name="name" required maxLength={200} placeholder="For example: Autumn Trade Show 2026" /></label>
            <label>Code<input name="code" required pattern="[A-Za-z0-9_\-]{1,40}" maxLength={40} aria-describedby="code-ev" /></label>
            <p id="code-ev" className="muted text-sm m-0">{CODE_HINT}</p>
            <label>Starts (first day of build)<input type="datetime-local" name="starts" required /></label>
            <label>Ends (last day of breakdown)<input type="datetime-local" name="ends" required /></label>
          </ActionForm>
        </details>
      ) : null}
    </>
  );
}
