import { redirect } from "next/navigation";
import { date } from "@/lib/labels";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";

export const metadata = { title: "Platform operations" };

const SETTING_TEXT: Record<string, Record<string, string>> = {
  malware_scanning: {
    off: "Off: uploads are recorded as not scanned and are usable at once (D-014)",
    required: "Required: uploads are released only once a scanner records them clean",
  },
};

// Platform operations: read-only health and settings. Settings change only by migration.
export default async function Operations() {
  if (!(await getSession())) redirect("/sign-in?next=/operations");
  const db = await supabaseServer();
  const { data: isOps } = await db.rpc("am_platform_admin");
  if (!isOps) return <p>Platform operations are available to Octra platform administrators only.</p>;
  const [{ data: settings }, { data: scanners }, { data: runs }, { data: failedMail }, { data: files }] = await Promise.all([
    db.from("platform_setting").select("key, value, effective_from, decision_ref").order("key"),
    db.from("scanner_status").select("*").order("recorded_at", { ascending: false }),
    db.from("job_run").select("job, started_at, finished_at, outcome, counts, error").order("started_at", { ascending: false }).limit(300),
    db.from("notification_delivery").select("id, channel, attempts, last_error, created_at").eq("delivery_state", "failed").order("created_at", { ascending: false }).limit(50),
    db.rpc("file_removal_status"),
  ]);
  const removal = files as { waiting?: number; failing?: Array<{ since: string; attempts: number; last_error: string }> } | null;
  // Each scheduled job runs every minute (P8-6): warn when one has not succeeded for five.
  const jobs = ["expiry", "notifications", "email", "packs", "retention"].map((job) => {
    const mine = (runs ?? []).filter((r) => r.job === job);
    const lastOk = mine.find((r) => r.outcome === "ok");
    return { job, last: mine[0], lastOk, stale: !lastOk || Date.now() - new Date(lastOk.finished_at!).getTime() > 5 * 60_000 };
  });

  return (
    <>
      <h1>Platform operations</h1>
      <p className="muted">Platform administration grants no authority over any venue&apos;s decisions (invariant 9).</p>

      <h2>Platform settings</h2>
      <p className="muted">Changed only by a reviewed database migration, never on this page.</p>
      <div className="table-wrap"><table>
        <thead><tr><th scope="col">Setting</th><th scope="col">Value</th><th scope="col">Since</th><th scope="col">Decision</th></tr></thead>
        <tbody>{(settings ?? []).map((s) => (
          <tr key={s.key}><td>{s.key.replace("_", " ")}</td><td>{SETTING_TEXT[s.key]?.[String(s.value)] ?? String(s.value)}</td>
            <td>{date(s.effective_from)}</td><td>{s.decision_ref ?? "—"}</td></tr>
        ))}</tbody>
      </table></div>

      <h2>Scheduled jobs</h2>
      <p className="muted">Run every minute by the scheduler, as the job runner service account. A job never approves or closes anything.</p>
      <div className="table-wrap"><table>
        <thead><tr><th scope="col">Job</th><th scope="col">Last run</th><th scope="col">Last success</th><th scope="col">Counts</th></tr></thead>
        <tbody>{jobs.map((j) => (
          <tr key={j.job}>
            <td>{j.job}{j.stale ? <span className="tag">No success in the last five minutes</span> : null}</td>
            <td>{j.last ? `${new Date(j.last.started_at).toLocaleString("en-GB")}: ${j.last.outcome ?? "running"}` : "Never"}
              {j.last?.error ? <div className="muted">{j.last.error}</div> : null}</td>
            <td>{j.lastOk ? new Date(j.lastOk.finished_at!).toLocaleString("en-GB") : "Never"}</td>
            <td>{j.lastOk ? Object.entries(j.lastOk.counts as Record<string, unknown>).map(([k, v]) => `${k.replace(/_/g, " ")} ${typeof v === "object" ? JSON.stringify(v) : v}`).join("; ") : "—"}</td>
          </tr>
        ))}</tbody>
      </table></div>

      <h2>Emails that could not be sent</h2>
      <p className="muted">After five attempts. The notice is still in the person&apos;s inbox. Content is not shown here.</p>
      {(failedMail ?? []).length === 0 ? <p>None.</p> : (
        <ul>{(failedMail ?? []).map((d) => <li key={d.id}>{new Date(d.created_at).toLocaleString("en-GB")} · {d.channel} · {d.attempts} attempts: {d.last_error}</li>)}</ul>
      )}

      <h2>Disposed files still in storage</h2>
      <p className="muted">Files whose disposal a venue confirmed (8d). They are no longer released to anyone; the retention job removes them from storage. Paths and contents are not shown here.</p>
      <p>{removal?.waiting ? `${removal.waiting} waiting to be removed.` : "None waiting."}</p>
      {removal?.failing?.length ? (
        <ul>{removal.failing.map((f, i) => <li key={i}>Disposed {new Date(f.since).toLocaleString("en-GB")} · {f.attempts} attempts: {f.last_error}</li>)}</ul>
      ) : null}

      <h2>Malware scanners</h2>
      {(scanners ?? []).length === 0 ? <p>No scanner has reported. That is expected while scanning is off (D-014).</p> : (
        <div className="table-wrap"><table>
          <thead><tr><th scope="col">Last report</th><th scope="col">State</th><th scope="col">Engine</th><th scope="col">Signatures</th><th scope="col">Waiting</th></tr></thead>
          <tbody>{(scanners ?? []).map((s) => (
            <tr key={s.scanner_user_id}>
              <td>{new Date(s.recorded_at).toLocaleString("en-GB")}</td><td>{s.state}</td><td>{s.engine_version}</td>
              <td>{s.signature_version}, dated {date(s.signature_date)}</td>
              <td>{s.queue_depth}{s.oldest_pending_at ? <div className="muted">oldest since {new Date(s.oldest_pending_at).toLocaleString("en-GB")}</div> : null}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
    </>
  );
}
