import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { date } from "@/lib/labels";
import { venueTime } from "@/lib/permits";
import { HOLD_STATE } from "@/lib/retention";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { decideHold, liftHold, renewHold, requestHold } from "./actions";

export const metadata = { title: "Legal holds" };

interface Option { id: string; name: string }
interface Hold {
  id: string; reference: string; matter: string; reason: string; scope: string; status: string; review_on: string; review_due: boolean;
  requested_by: string; requested_at: string; mine: boolean; decided_by: string | null; decided_at: string | null; decision_reason: string | null;
  lifted_by: string | null; lifted_at: string | null; lift_reason: string | null; row_version: number; kept: number;
  renewals: Array<{ review_on: string; reason: string; by: string; at: string }>;
}
interface Holds {
  ok: true; venue: { id: string; name: string; timezone: string }; today: string; can_request: boolean; can_decide: boolean; holds: Hold[];
  options: { organisations: Option[]; people: Option[]; jobs: Option[]; visits: Option[] };
}

function Pick({ name, label, options }: { name: string; label: string; options: Option[] }) {
  return (
    <label>{label}<select name={name} defaultValue=""><option value="">Any</option>{options.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
  );
}

// Q223, §16.4: holds stop disposal of what they cover until they are lifted. Visible to the venue's
// administrators and the holders of the hold and retention actions; never to contractors.
export default async function LegalHolds({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/holds");
  const db = await supabaseServer();
  const { data: scopes } = await db.rpc("report_scopes");
  const venues = ((scopes as { venues?: Array<{ id: string; name: string }> } | null)?.venues ?? []);
  const { venue: chosen } = await searchParams;
  const venueId = venues.some((v) => v.id === chosen) ? chosen! : venues[0]?.id;
  const { data } = venueId ? await db.rpc("legal_holds", { p_venue_id: venueId }) : { data: null };
  if (!data?.ok) {
    return <><h1>Legal holds</h1><p>This page is for a venue&apos;s administrators and the people it has appointed to request or approve legal holds.</p></>;
  }
  const h = data as Holds;
  const tz = h.venue.timezone;
  const k = () => randomUUID();

  return (
    <>
      <p><Link href="/venue/retention">Retention and disposal</Link></p>
      <h1>Legal holds — {h.venue.name}</h1>
      <div className="notice">
        <p className="m-0">While a hold is in force, nothing it covers is listed for disposal or disposed of (Q223). A hold is asked for by one person and approved by another. It stays in force until it is lifted with a reason: reaching its review date tells the people concerned, and changes nothing else.</p>
      </div>

      <h2>Holds</h2>
      {h.holds.length === 0 ? <p>None.</p> : h.holds.map((x) => (
        <div className="panel" key={x.id} style={{ maxWidth: "none" }}>
          <h3 style={{ marginTop: 0 }}>{x.reference}: {x.matter}</h3>
          <p><strong>{HOLD_STATE[x.status] ?? x.status}</strong>{x.status === "active" && x.review_due ? " — its review date has been reached; it stays in force until renewed or lifted" : null}</p>
          <dl className="facts">
            <dt>Covers</dt><dd>{x.scope}</dd>
            <dt>Reason</dt><dd>{x.reason}</dd>
            <dt>Asked for</dt><dd>by {x.requested_by}, {venueTime(x.requested_at, tz)}</dd>
            {x.decided_by ? <><dt>{x.status === "refused" ? "Refused" : "Approved"}</dt><dd>by {x.decided_by}, {x.decided_at ? venueTime(x.decided_at, tz) : ""}: {x.decision_reason}</dd></> : null}
            <dt>Review date</dt><dd>{date(x.review_on)}</dd>
            {x.renewals.map((r, i) => <div key={i} style={{ display: "contents" }}><dt>Renewed</dt><dd>by {r.by}, {venueTime(r.at, tz)}, to {date(r.review_on)}: {r.reason}</dd></div>)}
            {x.lifted_by ? <><dt>Lifted</dt><dd>by {x.lifted_by}, {x.lifted_at ? venueTime(x.lifted_at, tz) : ""}: {x.lift_reason}</dd></> : null}
            {x.kept > 0 ? <><dt>Kept back</dt><dd>from {x.kept} disposal {x.kept === 1 ? "batch" : "batches"}</dd></> : null}
          </dl>
          {h.can_decide && x.status === "requested" && !x.mine ? (
            <>
              <ActionForm action={decideHold} what="Approving this hold" submitLabel="Approve the hold">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="hold_id" value={x.id} />
                <input type="hidden" name="row_version" value={x.row_version} />
                <input type="hidden" name="decision" value="approve" />
                <label>Reason<input name="reason" required maxLength={2000} /></label>
              </ActionForm>
              <ActionForm action={decideHold} what="Refusing this hold" submitLabel="Refuse" secondary>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="hold_id" value={x.id} />
                <input type="hidden" name="row_version" value={x.row_version} />
                <input type="hidden" name="decision" value="refuse" />
                <label>Reason<input name="reason" required maxLength={2000} /></label>
              </ActionForm>
            </>
          ) : x.status === "requested" ? <p className="muted">Waiting for a hold approver who did not ask for it.</p> : null}
          {h.can_decide && x.status === "active" ? (
            <details><summary>Renew or lift</summary>
              <ActionForm action={renewHold} what="Renewing this hold" submitLabel="Renew">
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="hold_id" value={x.id} />
                <label>New review date<input type="date" name="review_on" required min={h.today} /></label>
                <label>Reason<input name="reason" required maxLength={2000} /></label>
              </ActionForm>
              <ActionForm action={liftHold} what="Lifting this hold" submitLabel="Lift the hold" secondary>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="hold_id" value={x.id} />
                <input type="hidden" name="row_version" value={x.row_version} />
                <label>Reason<input name="reason" required maxLength={2000} /></label>
                <p className="muted text-sm">Records it kept become eligible for disposal again under the schedule; they are disposed of only once listed and confirmed.</p>
              </ActionForm>
            </details>
          ) : null}
        </div>
      ))}

      {h.can_request ? (
        <details className="panel"><summary>Ask for a hold</summary>
          <ActionForm action={requestHold} what="Asking for this hold" submitLabel="Ask for the hold">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="venue_id" value={h.venue.id} />
            <input type="hidden" name="tz" value={tz} />
            <label>Matter<input name="matter" required maxLength={200} placeholder="For example: Claim 2027-014" /></label>
            <label>Reason<textarea name="reason" required maxLength={2000} rows={2} /></label>
            <label>Review date<input type="date" name="review_on" required min={h.today} /></label>
            <fieldset className="stack">
              <legend>What it covers (all that you choose must match; choose nothing to cover everything at the venue)</legend>
              <Pick name="organisation_id" label="Organisation" options={h.options.organisations} />
              <Pick name="person_id" label="Person" options={h.options.people} />
              <Pick name="work_package_id" label="Job" options={h.options.jobs} />
              <Pick name="visit_id" label="Visit" options={h.options.visits} />
              <label>Activity from (venue time)<input type="datetime-local" name="from" /></label>
              <label>Activity until (venue time)<input type="datetime-local" name="to" /></label>
            </fieldset>
          </ActionForm>
        </details>
      ) : null}
    </>
  );
}
