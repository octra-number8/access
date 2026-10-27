import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { ACTION_WORDS, IDENTITY_WORDS } from "@/lib/gate";
import { venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { resolveException } from "../actions";

export const metadata = { title: "Reconciliation" };

// What the gate did during an outage, checked against the live record on reconnection
// (Q202, Q203). Entry exceptions belong to the access administrator; work exceptions to the
// permit's issuer. Each stays open until resolved with a note, never by time (invariant 10).
export default async function Reconcile({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/gate/reconcile");
  const db = await supabaseServer();
  const { data: venues } = await db.from("venue").select("id, name, timezone").order("name");
  const { venue: vid } = await searchParams;
  const venue = (venues ?? []).find((v) => v.id === vid) ?? (venues ?? [])[0];
  if (!venue) return <p>No venue.</p>;
  const [{ data: exceptions }, { data: points }] = await Promise.all([
    db.from("reconciliation_exception").select("*").eq("venue_id", venue.id).order("created_at", { ascending: false }).limit(200),
    db.from("gate_point").select("id, name").eq("venue_id", venue.id),
  ]);
  const [{ data: entries }, { data: permits }] = await Promise.all([
    db.from("manual_fallback_entry").select("*").in("id", [...new Set((exceptions ?? []).map((e) => e.fallback_entry_id))]),
    db.from("permit").select("id, work_package_id").in("id", (exceptions ?? []).map((e) => e.permit_id).filter(Boolean) as string[]),
  ]);
  const { data: people } = await db.from("person").select("id, given_name, family_name")
    .in("id", [...new Set([...(entries ?? []).map((f) => f.operator_person_id), ...(exceptions ?? []).map((e) => e.resolved_by_person_id).filter(Boolean)])] as string[]);
  const name = (id: string | null) => { const p = (people ?? []).find((x) => x.id === id); return p ? `${p.given_name} ${p.family_name}` : "Someone"; };
  const entry = new Map((entries ?? []).map((f) => [f.id, f]));
  const point = new Map((points ?? []).map((p) => [p.id, p.name]));
  const permitLink = new Map((permits ?? []).map((p) => [p.id, p.id]));
  const open = (exceptions ?? []).filter((e) => !e.resolved_at);
  const done = (exceptions ?? []).filter((e) => e.resolved_at).slice(0, 50);
  const tz = venue.timezone;
  const k = () => randomUUID();

  const detail = (fid: string) => {
    const f = entry.get(fid);
    if (!f) return null;
    return (
      <p className="muted">
        Manual entry at {point.get(f.gate_point_id) ?? "a gate"}, {venueTime(f.recorded_at, tz)}, by {name(f.operator_person_id)}: {f.name_given}
        {f.organisation_given ? ` (${f.organisation_given})` : ""}, {f.direction === "in" ? "coming in" : "going out"}, {ACTION_WORDS[f.decision]?.toLowerCase()};
        {" "}identity: {IDENTITY_WORDS[f.identity_method]}; contacted: {f.contacted}; purpose: {f.purpose}
        {f.notes ? `; notes: ${f.notes}` : ""}.{" "}
        {f.manifest_id ? (f.manifest_usable ? `Manifest ${f.manifest_age_minutes} min old.` : `Manifest ${f.manifest_age_minutes} min old: past its permitted age.`) : "No manifest."}
      </p>
    );
  };

  return (
    <>
      <p>{(venues ?? []).length > 1 ? (venues ?? []).map((v) => <Link key={v.id} href={`/gate/reconcile?venue=${v.id}`} style={{ marginRight: "1rem" }}>{v.name}</Link>) : null}
        <Link href="/gate">Back to the gate</Link></p>
      <h1>Reconciliation — {venue.name}</h1>
      <p className="muted">Entries made during an outage, checked against the live record when they were uploaded. Octra notifies nobody: where work is stopped, its owner must also use the venue&apos;s direct route to the supervisor and control room (Q203). Resolving records what was found and done; it does not change any permit or entry decision.</p>

      <h2>Open</h2>
      {open.length === 0 ? <p>Nothing to reconcile.</p> : open.map((e) => (
        <div className="panel" key={e.id}>
          <p><strong>{e.kind === "work" ? "Work" : "Entry"}:</strong> {e.words}</p>
          <p>Owner: {e.owner}{e.permit_id && permitLink.has(e.permit_id) ? <> · <Link href={`/permits/${e.permit_id}`}>Open the permit</Link></> : null}</p>
          {detail(e.fallback_entry_id)}
          <ActionForm action={resolveException} what="Resolving this exception" submitLabel="Resolve">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="id" value={e.id} />
            <label>What you found and did<textarea name="note" required rows={2} /></label>
            <p className="muted">Only {e.kind === "work" ? "an appointee for this permit's class and area" : "an access administrator for this gate's area"} can resolve it, never the operator who made the entry.</p>
          </ActionForm>
        </div>
      ))}

      <h2>Resolved</h2>
      {done.length === 0 ? <p>None yet.</p> : (
        <ul>{done.map((e) => (
          <li key={e.id}>{e.words} <span className="muted">— {name(e.resolved_by_person_id)}, {venueTime(e.resolved_at, tz)}: {e.resolution_note}</span></li>
        ))}</ul>
      )}
    </>
  );
}
