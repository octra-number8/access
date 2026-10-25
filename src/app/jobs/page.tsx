import Link from "next/link";
import { redirect } from "next/navigation";
import { JOB_STATE, type JobDetail, nextAction } from "@/lib/jobs";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";

export const metadata = { title: "Jobs" };

// Q54: each job with its next action and who owns it; no headline counts.
export default async function Jobs() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/jobs");
  const db = await supabaseServer();
  const { data: rows } = await db.from("work_package").select("id, status, created_at").order("created_at", { ascending: false });
  const jobs = (await Promise.all((rows ?? []).map(async (r) => (await db.rpc("work_package_detail", { p_work_package_id: r.id })).data)))
    .filter((j): j is JobDetail => Boolean(j?.ok));
  const canStart = session.organisationAdmin.length > 0 || session.tenantAdminCustomerIds.length > 0;
  const open = jobs.filter((j) => j.status !== "cancelled");

  return (
    <>
      <h1>Jobs</h1>
      <p className="muted">A job describes work you plan to do at a venue. Screening works out which permits it needs. Nothing on this page is permission to enter or to start work.</p>
      {canStart ? <p><Link href="/jobs/new" className="button">Start a job</Link></p> : null}
      {open.length === 0 ? <p>No jobs yet.</p> : (
        <div className="table-wrap"><table>
          <thead><tr><th scope="col">Job</th><th scope="col">Recorded state</th><th scope="col">Next action</th><th scope="col">Who</th></tr></thead>
          <tbody>{open.map((j) => {
            const next = nextAction(j);
            return (
              <tr key={j.id}>
                <td><Link href={`/jobs/${j.id}`}>{j.reference} — {j.revision.title}</Link><div className="muted">{j.performing_organisation} · {j.venue}</div></td>
                <td>{JOB_STATE[j.status] ?? j.status}</td>
                <td>{next?.what ?? "—"}</td>
                <td>{next?.who ?? "—"}</td>
              </tr>
            );
          })}</tbody>
        </table></div>
      )}
      {jobs.some((j) => j.status === "cancelled") ? (
        <details><summary>Cancelled jobs</summary>
          <ul>{jobs.filter((j) => j.status === "cancelled").map((j) => (
            <li key={j.id}><Link href={`/jobs/${j.id}`}>{j.reference} — {j.revision.title}</Link> <span className="muted">({j.cancel_reason})</span></li>
          ))}</ul>
        </details>
      ) : null}
    </>
  );
}
