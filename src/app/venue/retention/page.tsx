import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { venueTime } from "@/lib/permits";
import type { DisposalBatch, RetentionCategory } from "@/lib/retention";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { decideBatch, decideRetention, proposeRetention, saveRetention, startRetentionDraft } from "./actions";

export const metadata = { title: "Retention and disposal" };

interface Overview {
  ok: true; venue: { id: string; name: string; timezone: string }; is_admin: boolean; can_approve: boolean; can_dispose: boolean; me: string | null;
  categories: RetentionCategory[];
  schedule: { id: string; version_no: number; decided_by: string; decided_at: string; decision_reason: string; source_ref: string | null } | null;
  draft: { id: string; status: "draft" | "proposed"; version_no: number; content: { rules: Record<string, { days: number; basis: string }> };
           row_version: number; authored_by: string; authored_by_person_id: string; proposed_by_person_id: string | null } | null;
  batches: DisposalBatch[]; files_waiting: number;
}

const days = (n: number) => (n === 1 ? "1 day" : `${n} days`);

function ScheduleTable({ categories, rules }: { categories: RetentionCategory[]; rules: Record<string, { days: number; basis: string }> | null }) {
  return (
    <div className="table-wrap"><table className="stacked">
      <thead><tr><th scope="col">Records</th><th scope="col">Kept for</th><th scope="col">Counted from</th><th scope="col">Disposal</th><th scope="col">Never disposed of while</th></tr></thead>
      <tbody>{categories.map((c) => {
        const r = rules?.[c.code];
        return (
          <tr key={c.code}>
            <td data-label="Records"><strong>{c.name}</strong></td>
            <td data-label="Kept for">{r ? <>{days(r.days)}<div className="muted text-sm">Based on: {r.basis}</div></> : <span>No rule: kept</span>}</td>
            <td data-label="Counted from">{c.trigger}</td>
            <td data-label="Disposal">{c.method}</td>
            <td data-label="Never while">{c.never_while}</td>
          </tr>
        );
      })}</tbody>
    </table></div>
  );
}

