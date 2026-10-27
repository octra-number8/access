import { randomUUID } from "node:crypto";
import Link from "next/link";
import { ActionForm } from "@/components/ActionForm";
import { type ChaseItem, ChasingView } from "@/components/chasing-view";
import { EntryRulesView, OutageView, PurposesView } from "@/components/gate/config-view";
import { type Purpose, visitState } from "@/lib/gate";
import { venueTime } from "@/lib/permits";
import { supabaseServer } from "@/lib/supabase/server";
import { decideChasing } from "../venue/chasing/actions";
import { decideEntryRules, decideOutage, decidePurposes, type EntryRules, type OutageProcedure } from "../venue/entry/actions";

// The access authority's queue (P7-2, Q121, Q123): entry rules and visit purposes to approve,
// and visits waiting for a decision. Whether someone may decide is settled by the database.
export async function EntryDecisions() {
  const db = await supabaseServer();
  const [{ data: rules }, { data: purposes }, { data: visits }, { data: capacities }, { data: courses }, { data: areas }, { data: venues }] = await Promise.all([
    db.from("entry_rule_version").select("id, venue_id, version_no, content, row_version").eq("status", "proposed"),
    db.from("venue_config_version").select("id, venue_id, kind, version_no, content, row_version").eq("status", "proposed"),
    db.from("access_authorisation").select("id, reference, venue_id, description, starts_at, ends_at, status").eq("status", "requested").order("starts_at"),
    db.from("engagement_capacity").select("code, label"),
    db.from("induction_course").select("id, title"),
    db.from("area").select("id, name"),
    db.from("venue").select("id, name, timezone"),
  ]);
  const names = new Map<string, string>([...(capacities ?? []).map((c) => [c.code, c.label] as [string, string]),
    ...(courses ?? []).map((c) => [c.id, c.title] as [string, string]), ...(areas ?? []).map((a) => [a.id, a.name] as [string, string])]);
  const venue = new Map((venues ?? []).map((v) => [v.id, v]));
  const chaseIds = (purposes ?? []).filter((r) => r.kind === "chasing").flatMap((r) => Object.values((r.content as { items: Record<string, ChaseItem> }).items)
    .flatMap((x) => [...(x.escalate_to?.person_ids ?? []), ...(x.escalate_to?.appointment_type_ids ?? [])]));
  const [{ data: chasePeople }, { data: chaseTypes }] = await Promise.all([
    db.from("person").select("id, given_name, family_name").in("id", chaseIds),
    db.from("appointment_type").select("id, name").in("id", chaseIds),
  ]);
  const chaseNames = new Map<string, string>([...(chasePeople ?? []).map((p) => [p.id, `${p.given_name} ${p.family_name}`] as [string, string]),
    ...(chaseTypes ?? []).map((t) => [t.id, t.name] as [string, string])]);
  const k = () => randomUUID();
  const decide = (action: typeof decideEntryRules, v: { id: string; row_version: number }, what: string) => (
    <>
      <ActionForm action={action} what={`Approving ${what}`} submitLabel="Approve">
        <input type="hidden" name="key" value={k()} />
        <input type="hidden" name="version_id" value={v.id} />
        <input type="hidden" name="row_version" value={v.row_version} />
        <input type="hidden" name="decision" value="approve" />
        <label>Reason<input name="reason" required placeholder="e.g. Matches the venue's access matrix, rev. 2" /></label>
      </ActionForm>
      <ActionForm action={action} what={`Rejecting ${what}`} submitLabel="Reject" secondary>
        <input type="hidden" name="key" value={k()} />
        <input type="hidden" name="version_id" value={v.id} />
        <input type="hidden" name="row_version" value={v.row_version} />
        <input type="hidden" name="decision" value="reject" />
        <label>What needs to change<input name="reason" required /></label>
      </ActionForm>
    </>
  );

  return (
    <>
      <h2>Entry rules to approve</h2>
      {(rules ?? []).length === 0 ? <p>None.</p> : (rules ?? []).map((r) => (
        <div className="panel" key={r.id}>
          <p><strong>{venue.get(r.venue_id)?.name}</strong> — entry rules version {r.version_no}</p>
          <EntryRulesView content={r.content as EntryRules} names={names} />
          {decide(decideEntryRules, r, "these entry rules")}
        </div>
      ))}
      <h2>Visit purposes to approve</h2>
      {(purposes ?? []).filter((r) => r.kind === "access_purposes").length === 0 ? <p>None.</p> : (purposes ?? []).filter((r) => r.kind === "access_purposes").map((r) => (
        <div className="panel" key={r.id}>
          <p><strong>{venue.get(r.venue_id)?.name}</strong> — visit purposes version {r.version_no}</p>
          <PurposesView purposes={(r.content as { purposes: Purpose[] }).purposes} names={names} />
          {decide(decidePurposes, r, "these purposes")}
        </div>
      ))}
      <h2>Outage procedures to approve</h2>
      {(purposes ?? []).filter((r) => r.kind === "outage_procedure").length === 0 ? <p>None.</p> : (purposes ?? []).filter((r) => r.kind === "outage_procedure").map((r) => (
        <div className="panel" key={r.id}>
          <p><strong>{venue.get(r.venue_id)?.name}</strong> — outage procedure version {r.version_no}</p>
          <OutageView content={r.content as OutageProcedure} />
          {decide(decideOutage, r, "this outage procedure")}
        </div>
      ))}
      <h2>Reminders and escalation to approve</h2>
      {(purposes ?? []).filter((r) => r.kind === "chasing").length === 0 ? <p>None.</p> : (purposes ?? []).filter((r) => r.kind === "chasing").map((r) => (
        <div className="panel" key={r.id}>
          <p><strong>{venue.get(r.venue_id)?.name}</strong> — reminders and escalation, version {r.version_no}</p>
          <ChasingView items={(r.content as { items: Record<string, ChaseItem> }).items} names={chaseNames} />
          {decide(decideChasing, r, "this chasing")}
        </div>
      ))}
      <h2>Visits waiting for a decision</h2>
      {(visits ?? []).length === 0 ? <p>None.</p> : (
        <ul>{(visits ?? []).map((v) => {
          const tz = venue.get(v.venue_id)?.timezone ?? "Europe/London";
          return <li key={v.id}><Link href={`/visits/${v.id}`}>{v.reference}</Link>: {v.description} <span className="muted">· {venueTime(v.starts_at, tz)} to {venueTime(v.ends_at, tz)} · {visitState(v.status, v.ends_at)}</span></li>;
        })}</ul>
      )}
    </>
  );
}
