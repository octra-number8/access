import { randomUUID } from "node:crypto";
import Link from "next/link";
import { ActionForm } from "@/components/ActionForm";
import { ContentView } from "@/components/screening/content-view";
import { day, type JobDetail, lastDay } from "@/lib/jobs";
import type { ScreeningContent } from "@/lib/screening/content";
import { supabaseServer } from "@/lib/supabase/server";
import { decideChallenge, decideHold, decideScreeningVersion, recordNoPermitRequired } from "../admin-actions";

/** One line that says which job, where and when, for every decision below. */
function JobLine({ j }: { j: JobDetail }) {
  return (
    <p><Link href={`/jobs/${j.id}`}>{j.reference} — {j.revision.title}</Link>
      <span className="muted"> · {j.performing_organisation} · {j.revision.areas.map((a) => a.name).join(", ")} · {day(j.revision.window_from)} to {lastDay(j.revision.window_to)}</span></p>
  );
}

const WORDING_HINT = "Say what was decided, for which work, where and when, e.g. \"No hot works permit for cold cutting of sockets at stand 1, Hall 1, 3–4 November\". Never \"approved\" or \"safe\".";

// Decisions for appointees (Q55-Q59): the database refuses anyone whose appointment does
// not cover the class and every area of the job, and anyone connected with it.
export async function ScreeningDecisions() {
  const db = await supabaseServer();
  const [{ data: versions }, { data: classes }, { data: rows }] = await Promise.all([
    db.from("screening_set_version").select("id, venue_id, version_no, content, source_ref, row_version").eq("status", "proposed"),
    db.from("permit_class").select("id, name, handling"),
    db.from("work_package").select("id").eq("status", "screening"),
  ]);
  const classMap = new Map((classes ?? []).map((c) => [c.id, { name: c.name, handling: c.handling }]));
  const jobs = (await Promise.all((rows ?? []).map(async (r) => (await db.rpc("work_package_detail", { p_work_package_id: r.id })).data)))
    .filter((j): j is JobDetail => Boolean(j?.ok));
  const challenges = jobs.flatMap((j) => j.recommendations.filter((r) => r.status === "challenged").map((r) => ({ j, r })));
  const holds = jobs.flatMap((j) => j.holds.filter((h) => h.status === "open").map((h) => ({ j, h })));
  const needNpr = jobs.filter((j) => j.routable_blockers?.needs_no_permit_decision
    && j.routable_blockers.open_holds === 0 && j.routable_blockers.refused_holds === 0);
  const k = () => randomUUID();

  return (
    <>
      <h2>Activity screening to approve</h2>
      {(versions ?? []).length === 0 ? <p>None.</p> : null}
      {(versions ?? []).map((v) => (
        <div className="panel" key={v.id}>
          <p><strong>Screening version {v.version_no}</strong>{v.source_ref ? <span className="muted"> · Source: {v.source_ref}</span> : null}</p>
          <p className="muted">Approving it means every job submitted from now on is screened with these questions and rules. Check each rule against the venue&apos;s procedures (Q55–Q59).</p>
          <ContentView content={v.content as ScreeningContent} classes={classMap} />
          <ActionForm action={decideScreeningVersion} what="Approving this screening" submitLabel="Approve">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={v.id} />
            <input type="hidden" name="row_version" value={v.row_version} />
            <input type="hidden" name="decision" value="approve" />
            <label>Reason<input name="reason" required placeholder="e.g. Checked against the venue's permit procedures, rev. 4" /></label>
          </ActionForm>
          <ActionForm action={decideScreeningVersion} what="Rejecting this screening" submitLabel="Reject" secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={v.id} />
            <input type="hidden" name="row_version" value={v.row_version} />
            <input type="hidden" name="decision" value="reject" />
            <label>What needs to change<input name="reason" required /></label>
          </ActionForm>
        </div>
      ))}

      <h2>Challenged recommendations</h2>
      {challenges.length === 0 ? <p>None.</p> : null}
      {challenges.map(({ j, r }) => (
        <div className="panel" key={r.id}>
          <JobLine j={j} />
          <p>Screening recommended <strong>{r.class_name}</strong>: {r.reasons.map((x) => x.rationale).join(" ")}</p>
          <p>{r.challenge?.by} challenged it: &ldquo;{r.challenge?.reason}&rdquo;{r.challenge?.documents ? ` (${r.challenge.documents} supporting document${r.challenge.documents === 1 ? "" : "s"}; open the job to read them)` : ""}</p>
          <ActionForm action={decideChallenge} what="Deciding this challenge" submitLabel="The permit is required" >
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="recommendation_id" value={r.id} />
            <input type="hidden" name="row_version" value={r.row_version} />
            <input type="hidden" name="outcome" value="upheld" />
            <label>Reason<input name="reason" required /></label>
          </ActionForm>
          <details><summary>Or record that no permit is required</summary>
            <ActionForm action={decideChallenge} what="Deciding this challenge" submitLabel="Record: no permit required" secondary>
              <input type="hidden" name="key" value={k()} />
              <input type="hidden" name="recommendation_id" value={r.id} />
              <input type="hidden" name="row_version" value={r.row_version} />
              <input type="hidden" name="outcome" value="not_required" />
              <label>Scope of the decision<textarea name="scope_wording" required rows={2} placeholder={WORDING_HINT} /></label>
              <label>Reason<input name="reason" required /></label>
            </ActionForm>
          </details>
        </div>
      ))}

      <h2>Jobs where screening recommended no permit</h2>
      <p className="muted">No recommendation is not a decision. Record whether any permit is needed (Q59).</p>
      {needNpr.length === 0 ? <p>None.</p> : null}
      {needNpr.map((j) => (
        <div className="panel" key={j.id}>
          <JobLine j={j} />
          <p>{j.revision.scope}</p>
          {j.screening ? <details><summary>The answers given</summary>
            <ul>{j.screening.answers.map((a, i) => <li key={i}>{a.question} — <strong>{a.answer}</strong></li>)}</ul></details> : null}
          <ActionForm action={recordNoPermitRequired} what="Recording this decision" submitLabel="Record: no permit required">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="work_package_id" value={j.id} />
            <input type="hidden" name="row_version" value={j.row_version} />
            <label>Scope of the decision<textarea name="scope_wording" required rows={2} placeholder={WORDING_HINT} /></label>
            <label>Reason<input name="reason" required /></label>
          </ActionForm>
          <p className="muted">If a permit is needed, do not record this. The job stays unresolved; ask the applicant to change the job and select the permit when they screen it again, and ask the venue whether a screening rule is missing.</p>
        </div>
      ))}

      <h2>Specialist work held for external evidence</h2>
      {holds.length === 0 ? <p>None.</p> : null}
      {holds.map(({ j, h }) => (
        <div className="panel" key={h.id}>
          <JobLine j={j} />
          <p><strong>{h.class_name}</strong>: {h.reasons.map((x) => x.rationale).join(" ")}</p>
          {h.evidence.length === 0 ? <p>No evidence provided yet.</p> : h.evidence.map((e, n) => (
            <p key={n}>Evidence: {e.decider}, {e.organisation}{e.reference ? ` (ref. ${e.reference})` : ""}, {day(e.decided_on)} — {e.scope}{e.conditions ? `. Conditions: ${e.conditions}` : ""}</p>
          ))}
          <ActionForm action={decideHold} what="Accepting this evidence" submitLabel="Accept the evidence">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="hold_id" value={h.id} />
            <input type="hidden" name="row_version" value={h.row_version} />
            <input type="hidden" name="outcome" value="accepted" />
            <label>Reason<input name="reason" required /></label>
          </ActionForm>
          <ActionForm action={decideHold} what="Refusing this evidence" submitLabel="Refuse the evidence" secondary>
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="hold_id" value={h.id} />
            <input type="hidden" name="row_version" value={h.row_version} />
            <input type="hidden" name="outcome" value="refused" />
            <label>Reason<input name="reason" required /></label>
          </ActionForm>
        </div>
      ))}
    </>
  );
}