// Q221–Q224, §16: the schedule (no default), the batches the job lists, and their confirmation.
// Who may draft, approve and confirm is settled by the database.
export default async function Retention({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/retention");
  const db = await supabaseServer();
  const { data: scopes } = await db.rpc("report_scopes");
  const venues = ((scopes as { venues?: Array<{ id: string; name: string }> } | null)?.venues ?? []);
  const { venue: chosen } = await searchParams;
  const venueId = venues.some((v) => v.id === chosen) ? chosen! : venues[0]?.id;
  const { data } = venueId ? await db.rpc("retention_overview", { p_venue_id: venueId }) : { data: null };
  if (!data?.ok) {
    return <><h1>Retention and disposal</h1><p>This page is for a venue&apos;s administrators and the people it has appointed to approve its retention schedule, confirm disposal or manage legal holds.</p></>;
  }
  const o = data as Overview;
  const tz = o.venue.timezone;
  const k = () => randomUUID();
  const proposed = o.batches.filter((b) => b.status === "proposed");
  const decided = o.batches.filter((b) => b.status !== "proposed");
  const kept = o.categories.filter((c) => c.rule && c.kept_back);
  const draft = o.draft;
  const draftRules = draft?.content.rules ?? {};

  return (
    <>
      <p><Link href="/venue">Venue administration</Link> · <Link href="/venue/holds">Legal holds</Link></p>
      <h1>Retention and disposal — {o.venue.name}</h1>
      <div className="notice">
        <p>Records are kept for as long as the venue&apos;s approved schedule says (Q221–Q224). There is no default: a category with no rule is kept. Octra lists records past their period that no legal hold covers; nothing is disposed of until someone appointed to do so confirms the batch, and every record is checked again then.</p>
        <p className="m-0">Disposal deletes the records (or, for files, removes the file and keeps its record). The audit log keeps who decided what and when, with reasons, but no record&apos;s contents. Disposal cannot be undone.</p>
      </div>
      {venues.length > 1 ? (
        <form className="no-print"><label>Venue <select name="venue" defaultValue={o.venue.id}>{venues.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label> <button type="submit" className="secondary">Show</button></form>
      ) : null}

      <h2>Schedule in force</h2>
      {o.schedule ? (
        <p className="muted">Version {o.schedule.version_no}, approved by {o.schedule.decided_by} on {venueTime(o.schedule.decided_at, tz)}: {o.schedule.decision_reason}
          {o.schedule.source_ref ? <> · Source: {o.schedule.source_ref}</> : null}</p>
      ) : <p className="notice notice-blocked">No schedule is approved, so nothing is listed for disposal and every record is kept.</p>}
      <ScheduleTable categories={o.categories} rules={o.schedule ? Object.fromEntries(o.categories.filter((c) => c.rule).map((c) => [c.code, c.rule!])) : null} />

      {draft?.status === "draft" && o.is_admin ? (
        <div className="panel stack" style={{ maxWidth: "none" }}>
          <h2 style={{ marginTop: 0 }}>Draft version {draft.version_no}</h2>
          <p className="muted text-sm">Set a period only where the venue has decided one, with its privacy adviser. Each period needs what it is based on. Octra suggests none.</p>
          <ActionForm key={draft.id} action={saveRetention} what="Saving the schedule" submitLabel="Save">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={draft.id} />
            {o.categories.map((c) => {
              const r = draftRules[c.code];
              return (
                <fieldset className="stack" key={c.code}><legend>{c.name}</legend>
                  <p className="muted text-sm m-0">Counted from: {c.trigger}. {c.method}.</p>
                  <label className="inline"><input type="checkbox" name={`${c.code}.on`} defaultChecked={!!r} /> Set a period for these</label>
                  <label>Keep for (days)<input name={`${c.code}.days`} inputMode="numeric" defaultValue={r?.days ?? ""} /></label>
                  <label>Based on<input name={`${c.code}.basis`} maxLength={500} defaultValue={r?.basis ?? ""} placeholder="The advice, policy or decision relied on" /></label>
                </fieldset>
              );
            })}
            <label>Source document (optional)<input name="source_ref" maxLength={300} placeholder="For example: Retention policy v3, March 2027" /></label>
          </ActionForm>
          <ActionForm action={proposeRetention} what="Proposing the schedule" submitLabel="Propose for approval">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={draft.id} />
            <input type="hidden" name="row_version" value={draft.row_version} />
          </ActionForm>
        </div>
      ) : draft?.status === "draft" ? (
        <p className="muted">Version {draft.version_no} is being drafted by {draft.authored_by}.</p>
      ) : draft?.status === "proposed" ? (
        <div className="panel" style={{ maxWidth: "none" }}>
          <h2 style={{ marginTop: 0 }}>Version {draft.version_no}: proposed by {draft.authored_by}</h2>
          <ScheduleTable categories={o.categories} rules={draftRules} />
          {o.can_approve && o.me !== draft.authored_by_person_id && o.me !== draft.proposed_by_person_id ? (
            <>
              <ActionForm action={decideRetention} what="Approving the schedule" submitLabel="Approve this schedule">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="version_id" value={draft.id} />
                <input type="hidden" name="row_version" value={draft.row_version} />
                <input type="hidden" name="decision" value="approve" />
                <label>Reason<input name="reason" required maxLength={2000} placeholder="For example: Agreed with the privacy adviser, note of 3 March" /></label>
              </ActionForm>
              <ActionForm action={decideRetention} what="Rejecting the schedule" submitLabel="Reject" secondary>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="version_id" value={draft.id} />
                <input type="hidden" name="row_version" value={draft.row_version} />
                <input type="hidden" name="decision" value="reject" />
                <label>What needs to change<input name="reason" required maxLength={2000} /></label>
              </ActionForm>
            </>
          ) : <p className="muted">Waiting for approval by someone appointed to approve the retention schedule who did not write or propose it.</p>}
        </div>
      ) : o.is_admin ? (
        <ActionForm action={startRetentionDraft} what="Starting a draft" submitLabel={o.schedule ? "Start a new version from this one" : "Start the first schedule"}>
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={o.venue.id} />
        </ActionForm>
      ) : null}

      <h2>Batches to confirm</h2>
      {proposed.length === 0 ? <p>None. Records are listed by a scheduled job once their period has run out.</p> : proposed.map((b) => (
        <div className="panel" key={b.id} style={{ maxWidth: "none" }}>
          <h3 style={{ marginTop: 0 }}>{b.reference}: {b.category}</h3>
          <p>{b.listed_count} {b.listed_count === 1 ? "record" : "records"} past the {days(b.period_days)} set by schedule version {b.rule_version}, listed {venueTime(b.listed_at, tz)}. No legal hold covered them then.</p>
          {b.held_back.length ? (
            <p>Kept back by legal holds and not listed: {b.held_back.map((h) => `${h.count} by ${h.reference} (${h.matter})`).join("; ")}.</p>
          ) : null}
          <details><summary>The records listed{b.listed_count > b.items.length ? ` (first ${b.items.length})` : ""}</summary>
            <ul>{b.items.map((i, n) => <li key={n}>{i.label ?? "No longer recorded"} <span className="muted text-sm">· counted from {venueTime(i.trigger_at, tz)}</span></li>)}</ul>
          </details>
          {o.can_dispose && o.me !== b.rule_approver_person_id ? (
            <>
              <ActionForm action={decideBatch} what="Confirming this disposal" submitLabel="Confirm disposal">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="batch_id" value={b.id} />
                <input type="hidden" name="row_version" value={b.row_version} />
                <input type="hidden" name="decision" value="confirm" />
                <label>Reason<input name="reason" required maxLength={2000} placeholder="For example: Reviewed the list; nothing needed for an open matter" /></label>
                <p className="muted text-sm">Each record is checked again now: anything that is no longer past its period, or that a legal hold now covers, is kept and listed with the reason. This cannot be undone.</p>
              </ActionForm>
              <ActionForm action={decideBatch} what="Declining this disposal" submitLabel="Decline" secondary>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="batch_id" value={b.id} />
                <input type="hidden" name="row_version" value={b.row_version} />
                <input type="hidden" name="decision" value="decline" />
                <label>Reason for keeping them<input name="reason" required maxLength={2000} /></label>
                <p className="muted text-sm">Declined records are kept, and not listed again under this version of the schedule.</p>
              </ActionForm>
            </>
          ) : o.can_dispose ? <p className="muted">You approved the schedule this batch follows, so someone else appointed to confirm disposal decides it.</p>
            : <p className="muted">Waiting for someone appointed to confirm disposal.</p>}
        </div>
      ))}

      <h2>Kept back by legal holds</h2>
      {kept.length === 0 ? <p>Nothing past its period is being kept by a legal hold.</p> : (
        <>
          <p className="muted">Records past their period that a legal hold covers are not listed. Checked at every run of the scheduled job; each line shows since when it has been the case.</p>
          <ul>{kept.map((c) => (
            <li key={c.code}><strong>{c.name}:</strong> {c.kept_back!.count === 1 ? "1 record" : `${c.kept_back!.count} records`}: {c.kept_back!.holds.map((h) => `${h.count} by ${h.reference} (${h.matter})`).join("; ")}
              <span className="muted text-sm"> · since {venueTime(c.kept_back!.since, tz)}</span></li>
          ))}</ul>
        </>
      )}

      {o.files_waiting > 0 ? <p className="notice">{o.files_waiting === 1 ? "1 disposed file is still to be removed from storage by the scheduled job. It is no longer released to anyone."
        : `${o.files_waiting} disposed files are still to be removed from storage by the scheduled job. They are no longer released to anyone.`}</p> : null}

      <h2>Decided batches</h2>
      {decided.length === 0 ? <p>None yet.</p> : (
        <div className="table-wrap"><table className="stacked">
          <thead><tr><th scope="col">Batch</th><th scope="col">Decision</th><th scope="col">Result</th></tr></thead>
          <tbody>{decided.map((b) => (
            <tr key={b.id}>
              <td data-label="Batch">{b.reference}: {b.category}<div className="muted text-sm">{b.listed_count} listed {venueTime(b.listed_at, tz)}, {days(b.period_days)} (schedule version {b.rule_version})</div></td>
              <td data-label="Decision">{b.status === "confirmed" ? "Confirmed" : "Declined"} by {b.decided_by} on {b.decided_at ? venueTime(b.decided_at, tz) : ""}<div className="muted text-sm">{b.decision_reason}</div></td>
              <td data-label="Result">{b.status === "confirmed" ? `${b.disposed_count} disposed of, ${b.kept_count} kept` : "All kept"}
                {b.status === "confirmed" && b.items.length ? (
                  <details><summary>Kept, and why</summary><ul>{b.items.map((i, n) => <li key={n}>{i.label ?? "No longer recorded"}: {i.kept_reason}</li>)}</ul></details>
                ) : null}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
    </>
  );
}
