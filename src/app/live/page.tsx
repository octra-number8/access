import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { permitNeeds as needs } from "@/lib/dashboard";
import { PERMIT_STATE, type PermitSummary, STOP_CATEGORY, timeLeft, venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { liftAreaStop, stopArea } from "../controls/actions";

export const metadata = { title: "Live board" };

type Board = {
  permits: PermitSummary[];
  area_stops: Array<{ id: string; area: string; category: string; reason: string; by: string; at: string; venue_timezone: string }>;
  emergencies_overdue: Array<{ id: string; reference: string; deadline_at: string; organisation: string }>;
};

export default async function LiveBoard() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/live");
  const db = await supabaseServer();
  const [{ data }, { data: areas }] = await Promise.all([
    db.rpc("live_board"),
    db.from("area").select("id, name, venue_id").in("venue_id", session.appointmentVenueIds).order("name"),
  ]);
  const b = (data ?? { permits: [], area_stops: [], emergencies_overdue: [] }) as Board;
  const k = () => randomUUID();
  const hidden = (n: string, v: string) => <input type="hidden" name={n} value={v} />;

  return (
    <>
      <h1>Live board</h1>
      <p className="muted">Live permits at your venues and what each needs next. A status records a decision; it does not mean the work is safe.</p>

      {b.area_stops.length ? (
        <div className="notice notice-blocked">
          <p className="notice-title">Area stops in force</p>
          {b.area_stops.map((z) => (
            <div key={z.id} className="stack">
              <p className="m-0"><strong>{z.area}</strong>: {STOP_CATEGORY[z.category] ?? z.category} — {z.reason} ({z.by}, {venueTime(z.at, z.venue_timezone)})</p>
              <details><summary>Lift this area stop</summary>
                <ActionForm action={liftAreaStop} what="Lifting the area stop" submitLabel="Lift">
                  {hidden("key", k())}{hidden("area_stop_id", z.id)}
                  <label>Why it can be lifted<input name="reason" required /></label>
                  <label>Conditions for restarting, one per line (optional)<textarea name="conditions" rows={2} /></label>
                </ActionForm>
              </details>
            </div>
          ))}
        </div>
      ) : null}

      <h2>Permits</h2>
      {b.permits.length === 0 ? <p>No live permits.</p> : (
        <div className="table-wrap"><table>
          <thead><tr><th scope="col">Permit</th><th scope="col">Recorded state</th><th scope="col">Needs</th><th scope="col">Where</th><th scope="col">Ends</th></tr></thead>
          <tbody>{b.permits.map((p) => (
            <tr key={p.id}>
              <td><Link href={`/permits/${p.id}`}>{p.job_reference} — {p.class_name}</Link><div className="muted">{p.job_title} · {p.organisation}</div></td>
              <td>{PERMIT_STATE[p.status] ?? p.status}</td>
              <td>{needs(p).length ? <ul className="m-0">{needs(p).map((n, i) => <li key={i}>{n.what} <span className="muted">— {n.who}</span></li>)}</ul> : "Nothing"}</td>
              <td>{p.areas.join(", ")}</td>
              <td>{venueTime(p.window_end, p.venue_timezone)}<div className="muted">{timeLeft(p.window_end)}</div></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}

      {b.emergencies_overdue.length ? (
        <>
          <h2>Emergency work without its retrospective permit</h2>
          <ul>{b.emergencies_overdue.map((e) => <li key={e.id}><Link href="/emergency">{e.reference}</Link> — {e.organisation}: overdue <span className="muted">— the organisation, by linking and submitting its job</span></li>)}</ul>
        </>
      ) : null}

      {(areas ?? []).length ? (
        <details className="panel"><summary><strong>Stop all work in an area</strong></summary>
          <ActionForm action={stopArea} what="Stopping the area" submitLabel="Stop all work there">
            {hidden("key", k())}
            <label>Area (and everything inside it)<select name="area_id" required defaultValue=""><option value="">— Choose —</option>
              {(areas ?? []).map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
            <label>Why<select name="category" required defaultValue=""><option value="">— Choose —</option>
              {Object.entries(STOP_CATEGORY).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
            <label>What has happened<input name="reason" required /></label>
            <p className="m-0 text-sm muted">Every live permit on a job in that area is suspended. Only a venue authority for the area lifts it.</p>
          </ActionForm>
        </details>
      ) : null}
    </>
  );
}
