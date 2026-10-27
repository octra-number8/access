import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { type EntryResult, OUTCOME_WORDS, OVERRIDABLE_WORDS } from "@/lib/gate";
import { toVenueLocal, venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { overrideEntry } from "../actions";

export const metadata = { title: "Gate overrides" };

// Refusals waiting at the venue's gates (Q195, P7-6): today's results that were not let
// through, with the reasons an access authority may set aside. Who may override, and for
// which reasons, is decided by the database when they try.
export default async function Overrides({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/gate/overrides");
  const db = await supabaseServer();
  const { data: venues } = await db.from("venue").select("id, name, timezone").order("name");
  const { venue: vid } = await searchParams;
  const venue = (venues ?? []).find((v) => v.id === vid) ?? (venues ?? [])[0];
  if (!venue) return <p>No venue.</p>;
  const since = new Date(Date.now() - 12 * 3_600_000).toISOString();
  const [{ data: evals }, { data: points }, { data: overrides }] = await Promise.all([
    db.from("entry_eligibility_evaluation").select("id, gate_point_id, person_id, outcome, result, evaluated_at")
      .eq("venue_id", venue.id).in("outcome", ["check", "do_not_admit"]).gte("evaluated_at", since).order("evaluated_at", { ascending: false }),
    db.from("gate_point").select("id, name, area_id").eq("venue_id", venue.id),
    db.from("entry_override").select("id, person_id, reason_codes, purpose, reason, escort, valid_during, area_id, granted_by_person_id")
      .eq("venue_id", venue.id).order("created_at", { ascending: false }).limit(50),
  ]);
  const [{ data: scans }, { data: people }] = await Promise.all([
    db.from("scan_event").select("evaluation_id, action").in("evaluation_id", (evals ?? []).map((e) => e.id)),
    db.from("person").select("id, given_name, family_name").in("id", [...new Set([...(overrides ?? []).map((o) => o.person_id), ...(overrides ?? []).map((o) => o.granted_by_person_id)])]),
  ]);
  const personName = new Map((people ?? []).map((p) => [p.id, `${p.given_name} ${p.family_name}`]));
  const pointName = new Map((points ?? []).map((p) => [p.id, p.name]));
  const done = new Map((scans ?? []).map((s) => [s.evaluation_id, s.action as string]));
  // The latest result per person and gate, still not let through.
  const seen = new Set<string>();
  const waiting = (evals ?? []).filter((e) => {
    const k = `${e.person_id}:${e.gate_point_id}`;
    if (!e.person_id || seen.has(k)) return false;
    seen.add(k);
    return done.get(e.id) !== "admitted" && done.get(e.id) !== "refused";
  });
  const upper = (range: string) => range.replace(/^[[(]"?[^,]*"?,"?([^")\]]*)"?[\])]$/, "$1");
  const inForce = (overrides ?? []).filter((o) => new Date(upper(o.valid_during)).getTime() > Date.now());
  const endOfDay = toVenueLocal(new Date().toISOString(), venue.timezone).slice(0, 10) + "T23:59";
  const k = () => randomUUID();

  return (
    <>
      <p>{(venues ?? []).length > 1 ? (venues ?? []).map((v) => <Link key={v.id} href={`/gate/overrides?venue=${v.id}`} style={{ marginRight: "1rem" }}>{v.name}</Link>) : null}
        <Link href="/gate">Back to the gate</Link></p>
      <h1>Gate overrides — {venue.name}</h1>
      <p className="muted">An override sets aside named reasons for one person, in one gate&apos;s area, until a stated time. A restriction, a revoked or unknown pass, an inactive record, and any reason the venue has made never-overridable cannot be set aside here. An override is permission to be here, never permission to work.</p>

      <h2>Waiting at the gates (last 12 hours)</h2>
      {waiting.length === 0 ? <p>Nobody is waiting.</p> : waiting.map((e) => {
        const r = e.result as EntryResult;
        const settable = r.reasons.filter((x) => x.overridable && !x.overridden_by);
        const fixed = r.reasons.filter((x) => !x.overridable && !x.overridden_by);
        return (
          <div className="panel" key={e.id}>
            <p><strong>{r.person?.name ?? "Unknown"}</strong>{r.organisation ? ` · ${r.organisation}` : ""} at {pointName.get(e.gate_point_id) ?? "a gate"},{" "}
              {venueTime(e.evaluated_at, venue.timezone)}: <strong>{OUTCOME_WORDS[e.outcome as keyof typeof OUTCOME_WORDS]}</strong>
              {done.get(e.id) === "referred" ? <span className="tag">Referred by the operator</span> : null}</p>
            <ul>{r.reasons.filter((x) => !x.overridden_by).map((x) => <li key={x.code + x.words}>{x.words} <span className="muted">({x.owner})</span></li>)}</ul>
            {fixed.length ? <p className="muted">Cannot be set aside here: {fixed.map((x) => x.words).join(" ")}</p> : null}
            {settable.length && r.person ? (
              <details><summary>Set aside a reason</summary>
                <ActionForm action={overrideEntry} what="Recording this override" submitLabel="Record override">
                  <input type="hidden" name="key" value={k()} />
                  <input type="hidden" name="person_id" value={r.person.id} />
                  <input type="hidden" name="gate_point_id" value={e.gate_point_id} />
                  <input type="hidden" name="tz" value={venue.timezone} />
                  <fieldset className="stack"><legend>Reasons this covers</legend>
                    {settable.map((x) => <label className="inline" key={x.code}><input type="checkbox" name="reason_codes" value={x.code} /> {OVERRIDABLE_WORDS[x.code] ?? x.words}</label>)}
                  </fieldset>
                  <label>Purpose of the visit<input name="purpose" required placeholder="e.g. Collecting tools left on stand 12" /></label>
                  <label>Why entry is justified despite the reasons<textarea name="reason" required rows={2} /></label>
                  <label>Ends ({venue.timezone}; never open-ended)<input name="until" type="datetime-local" required defaultValue={endOfDay} /></label>
                  <label>Escort (optional)<input name="escort" placeholder="Name or role" /></label>
                  <p className="muted">You cannot override for yourself or anyone from your own organisations.</p>
                </ActionForm>
              </details>
            ) : null}
          </div>
        );
      })}

      <h2>Overrides in force</h2>
      {inForce.length === 0 ? <p>None.</p> : (
        <ul>{inForce.map((o) => (
          <li key={o.id}><strong>{personName.get(o.person_id) ?? "A person"}</strong>: {(o.reason_codes as string[]).map((c) => OVERRIDABLE_WORDS[c] ?? c).join(", ")} set aside until {venueTime(upper(o.valid_during), venue.timezone)}
            {" "}in {pointName.get((points ?? []).find((p) => p.area_id === o.area_id)?.id ?? "") ?? "a gate's area"}: {o.purpose}{o.escort ? `; escort ${o.escort}` : ""}.
            <span className="muted"> {o.reason} (by {personName.get(o.granted_by_person_id) ?? "an access authority"})</span></li>
        ))}</ul>
      )}
    </>
  );
}
