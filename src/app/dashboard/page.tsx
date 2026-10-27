import Link from "next/link";
import { redirect } from "next/navigation";
import { DashList } from "@/components/dash-list";
import { PHASE, permitNeeds, type VenueDashboard } from "@/lib/dashboard";
import { PERMIT_STATE, venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";

export const metadata = { title: "Venue dashboard" };

const VISIT_STATE: Record<string, string> = { requested: "Requested", approved: "Approved" };

// The venue's five groups (Q204): actions, owners and deadlines, never headline counts (CLAUDE.md §6).
export default async function Dashboard({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/dashboard");
  const db = await supabaseServer();
  const { data: scopes } = await db.rpc("report_scopes");
  const venues = ((scopes as { venues?: Array<{ id: string; name: string }> } | null)?.venues ?? []);
  if (venues.length === 0) {
    return (
      <>
        <h1>Venue dashboard</h1>
        <p>The venue dashboard is for a venue&apos;s administrators and the people it has appointed. You have neither role at any venue.</p>
        {session.organisationAdmin.length ? <p>Your organisation&apos;s dashboard is on <Link href={`/organisation/${session.organisationAdmin[0]!.organisation_id}`}>its page</Link>.</p> : null}
      </>
    );
  }
  const { venue: chosen } = await searchParams;
  const venueId = venues.some((v) => v.id === chosen) ? chosen! : venues[0]!.id;
  const { data } = await db.rpc("venue_dashboard", { p_venue_id: venueId });
  const d = data as VenueDashboard | { ok: false; reason: string } | null;
  if (!d || !d.ok) return <><h1>Venue dashboard</h1><p>{d && "reason" in d ? d.reason : "The dashboard could not be loaded."}</p></>;
  const tz = d.timezone;

  // Group today's work by location, then event phase.
  const byPlace = new Map<string, VenueDashboard["work"]>();
  for (const p of d.work) {
    const key = `${p.areas.join(", ") || "No area recorded"}${p.phase ? ` · ${PHASE[p.phase] ?? p.phase}${p.event ? ` (${p.event})` : ""}` : ""}`;
    byPlace.set(key, [...(byPlace.get(key) ?? []), p]);
  }

  return (
    <>
      <h1>{d.venue}: what needs doing</h1>
      <p className="muted">From {venueTime(d.from, tz)} to {venueTime(d.to, tz)}, venue time. Each line is a recorded decision or one still to make, with who owns it. Nothing here means work is safe or compliant.</p>
      {venues.length > 1 ? (
        <form className="inline no-print" method="get">
          <label>Venue <select name="venue" defaultValue={venueId}>{venues.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label>
          <button type="submit" className="secondary">Show</button>
        </form>
      ) : null}
      <p className="no-print"><Link href={`/reports?venue=${venueId}`}>Reports for this venue</Link> · <Link href="/live">Live board</Link> · <Link href="/review">Decisions waiting for you</Link></p>

      <section aria-labelledby="h-work">
        <h2 id="h-work">Today&apos;s and tomorrow&apos;s work</h2>
        {d.work.length === 0 ? <p>No work is approved, issued or live in this period.</p> : [...byPlace.entries()].map(([place, permits]) => (
          <div key={place}>
            <h3>{place}</h3>
            <div className="table-wrap"><table className="stacked">
              <thead><tr><th scope="col">Permit</th><th scope="col">Recorded state</th><th scope="col">Needs</th><th scope="col">From</th><th scope="col">Until</th></tr></thead>
              <tbody>{permits.map((p) => (
                <tr key={p.id}>
                  <td data-label="Permit"><Link href={`/permits/${p.id}`}>{p.job_reference} — {p.class_name}</Link><div className="muted">{p.job_title} · {p.organisation}</div></td>
                  <td data-label="Recorded state">{PERMIT_STATE[p.status] ?? p.status}</td>
                  <td data-label="Needs">{permitNeeds(p).length ? <ul className="m-0">{permitNeeds(p).map((n, i) => <li key={i}>{n.what} <span className="muted">— {n.who}</span></li>)}</ul>
                    : p.status === "approved_for_issue" ? "Waiting to be issued: see decisions due below" : "Nothing recorded as outstanding"}</td>
                  <td data-label="From">{venueTime(p.starts_at, tz)}</td>
                  <td data-label="Until">{venueTime(p.window_end, tz)}</td>
                </tr>
              ))}</tbody>
            </table></div>
          </div>
        ))}
        <h3>Visits in this period</h3>
        <p className="muted">A visit is permission to enter only. It never permits work.</p>
        {d.visits.length === 0 ? <p>No visits.</p> : (
          <ul>{d.visits.map((v) => (
            <li key={v.id}><Link href={`/visits/${v.id}`}>{v.reference}</Link> — {v.organisation}, {v.purpose ?? "visit"} ({VISIT_STATE[v.status] ?? v.status})
              <span className="muted"> · {v.areas.join(", ")} · {venueTime(v.from, tz)} to {venueTime(v.to, tz)}</span></li>
          ))}</ul>
        )}
      </section>

      <DashList heading="Decisions due and missing prerequisites" items={d.due} tz={tz} />
      <DashList heading="Stopped work and controls in progress" items={d.stopped} tz={tz} empty="No work stopped and no controls in progress." />
      <DashList heading="Hand-backs, continuing controls and exceptions" items={d.closing} tz={tz} />
      <DashList heading="Restrictions and expiries affecting this work or these visits" items={d.affecting} tz={tz}
        empty="Nothing recorded affects the work or visits in this period." />
    </>
  );
}
