import { randomUUID } from "node:crypto";
import Link from "next/link";
import { ActionForm } from "@/components/ActionForm";
import { ConfigView } from "@/components/permits/config-view";
import type { ClassConfig } from "@/lib/permits";
import { PERMIT_STATE, STEP_KIND, venueTime } from "@/lib/permits";
import { supabaseServer } from "@/lib/supabase/server";
import { decideClassVersion } from "../permits/actions";

// The reviewer's and issuer's queues (Q76-Q99): actions, owners and dates, no counts.
// Whether someone may decide is still settled by the database when they try.
export async function PermitDecisions() {
  const db = await supabaseServer();
  const [{ data: versions }, { data: classes }, { data: steps }, { data: ready }, { data: exceptions }, systemTypes, courses, competencies] = await Promise.all([
    db.from("permit_class_version").select("id, permit_class_id, version_no, content, source_ref, row_version").eq("status", "proposed"),
    db.from("permit_class").select("id, name"),
    db.rpc("open_permit_steps"),
    db.from("permit").select("id, permit_class_id, work_package_id, status").eq("status", "approved_for_issue"),
    db.from("exception_request").select("id, kind, reason, permit_version_id"),
    db.from("system_type").select("id, label"),
    db.from("induction_course").select("id, title"),
    db.from("competency_type").select("id, label"),
  ]);
  const { data: decided } = await db.from("exception_decision").select("exception_request_id");
  const { data: excVersions } = await db.from("permit_version").select("id, permit_id").in("id", (exceptions ?? []).map((e) => e.permit_version_id));
  const className = new Map((classes ?? []).map((c) => [c.id, c.name]));
  const names = new Map<string, string>([
    ...(systemTypes.data ?? []).map((t) => [t.id, t.label] as [string, string]),
    ...(courses.data ?? []).map((c) => [c.id, c.title] as [string, string]),
    ...(competencies.data ?? []).map((c) => [c.id, c.label] as [string, string]),
  ]);
  const openExceptions = (exceptions ?? []).filter((e) => !(decided ?? []).some((d) => d.exception_request_id === e.id));
  const k = () => randomUUID();
  const stepList = (steps ?? []) as Array<{ step_id: string; step_name: string; kind: string; permit_id: string; class_name: string; permit_status: string;
    job_reference: string; job_title: string; organisation: string; window_from: string; venue_timezone: string; party: string | null }>;

  return (
    <>
      <h2>Permit configurations to approve</h2>
      {(versions ?? []).length === 0 ? <p>None.</p> : (versions ?? []).map((v) => (
        <div className="panel" key={v.id}>
          <p><strong>{className.get(v.permit_class_id)}</strong> — version {v.version_no}{v.source_ref ? <span className="muted"> · {v.source_ref}</span> : null}</p>
          <ConfigView config={v.content as ClassConfig} names={names} />
          <ActionForm action={decideClassVersion} what="Approving this configuration" submitLabel="Approve">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={v.id} />
            <input type="hidden" name="row_version" value={v.row_version} />
            <input type="hidden" name="decision" value="approve" />
            <label>Reason<input name="reason" required placeholder="e.g. Checked against the venue's hot works procedure, rev. 3" /></label>
          </ActionForm>
          <ActionForm action={decideClassVersion} what="Rejecting this configuration" submitLabel="Reject" secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={v.id} />
            <input type="hidden" name="row_version" value={v.row_version} />
            <input type="hidden" name="decision" value="reject" />
            <label>What needs to change<input name="reason" required /></label>
          </ActionForm>
        </div>
      ))}

      <h2>Permit steps waiting for a decision</h2>
      {stepList.length === 0 ? <p>None.</p> : (
        <div className="table-wrap"><table>
          <thead><tr><th scope="col">Permit</th><th scope="col">Step</th><th scope="col">Organisation</th><th scope="col">Starts</th></tr></thead>
          <tbody>{stepList.map((s) => (
            <tr key={s.step_id}>
              <td><Link href={`/permits/${s.permit_id}`}>{s.job_reference} — {s.class_name}</Link><div className="muted">{s.job_title} · {PERMIT_STATE[s.permit_status]}</div></td>
              <td>{s.step_name}<div className="muted">{STEP_KIND[s.kind]}{s.party ? ` · ${s.party}` : ""}</div></td>
              <td>{s.organisation}</td>
              <td>{venueTime(s.window_from, s.venue_timezone)}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}

      <h2>Exceptions to decide</h2>
      {openExceptions.length === 0 ? <p>None.</p> : (
        <ul>{openExceptions.map((e) => {
          const permitId = (excVersions ?? []).find((v) => v.id === e.permit_version_id)?.permit_id;
          return <li key={e.id}><Link href={`/permits/${permitId}`}>{e.kind === "late_notice" ? "Late notice" : "Restriction clash"}</Link>: {e.reason}</li>;
        })}</ul>
      )}

      <h2>Permits approved for issue</h2>
      {(ready ?? []).length === 0 ? <p>None.</p> : (
        <ul>{(ready ?? []).map((p) => <li key={p.id}><Link href={`/permits/${p.id}`}>{className.get(p.permit_class_id)}</Link> — open it to see the pre-issue checks</li>)}</ul>
      )}
    </>
  );
}
