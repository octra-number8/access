import { redirect } from "next/navigation";
import { dayIn, isDay, parseScope, type Report, REPORT_KINDS } from "@/lib/dashboard";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";

export const metadata = { title: "Reports" };

type Scopes = {
  venues: Array<{ id: string; name: string }>;
  organisations: Array<{ id: string; name: string; venues: Array<{ id: string; name: string }> }>;
};

// On-screen reports with a CSV download (Q209, P8-15). Each reports what was recorded; none is a
// score. The database decides which rows a person may see.
export default async function Reports({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/reports");
  const db = await supabaseServer();
  const sp = await searchParams;
  const { data } = await db.rpc("report_scopes");
  const scopes = (data ?? { venues: [], organisations: [] }) as Scopes;
  const options = [
    ...scopes.venues.map((v) => ({ value: `venue:${v.id}`, label: `${v.name} (whole venue)` })),
    ...scopes.organisations.flatMap((o) => o.venues.map((v) => ({ value: `org:${o.id}:${v.id}`, label: `${o.name} at ${v.name} (your organisation's rows)` }))),
  ];
  if (options.length === 0) {
    return <><h1>Reports</h1><p>Reports are for a venue&apos;s administrators and appointees, and for an organisation&apos;s administrators about their own work. You have none of these roles.</p></>;
  }
  const preferred = sp.scope ?? (sp.venue ? `venue:${sp.venue}` : undefined)
    ?? (sp.organisation ? options.find((o) => o.value.startsWith(`org:${sp.organisation}:`))?.value : undefined);
  const scope = options.some((o) => o.value === preferred) ? preferred! : options[0]!.value;
  const kinds = REPORT_KINDS.filter((k) => !(k.venueOnly && scope.startsWith("org:")));
  const kind = kinds.some((k) => k.key === sp.kind) ? sp.kind! : kinds[0]!.key;
  const from = isDay(sp.from) ? sp.from : dayIn("UTC", -30);
  const to = isDay(sp.to) ? sp.to : dayIn("UTC");
  const run = sp.kind !== undefined;
  const target = parseScope(scope)!;

  let report: Report | null = null;
  let refusal: string | null = null;
  if (run) {
    const { data: r } = await db.rpc("report", { p_kind: kind, p_venue_id: target.venueId, p_from: from, p_to: to, p_organisation_id: target.organisationId });
    if (r?.ok) report = r as Report;
    else refusal = (r as { reason?: string } | null)?.reason ?? "The report could not be produced.";
  }
  const query = new URLSearchParams({ scope, kind, from, to }).toString();

  return (
    <>
      <h1>Reports</h1>
      <p className="muted">What was recorded in the period, in the venue&apos;s time. A report is not a score and says nothing about whether work was safe or compliant.</p>
      <form method="get" className="panel stack no-print">
        <label>Report on<select name="scope" defaultValue={scope}>{options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</select></label>
        <label>Report<select name="kind" defaultValue={kind}>{kinds.map((k) => <option key={k.key} value={k.key}>{k.label}</option>)}</select></label>
        <p className="m-0 text-sm muted">{REPORT_KINDS.find((k) => k.key === kind)?.about}</p>
        <div className="inline">
          <label>From<input type="date" name="from" defaultValue={from} required /></label>
          <label>To (inclusive)<input type="date" name="to" defaultValue={to} required /></label>
        </div>
        <button type="submit">Show report</button>
      </form>

      {refusal ? <div className="notice notice-blocked" role="alert"><p className="notice-title">Report not shown</p><p className="m-0">{refusal}</p></div> : null}
      {report ? (
        <section aria-labelledby="h-report">
          <h2 id="h-report">{REPORT_KINDS.find((k) => k.key === report.kind)?.label}: {report.organisation ? `${report.organisation} at ` : ""}{report.venue}, {report.from} to {report.to}</h2>
          <p className="no-print"><a href={`/reports/csv?${query}`} download>Download as CSV</a></p>
          {report.rows.length === 0 ? <p>Nothing was recorded in this period.</p> : (
            <div className="table-wrap"><table>
              <thead><tr>{report.columns.map((c) => <th key={c.key} scope="col">{c.label}</th>)}</tr></thead>
              <tbody>{report.rows.map((r, i) => <tr key={i}>{report!.columns.map((c) => <td key={c.key}>{r[c.key] ?? "—"}</td>)}</tr>)}</tbody>
            </table></div>
          )}
        </section>
      ) : null}
    </>
  );
}
