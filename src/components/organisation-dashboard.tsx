import Link from "next/link";
import { DashList } from "@/components/dash-list";
import { type OrganisationDashboard as Dash, permitNeeds, requestNeeds } from "@/lib/dashboard";
import { PERMIT_STATE, venueTime } from "@/lib/permits";
import { supabaseServer } from "@/lib/supabase/server";

const JOB_STATE: Record<string, string> = { draft: "Draft: screening not submitted", screening: "Screening: permits being settled", routed: "Permit routing settled" };

// The organisation's five groups (Q205), for its administrators. The occupier and the venue's
// appointees are never named here (P5-6): decisions are owned by a role.
export async function OrganisationDashboard({ organisationId }: { organisationId: string }) {
  const db = await supabaseServer();
  const { data } = await db.rpc("organisation_dashboard", { p_organisation_id: organisationId });
  const d = data as Dash | { ok: false } | null;
  if (!d || !d.ok) return null;
  const tz = d.jobs[0]?.timezone ?? d.visits[0]?.timezone ?? d.live[0]?.venue_timezone ?? "Europe/London";

  return (
    <section aria-labelledby="h-org-dash" className="panel">
      <h2 id="h-org-dash">What your organisation needs to do</h2>
      <p className="muted">Each line is a recorded decision or one still to make, with who owns it. <Link href={`/reports?organisation=${organisationId}`}>Reports on your own work</Link></p>

      <h3>Jobs and visits due next</h3>
      {d.jobs.length === 0 && d.visits.length === 0 ? <p>Nothing planned.</p> : null}
      {d.jobs.length ? (
        <div className="table-wrap"><table className="stacked">
          <thead><tr><th scope="col">Job</th><th scope="col">When</th><th scope="col">Permits and what each needs</th></tr></thead>
          <tbody>{d.jobs.map((j) => (
            <tr key={j.id}>
              <td data-label="Job"><Link href={`/jobs/${j.id}`}>{j.reference}</Link> — {j.title}<div className="muted">{j.venue} · {JOB_STATE[j.status] ?? j.status}</div></td>
              <td data-label="When">{venueTime(j.from, j.timezone)} to {venueTime(j.to, j.timezone)}</td>
              <td data-label="Permits">{j.permits.length === 0 ? (j.status === "routed" ? "No permits" : "Permits are settled when screening is decided") : (
                <ul className="m-0">{j.permits.map((p) => (
                  <li key={p.id}><Link href={`/permits/${p.id}`}>{p.class_name}</Link>: {PERMIT_STATE[p.status] ?? p.status}
                    {p.missing.length ? <ul>{p.missing.map((m, i) => <li key={i}>Missing before issue: {m.problem} <span className="muted">— {m.who}</span></li>)}</ul>
                      : requestNeeds(p.status) ? <span className="muted"> — {requestNeeds(p.status)}</span> : null}</li>
                ))}</ul>
              )}</td>
            </tr>
          ))}</tbody>
        </table></div>
      ) : null}
      {d.visits.length ? (
        <>
          <p className="muted">Visits are permission to enter only. They never permit work.</p>
          <ul>{d.visits.map((v) => (
            <li key={v.id}><Link href={`/visits/${v.id}`}>{v.reference}</Link> — {v.purpose ?? "visit"} at {v.venue}, {venueTime(v.from, v.timezone)} to {venueTime(v.to, v.timezone)}:{" "}
              {v.status === "approved" ? "approved" : v.consents_refused ? "an affected occupier refused consent" : v.consents_waiting ? "waiting for an affected occupier's consent" : "waiting for the venue's decision"}</li>
          ))}</ul>
        </>
      ) : null}

      <DashList heading="Requests returned to you" items={d.returned} tz={tz} empty="Nothing returned." level={3} />
      <DashList heading="Workers needing something for planned work" items={d.workers} tz={tz} empty="Nothing missing for the work planned." level={3} />
      <DashList heading="Venue decisions you are waiting for" items={d.venue_decisions} tz={tz} empty="No venue decisions outstanding." level={3} />

      <h3>Live permits, stopped work and hand-backs due</h3>
      {d.live.length === 0 ? <p>No live permits.</p> : (
        <ul>{d.live.map((p) => (
          <li key={p.id}><Link href={`/permits/${p.id}`}>{p.job_reference} — {p.class_name}</Link>: {PERMIT_STATE[p.status] ?? p.status}
            {permitNeeds(p).length ? <ul>{permitNeeds(p).map((n, i) => <li key={i}>{n.what} <span className="muted">— {n.who}</span></li>)}</ul> : null}</li>
        ))}</ul>
      )}
    </section>
  );
}
