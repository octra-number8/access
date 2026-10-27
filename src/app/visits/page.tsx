import Link from "next/link";
import { redirect } from "next/navigation";
import { visitState } from "@/lib/gate";
import { venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";

export const metadata = { title: "Visits" };

// Visits the signed-in user can see (Q120–Q126): actions first, then current, then the rest.
// A visit is permission to be somewhere for a purpose; it is never permission to work (Q122).
export default async function Visits() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/visits");
  const db = await supabaseServer();
  const [{ data: visits }, { data: orgs }, { data: venues }] = await Promise.all([
    db.from("access_authorisation").select("id, reference, venue_id, organisation_id, purpose_key, purpose_config_id, description, starts_at, ends_at, status")
      .order("starts_at", { ascending: false }).limit(200),
    db.from("organisation").select("id, legal_name"),
    db.from("venue").select("id, name, timezone"),
  ]);
  const { data: configs } = await db.from("venue_config_version").select("id, content").in("id", [...new Set((visits ?? []).map((v) => v.purpose_config_id))]);
  const purposeName = (configId: string, key: string) =>
    ((configs ?? []).find((c) => c.id === configId)?.content as { purposes?: Array<{ key: string; name: string }> } | undefined)?.purposes?.find((p) => p.key === key)?.name ?? key;
  const orgName = new Map((orgs ?? []).map((o) => [o.id, o.legal_name]));
  const venue = new Map((venues ?? []).map((v) => [v.id, v]));
  const now = Date.now();
  const waiting = (visits ?? []).filter((v) => v.status === "requested");
  const current = (visits ?? []).filter((v) => v.status === "approved" && new Date(v.ends_at).getTime() >= now);
  const rest = (visits ?? []).filter((v) => !waiting.includes(v) && !current.includes(v));
  const canAsk = session.organisationAdmin.length > 0 || session.tenantAdminCustomerIds.length > 0;

  const list = (rows: typeof waiting) => rows.length === 0 ? <p>None.</p> : (
    <div className="table-wrap"><table>
      <thead><tr><th scope="col">Visit</th><th scope="col">Organisation</th><th scope="col">Purpose</th><th scope="col">When</th><th scope="col">State</th></tr></thead>
      <tbody>{rows.map((v) => {
        const tz = venue.get(v.venue_id)?.timezone ?? "Europe/London";
        return (
          <tr key={v.id}>
            <td><Link href={`/visits/${v.id}`}>{v.reference}</Link><br /><span className="muted">{venue.get(v.venue_id)?.name}</span></td>
            <td>{orgName.get(v.organisation_id) ?? "—"}</td>
            <td>{purposeName(v.purpose_config_id, v.purpose_key)}<br /><span className="muted">{v.description}</span></td>
            <td>{venueTime(v.starts_at, tz)} to {venueTime(v.ends_at, tz)}</td>
            <td>{visitState(v.status, v.ends_at)}</td>
          </tr>
        );
      })}</tbody>
    </table></div>
  );

  return (
    <>
      <h1>Visits</h1>
      <p className="muted">A visit lets named people be in named places, for a stated purpose, at stated times. It never allows work: work needs a job and, where required, a permit.</p>
      {canAsk ? <p><Link href="/visits/new" className="button">Ask for a visit</Link></p> : null}
      <h2>Waiting for a decision</h2>
      {list(waiting)}
      <h2>Approved and current</h2>
      {list(current)}
      <h2>Earlier, refused or cancelled</h2>
      {list(rest)}
    </>
  );
}
