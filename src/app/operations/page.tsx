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
  const [{ data: settings }, { data: scanners }] = await Promise.all([
    db.from("platform_setting").select("key, value, effective_from, decision_ref").order("key"),
    db.from("scanner_status").select("*").order("recorded_at", { ascending: false }),
  ]);

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
