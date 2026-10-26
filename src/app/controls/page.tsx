import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { CONTROL_STATE, type PermitSummary, venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import {
  impairmentStep, isolationStep, issueCustody, liftControlFailure, lockOffOnBehalf, publishControlRule, registerCustodyItem, reportFailureAsAuthority,
  returnCustody, transferControl,
} from "./actions";

export const metadata = { title: "Controls desk" };

type Desk = {
  isolations: Array<{ id: string; system: string; points: string; status: string; row_version: number; from: string; to: string; requested_by: string;
    failure_open: boolean; locks_on: number; venue_timezone: string; jobs: string[] | null;
    continuing: null | { owner: string; review_on: string; reason: string; review_overdue: boolean } }>;
  impairments: Array<{ id: string; system: string; zones: string; status: string; row_version: number; from: string; to: string; requested_by: string;
    max_hours: number | null; impaired_at: string | null; overdue: boolean; failure_open: boolean; venue_timezone: string; jobs: string[] | null;
    continuing: null | { owner: string; review_on: string; reason: string; review_overdue: boolean } }>;
};

const ISO_NEXT: Record<string, string> = {
  requested: "Waiting for the isolation authority to authorise the boundary", authorised: "Waiting for an authorised person to apply it",
  applied: "Waiting to be proved dead", proved: "In place", removed: "Waiting to be returned to service",
};
const IMP_NEXT: Record<string, string> = {
  requested: "Waiting for the authority to authorise it", authorised: "Waiting for measures and notifications, then impairing",
  impaired: "Impaired", tested: "Reinstatement passed: confirm back in service",
};

// The controls desk (design §13): actions, owners and deadlines for isolations and impairments.
export default async function ControlsDesk() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/controls");
  const db = await supabaseServer();
  const [{ data: desk }, { data: failures }, { data: resolutions }, { data: locks }, { data: impairmentRows }, { data: rules }, { data: types },
         { data: people }, { data: items }, { data: movements }, { data: venues }, { data: board }] = await Promise.all([
    db.rpc("controls_desk"),
    db.from("control_failure").select("id, control_kind, control_id, reason, created_at"),
    db.from("control_failure_resolution").select("failure_id"),
    db.from("isolation_lock").select("id, isolation_id, person_id, lock_ref, on_at").is("off_at", null),
    db.from("impairment").select("id, rule_version_id"),
    db.from("system_control_rule").select("id, system_type_id, kind, content, effective_from, change_reason").order("effective_from", { ascending: false }),
    db.from("system_type").select("id, label, venue_id").is("retired_at", null).order("label"),
    db.from("person").select("id, given_name, family_name").order("family_name"),
    db.from("custody_item").select("id, venue_id, kind, label, reference, retired_at").is("retired_at", null).order("reference"),
    db.from("custody_movement").select("id, item_id, permit_id, holder_person_id, issued_at").is("returned_at", null),
    db.from("venue").select("id, name, timezone"),
    db.rpc("live_board"),
  ]);
  const d = (desk ?? { isolations: [], impairments: [] }) as Desk;
  const k = () => randomUUID();
  const name = new Map((people ?? []).map((x) => [x.id, `${x.given_name} ${x.family_name}`]));
  const openFailure = (kind: string, id: string) => (failures ?? []).find((f) => f.control_kind === kind && f.control_id === id
    && !(resolutions ?? []).some((r) => r.failure_id === f.id));
  const ruleFor = (id: string | null) => (rules ?? []).find((r) => r.id === id);
  const latestRule = (typeId: string, kind: string) => (rules ?? []).find((r) => r.system_type_id === typeId && r.kind === kind);
  const livePermits = ((board as { permits?: PermitSummary[] } | null)?.permits ?? []).filter((x) => ["approved_for_issue", "issued_awaiting_acceptance", "active", "suspended"].includes(x.status));
  const personSelect = (field: string, label: string, required = true) => (
    <label>{label}
      <select name={field} required={required} defaultValue=""><option value="">— Choose —</option>
        {(people ?? []).map((x) => <option key={x.id} value={x.id}>{x.given_name} {x.family_name}</option>)}</select>
    </label>
  );
  const hidden = (n: string, v: string | number) => <input type="hidden" name={n} value={v} />;
  const isAdmin = session.tenantAdminCustomerIds.length > 0;

  return (
    <>
      <h1>Controls desk</h1>
      <p className="muted">Isolations and impairments at your venues, with what each is waiting for. An approved permit is not an applied isolation:
        each step here is its own decision by the person appointed for that system.</p>

      <h2>Isolations</h2>
      {d.isolations.length === 0 ? <p>None open.</p> : d.isolations.map((i) => {
        const failure = openFailure("isolation", i.id);
        const tz = i.venue_timezone;
        return (
          <details className="panel" key={i.id} open={Boolean(failure) || i.status === "requested"}>
            <summary><strong>{i.system}</strong>: {i.points} — {CONTROL_STATE[i.status] ?? i.status}
              {failure ? <strong> · FAILED</strong> : null}{i.continuing ? " · continuing" : ""}
              <span className="muted"> · {i.jobs?.join(", ") ?? "no permit"} · asked by {i.requested_by}</span></summary>
            <p className="m-0">{failure ? `Failed: ${failure.reason}. Prove it again, then lift the failure.` : i.continuing
              ? `Continuing after the work, owned by ${i.continuing.owner}: ${i.continuing.reason}. Review ${i.continuing.review_on}${i.continuing.review_overdue ? " (overdue)" : ""}.`
              : ISO_NEXT[i.status] ?? ""} <span className="muted">Needed {venueTime(i.from, tz)} to {venueTime(i.to, tz)}.</span></p>
            {i.status === "requested" ? (
              <>
                <ActionForm action={isolationStep} what="Authorising this isolation" submitLabel="Authorise">
                  {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "authorise")}
                  <label>Boundary and method approved<input name="note" required /></label>
                </ActionForm>
                <ActionForm action={isolationStep} what="Refusing this isolation" submitLabel="Refuse" secondary>
                  {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "refuse")}
                  <label>Why<input name="note" required /></label>
                </ActionForm>
              </>
            ) : null}
            {i.status === "authorised" ? (
              <ActionForm action={isolationStep} what="Applying this isolation" submitLabel="Applied">
                {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "apply")}
                <label>Isolation certificate<input name="certificate_ref" required /></label>
                <label>Locks applied, one per line<textarea name="lock_refs" required rows={2} /></label>
                <label>Lock box (optional)<input name="lock_box_ref" /></label>
              </ActionForm>
            ) : null}
            {i.status === "applied" ? (
              <ActionForm action={isolationStep} what="Proving this isolation" submitLabel="Proved">
                {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "prove")}
                <label>Test instrument<input name="instrument_ref" required /></label>
                <label>Method<input name="method" required placeholder="e.g. Prove, test, prove" /></label>
                <label className="inline"><input type="checkbox" name="confirmed" /> The test confirmed it dead or at zero energy</label>
              </ActionForm>
            ) : null}
            {failure && i.status === "proved" ? (
              <ActionForm action={liftControlFailure} what="Lifting this failure" submitLabel="Lift the failure">
                {hidden("key", k())}{hidden("failure_id", failure.id)}
                <label>How it was restored<input name="reason" required /></label>
                <label>Conditions for restarting, one per line (optional)<textarea name="conditions" rows={2} /></label>
              </ActionForm>
            ) : null}
            {["applied", "proved"].includes(i.status) ? (
              <>
                {(locks ?? []).filter((l) => l.isolation_id === i.id).map((l) => (
                  <details key={l.id}><summary>{name.get(l.person_id) ?? "Someone"}&apos;s lock {l.lock_ref} is on: remove for an absent holder</summary>
                    <ActionForm action={lockOffOnBehalf} what="Removing this lock" submitLabel="Remove the lock" secondary>
                      {hidden("key", k())}{hidden("lock_id", l.id)}
                      <label>Why the holder cannot remove it<input name="reason" required /></label>
                      <label className="inline"><input type="checkbox" name="confirmed" /> I have confirmed they are not in the isolated area</label>
                    </ActionForm>
                  </details>
                ))}
                <details><summary>Remove the isolation</summary>
                  <ActionForm action={isolationStep} what="Removing this isolation" submitLabel="Removed" secondary>
                    {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "remove")}
                    <label>Locks removed and keys returned<input name="note" required /></label>
                  </ActionForm>
                </details>
                {!i.continuing ? (
                  <details><summary>Keep it after the work: take ownership (Q147)</summary>
                    <ActionForm action={transferControl} what="Taking ownership" submitLabel="Take ownership">
                      {hidden("key", k())}{hidden("id", i.id)}{hidden("kind", "isolation")}
                      <label>Why it must stay<input name="reason" required /></label>
                      <label>Review on<input name="review_on" type="date" required /></label>
                    </ActionForm>
                  </details>
                ) : null}
                {!failure ? (
                  <details><summary>Report it has failed</summary>
                    <ActionForm action={reportFailureAsAuthority} what="Reporting a failure" submitLabel="Report failure and stop the work">
                      {hidden("key", k())}{hidden("id", i.id)}{hidden("kind", "isolation")}
                      <label>What has failed<input name="reason" required /></label>
                    </ActionForm>
                  </details>
                ) : null}
              </>
            ) : null}
            {i.status === "removed" ? (
              <ActionForm action={isolationStep} what="Returning to service" submitLabel="Returned to service">
                {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "return")}
                <label>Evidence it is safe to return (Q148)<input name="evidence" required /></label>
                {personSelect("witness", "Witness (where the rules require one)", false)}
              </ActionForm>
            ) : null}
            {["requested", "authorised"].includes(i.status) ? (
              <details><summary>Withdraw the request</summary>
                <ActionForm action={isolationStep} what="Withdrawing" submitLabel="Withdraw" secondary>
                  {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "withdraw")}
                  <label>Why it is no longer needed<input name="note" required /></label>
                </ActionForm>
              </details>
            ) : null}
          </details>
        );
      })}

      <h2>Impairments</h2>
      {d.impairments.length === 0 ? <p>None open.</p> : d.impairments.map((i) => {
        const failure = openFailure("impairment", i.id);
        const rule = ruleFor((impairmentRows ?? []).find((r) => r.id === i.id)?.rule_version_id ?? null)?.content as
          { compensatory_measures?: string[]; notifications?: string[] } | undefined;
        const tz = i.venue_timezone;
        return (
          <details className="panel" key={i.id} open={i.overdue || Boolean(failure) || i.status === "requested"}>
            <summary><strong>{i.system}</strong>: {i.zones} — {CONTROL_STATE[i.status] ?? i.status}
              {i.overdue ? <strong> · OVERDUE</strong> : null}{failure ? <strong> · MEASURE FAILED</strong> : null}{i.continuing ? " · continuing" : ""}
              <span className="muted"> · {i.jobs?.join(", ") ?? "no permit"} · asked by {i.requested_by}</span></summary>
            <p className="m-0">{IMP_NEXT[i.status] ?? ""}{i.impaired_at ? ` since ${venueTime(i.impaired_at, tz)}, maximum ${i.max_hours} hours` : ""}
              {i.overdue ? ". Past its approved maximum: nothing is restored or approved by time passing; authorise it to continue or restore it." : ""}</p>
            {i.status === "requested" ? (
              <>
                <ActionForm action={impairmentStep} what="Authorising this impairment" submitLabel="Authorise">
                  {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "authorise")}
                  <label>Reason<input name="note" required /></label>
                </ActionForm>
                <ActionForm action={impairmentStep} what="Refusing this impairment" submitLabel="Refuse" secondary>
                  {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "refuse")}
                  <label>Why<input name="note" required /></label>
                </ActionForm>
              </>
            ) : null}
            {i.status === "authorised" ? (
              <ActionForm action={impairmentStep} what="Impairing the system" submitLabel="Impair the system">
                {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "impair")}
                {(rule?.compensatory_measures ?? []).map((m) => (
                  <div key={m}>{hidden("measure", m)}{personSelect("measure_person", `In place: ${m} — who is responsible`)}</div>
                ))}
                {(rule?.notifications ?? []).map((n) => (
                  <fieldset key={n} className="stack"><legend>Told: {n}</legend>{hidden("notification", n)}
                    <label>Who was told<input name="told" required /></label><label>How<input name="how" required /></label></fieldset>
                ))}
              </ActionForm>
            ) : null}
            {i.status === "impaired" ? (
              <>
                <ActionForm action={impairmentStep} what="Recording the reinstatement test" submitLabel="Record test">
                  {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "test")}
                  <label>Result<select name="passed" required defaultValue=""><option value="">— Choose —</option><option value="yes">Passed</option><option value="no">Failed</option></select></label>
                  {personSelect("witness", "Witness (not you, Q140)")}
                  <label>What was tested<input name="note" required /></label>
                </ActionForm>
                <details open={i.overdue}><summary>Authorise it to continue (Q139)</summary>
                  <ActionForm action={impairmentStep} what="Authorising it to continue" submitLabel="Authorise to continue">
                    {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "reauthorise")}
                    <label>New maximum (hours from impairment)<input name="max_hours" type="number" min={0} step="any" required /></label>
                    <label>Why it must continue<input name="note" required /></label>
                  </ActionForm>
                </details>
                {failure ? (
                  <ActionForm action={liftControlFailure} what="Lifting this failure" submitLabel="Measure restored: lift the failure">
                    {hidden("key", k())}{hidden("failure_id", failure.id)}
                    <label>How it was restored<input name="reason" required /></label>
                    <label>Conditions for restarting, one per line (optional)<textarea name="conditions" rows={2} /></label>
                  </ActionForm>
                ) : (
                  <details><summary>Report a compensatory measure has failed</summary>
                    <ActionForm action={reportFailureAsAuthority} what="Reporting a failure" submitLabel="Report failure and stop the work">
                      {hidden("key", k())}{hidden("id", i.id)}{hidden("kind", "impairment")}
                      <label>What has failed<input name="reason" required /></label>
                    </ActionForm>
                  </details>
                )}
              </>
            ) : null}
            {["impaired", "tested"].includes(i.status) && !i.continuing ? (
              <details><summary>Cannot be restored yet: take ownership (Q141)</summary>
                <ActionForm action={transferControl} what="Taking ownership" submitLabel="Take ownership">
                  {hidden("key", k())}{hidden("id", i.id)}{hidden("kind", "impairment")}
                  <label>Why it continues<input name="reason" required /></label>
                  <label>Review on<input name="review_on" type="date" required /></label>
                </ActionForm>
              </details>
            ) : null}
            {i.status === "tested" ? (
              <ActionForm action={impairmentStep} what="Confirming back in service" submitLabel="Back in service">
                {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "restore")}
                <label>How it was confirmed<input name="note" required /></label>
              </ActionForm>
            ) : null}
            {["requested", "authorised"].includes(i.status) ? (
              <details><summary>Withdraw the request</summary>
                <ActionForm action={impairmentStep} what="Withdrawing" submitLabel="Withdraw" secondary>
                  {hidden("key", k())}{hidden("id", i.id)}{hidden("row_version", i.row_version)}{hidden("step", "withdraw")}
                  <label>Why it is no longer needed<input name="note" required /></label>
                </ActionForm>
              </details>
            ) : null}
          </details>
        );
      })}

      <h2>Keys, passes and certificates (Q118)</h2>
      {(movements ?? []).length === 0 ? <p>Nothing is out.</p> : (
        <ul>{(movements ?? []).map((m) => {
          const item = (items ?? []).find((x) => x.id === m.item_id);
          return (
            <li key={m.id}>{item?.label ?? "An item"} ({item?.reference}) — held by {name.get(m.holder_person_id) ?? "someone"} since {venueTime(m.issued_at, (venues ?? []).find((v) => v.id === item?.venue_id)?.timezone ?? "UTC")}
              <ActionForm action={returnCustody} what="Recording the return" submitLabel="Returned" secondary>{hidden("key", k())}{hidden("movement_id", m.id)}</ActionForm>
            </li>
          );
        })}</ul>
      )}
      {(items ?? []).length > 0 && livePermits.length > 0 ? (
        <details><summary>Issue an item against a permit</summary>
          <ActionForm action={issueCustody} what="Issuing this item" submitLabel="Issue">
            {hidden("key", k())}
            <label>Item<select name="item_id" required defaultValue=""><option value="">— Choose —</option>
              {(items ?? []).filter((x) => !(movements ?? []).some((m) => m.item_id === x.id)).map((x) => <option key={x.id} value={x.id}>{x.label} ({x.reference})</option>)}</select></label>
            <label>Permit<select name="permit_id" required defaultValue=""><option value="">— Choose —</option>
              {livePermits.map((x) => <option key={x.id} value={x.id}>{x.job_reference} {x.class_name} ({x.organisation})</option>)}</select></label>
            {personSelect("holder", "Holder")}
          </ActionForm>
        </details>
      ) : null}
      {isAdmin ? (
        <details><summary>Add to the custody register</summary>
          <ActionForm action={registerCustodyItem} what="Adding to the register" submitLabel="Add">
            {hidden("key", k())}
            <label>Venue<select name="venue_id" required>{(venues ?? []).map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label>
            <label>Kind<select name="kind" required defaultValue="key"><option value="key">Key</option><option value="pass">Pass</option>
              <option value="hatch_key">Hatch key</option><option value="lock_box_key">Lock box key</option><option value="certificate">Certificate</option><option value="other">Other</option></select></label>
            <label>Label<input name="label" required placeholder="e.g. Roof hatch 2 key" /></label>
            <label>Reference (unique at the venue)<input name="reference" required /></label>
          </ActionForm>
        </details>
      ) : null}

      <h2>Rules per system type (P6-9)</h2>
      <p className="muted">Published by the venue&apos;s technical authority. Without rules, nothing on a system of that type can be authorised. None has a default.</p>
      {(types ?? []).length === 0 ? <p>The venue has no system types.</p> : (
        <div className="table-wrap"><table>
          <thead><tr><th scope="col">System type</th><th scope="col">Isolation</th><th scope="col">Impairment</th></tr></thead>
          <tbody>{(types ?? []).map((t) => {
            const iso = latestRule(t.id, "isolation")?.content as { prove_by?: string; return_witness?: string } | undefined;
            const imp = latestRule(t.id, "impairment")?.content as { max_duration_hours?: number; compensatory_measures?: string[]; notifications?: string[] } | undefined;
            return (
              <tr key={t.id}><td>{t.label}</td>
                <td>{iso ? `${iso.prove_by === "different_person" ? "a different person proves it" : "the applier may prove it"}; return ${iso.return_witness === "required" ? "witnessed" : "not witnessed"}` : "Not published"}</td>
                <td>{imp ? `up to ${imp.max_duration_hours} h; ${imp.compensatory_measures?.length ?? 0} measure(s); tell ${imp.notifications?.length ? imp.notifications.join(", ") : "nobody"}` : "Not published"}</td></tr>
            );
          })}</tbody>
        </table></div>
      )}
      {(types ?? []).length > 0 ? (
        <details><summary>Publish rules</summary>
          <ActionForm action={publishControlRule} what="Publishing rules" submitLabel="Publish">
            {hidden("key", k())}
            <label>System type<select name="system_type_id" required defaultValue=""><option value="">— Choose —</option>
              {(types ?? []).map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}</select></label>
            <label>Rules for<select name="kind" required defaultValue="isolation"><option value="isolation">Isolation</option><option value="impairment">Impairment</option></select></label>
            <fieldset className="stack"><legend>Isolation</legend>
              <label>Who proves it<select name="prove_by" defaultValue=""><option value="">— Choose —</option><option value="different_person">A different person from the one who applied it</option><option value="same_person_allowed">The person who applied it may prove it</option></select></label>
              <label>Return to service<select name="return_witness" defaultValue=""><option value="">— Choose —</option><option value="required">Needs a witness</option><option value="not_required">No witness needed</option></select></label>
            </fieldset>
            <fieldset className="stack"><legend>Impairment</legend>
              <label>Maximum hours before a fresh authorisation (Q139)<input name="max_hours" type="number" min={0} step="any" /></label>
              <label>Compensatory measures, one per line (Q138)<textarea name="measures" rows={2} /></label>
              <label>Who must be told first, one per line (Q137)<textarea name="notifications" rows={2} /></label>
            </fieldset>
            <label>Source<input name="reason" required placeholder="e.g. Electrical safety rules rev. 4" /></label>
          </ActionForm>
        </details>
      ) : null}
    </>
  );
}
