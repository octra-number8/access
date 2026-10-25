import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { ContentView } from "@/components/screening/content-view";
import { date } from "@/lib/labels";
import type { ScreeningContent } from "@/lib/screening/content";
import { SUGGESTED_CLASSES } from "@/lib/screening/starter";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import {
  createPermitClass, createWorkType, loadStarter, proposeScreening, removeQuestion, removeRule, startScreeningDraft,
} from "./actions";
import { Preview, QuestionForm, RuleForm } from "./forms";

export const metadata = { title: "Activity screening" };

const STATE: Record<string, string> = {
  draft: "draft", proposed: "proposed, waiting for the technical authority", approved: "approved and in use",
  rejected: "rejected", superseded: "replaced by a later version",
};

export default async function Screening() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/screening");
  if (session.tenantAdminCustomerIds.length === 0) return <p>Screening set-up is available to tenant administrators only.</p>;
  const db = await supabaseServer();
  const { data: venues } = await db.from("venue").select("id, name").in("customer_id", session.tenantAdminCustomerIds).order("name");
  const venue = (venues ?? [])[0];
  if (!venue) return <p>No venue yet.</p>;
  const [classes, workTypes, versions] = await Promise.all([
    db.from("permit_class").select("id, code, name, handling, retired_at").eq("venue_id", venue.id).order("name"),
    db.from("work_type").select("id, code, label, retired_at").eq("venue_id", venue.id).order("label"),
    db.from("screening_set_version").select("id, version_no, status, content, source_ref, row_version, decided_at, decision_reason, decided_by_person_id")
      .eq("venue_id", venue.id).order("version_no", { ascending: false }),
  ]);
  const classMap = new Map((classes.data ?? []).map((c) => [c.id, { name: c.name, handling: c.handling }]));
  const current = (versions.data ?? []).find((v) => v.status === "draft" || v.status === "proposed");
  const approved = (versions.data ?? []).find((v) => v.status === "approved");
  const activeClasses = (classes.data ?? []).filter((c) => !c.retired_at);
  const k = () => randomUUID();
  const missingSuggested = SUGGESTED_CLASSES.filter((s) => !activeClasses.some((c) => c.code.toUpperCase() === s.code && c.handling === s.handling));

  return (
    <>
      <p><Link href="/venue">Venue administration</Link></p>
      <h1>Activity screening — {venue.name}</h1>
      <div className="notice">
        <p className="notice-title">What this does, and what it does not</p>
        <p>Applicants answer these questions about their job. Each rule says which permit class an answer leads to, and why. The result only says which permits a job needs: it never authorises work, entry or isolation.</p>
        <p>The questions and rules are for the venue&apos;s technical authority to validate and approve (Q55–Q59). Nothing here is in use until they approve it.</p>
      </div>

      <h2>Permit classes</h2>
      <div className="table-wrap"><table>
        <thead><tr><th scope="col">Code</th><th scope="col">Name</th><th scope="col">Handled by</th></tr></thead>
        <tbody>{(classes.data ?? []).map((c) => (
          <tr key={c.id}><td>{c.code}</td><td>{c.name}</td><td>{c.handling === "external_reference" ? "External reference (deferred specialist work)" : "Permit"}</td></tr>
        ))}</tbody>
      </table></div>
      <details>
        <summary>Add a permit class</summary>
        {missingSuggested.length > 0 ? (
          <p className="muted">The starter set refers to: {missingSuggested.map((s) => `${s.code} ${s.name}${s.handling === "external_reference" ? " (specialist, external reference)" : ""}`).join("; ")}.</p>
        ) : null}
        <ActionForm action={createPermitClass} what="Adding this class" submitLabel="Add class">
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
          <label>Code<input name="code" required pattern="[A-Za-z0-9_-]+" /></label>
          <label>Name<input name="name" required /></label>
          <label>Handled by
            <select name="handling" defaultValue="permit">
              <option value="permit">A permit issued at this venue</option>
              <option value="external_reference">External reference: deferred specialist work, held until an authority accepts outside evidence</option>
            </select>
          </label>
        </ActionForm>
      </details>

      <h2>Work types</h2>
      <p className="muted">The starting branches applicants choose from (Q50).</p>
      {(workTypes.data ?? []).length === 0 ? <p>None yet. Applicants cannot start a job until there is at least one.</p> : (
        <ul>{(workTypes.data ?? []).map((w) => <li key={w.id}>{w.label}</li>)}</ul>
      )}
      <details>
        <summary>Add a work type</summary>
        <ActionForm action={createWorkType} what="Adding this work type" submitLabel="Add work type">
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
          <label>Short code<input name="code" required pattern="[A-Za-z0-9_-]+" placeholder="e.g. MAINT" /></label>
          <label>Name<input name="label" required placeholder="e.g. Routine maintenance" /></label>
        </ActionForm>
      </details>

      <h2>Screening versions</h2>
      <ul>{(versions.data ?? []).map((v) => (
        <li key={v.id}>Version {v.version_no} — {STATE[v.status] ?? v.status}{v.decided_at ? ` (${date(v.decided_at)}: ${v.decision_reason})` : ""}</li>
      ))}</ul>
      {!approved ? <p className="notice notice-blocked">No screening is approved yet, so no job can be submitted at this venue.</p> : null}

      {current ? (
        <div className="panel">
          <h2>Version {current.version_no} — {STATE[current.status]}</h2>
          {current.source_ref ? <p className="muted">Source: {current.source_ref}</p> : null}
          {current.status === "draft" ? (
            <>
              <ActionForm action={loadStarter} what="Loading the starter set" submitLabel="Replace this draft with the Octra starter set" secondary>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="venue_id" value={venue.id} />
                <input type="hidden" name="version_id" value={current.id} />
                <p className="muted">Drawn from the trigger activities in Q56 and Q183. It is a proposal for your technical authority to validate, not an approved procedure.</p>
              </ActionForm>
              <ContentView content={current.content as ScreeningContent} classes={classMap}
                questionAction={(qk) => (
                  <ActionForm action={removeQuestion} what="Removing this question" submitLabel="Remove" secondary>
                    <input type="hidden" name="key" value={k()} />
                    <input type="hidden" name="version_id" value={current.id} />
                    <input type="hidden" name="question_key" value={qk} />
                  </ActionForm>
                )}
                ruleAction={(rk) => (
                  <ActionForm action={removeRule} what="Removing this rule" submitLabel="Remove" secondary>
                    <input type="hidden" name="key" value={k()} />
                    <input type="hidden" name="version_id" value={current.id} />
                    <input type="hidden" name="rule_key" value={rk} />
                  </ActionForm>
                )} />
              <details><summary>Add a question</summary>
                <QuestionForm versionId={current.id} content={current.content as ScreeningContent} newKey={k()} />
              </details>
              <details><summary>Add a rule</summary>
                {activeClasses.length === 0 ? <p>Add a permit class first.</p> : (
                  <RuleForm versionId={current.id} content={current.content as ScreeningContent} newKey={k()}
                    classes={activeClasses.map((c) => ({ id: c.id, name: c.name, handling: c.handling }))} />
                )}
              </details>
              <h3>Try it</h3>
              <Preview versionId={current.id} content={current.content as ScreeningContent} />
              <h3>Propose for approval</h3>
              <ActionForm action={proposeScreening} what="Proposing this version" submitLabel="Propose to the technical authority">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="version_id" value={current.id} />
                <input type="hidden" name="row_version" value={current.row_version} />
                <p className="muted">Once proposed it cannot be edited. The person who proposes it cannot approve it.</p>
              </ActionForm>
            </>
          ) : (
            <>
              <ContentView content={current.content as ScreeningContent} classes={classMap} />
              <h3>Try it</h3>
              <Preview versionId={current.id} content={current.content as ScreeningContent} />
            </>
          )}
        </div>
      ) : (
        <ActionForm action={startScreeningDraft} what="Starting a draft" submitLabel={approved ? "Start a new version from the approved one" : "Start the first version"}>
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
        </ActionForm>
      )}

      {approved ? (
        <details>
          <summary>The approved version in use (version {approved.version_no})</summary>
          <ContentView content={approved.content as ScreeningContent} classes={classMap} />
        </details>
      ) : null}
    </>
  );
}
