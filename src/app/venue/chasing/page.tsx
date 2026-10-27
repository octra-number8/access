import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { CHASE_KINDS, type ChaseItem, ChasingView } from "@/components/chasing-view";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { proposeChasing, saveChasing, startChasingDraft } from "./actions";

export const metadata = { title: "Reminders and escalation" };

// Q207, P8-5: drafted and proposed here by the tenant administrator; approved on the decisions
// page by an appointee who did not write it. Nothing is chased until it is approved.
export default async function Chasing() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/chasing");
  if (session.tenantAdminCustomerIds.length === 0) return <p>Reminders and escalation are set up by tenant administrators.</p>;
  const db = await supabaseServer();
  const { data: venues } = await db.from("venue").select("id, name").in("customer_id", session.tenantAdminCustomerIds).order("name");
  const venue = (venues ?? [])[0];
  if (!venue) return <p>No venue yet.</p>;
  const [{ data: versions }, { data: people }, { data: types }] = await Promise.all([
    db.from("venue_config_version").select("id, version_no, status, content, row_version").eq("venue_id", venue.id).eq("kind", "chasing")
      .in("status", ["draft", "proposed", "approved"]).order("version_no", { ascending: false }),
    db.from("person").select("id, given_name, family_name, deactivated_at").in("customer_id", session.tenantAdminCustomerIds).order("family_name"),
    db.from("appointment_type").select("id, name").eq("venue_id", venue.id).order("name"),
  ]);
  const names = new Map<string, string>([...(people ?? []).map((p) => [p.id, `${p.given_name} ${p.family_name}`] as [string, string]),
    ...(types ?? []).map((t) => [t.id, t.name] as [string, string])]);
  const approved = (versions ?? []).find((v) => v.status === "approved");
  const current = (versions ?? []).find((v) => v.status !== "approved");
  const items = (current?.content as { items?: Record<string, ChaseItem> } | undefined)?.items ?? {};
  const k = () => randomUUID();

  return (
    <>
      <p><Link href="/venue">Venue administration</Link></p>
      <h1>Reminders and escalation — {venue.name}</h1>
      <div className="notice">
        <p>Overdue items are always shown on screen with their owner. Here the venue chooses which are also chased by notice, how often, and when and to whom they are escalated (Q207). There is no default. Escalation tells more people; it never reassigns, approves or closes anything.</p>
      </div>
      {approved ? (
        <details className="panel" open={!current}><summary><strong>Version {approved.version_no} in use</strong></summary>
          <ChasingView items={(approved.content as { items: Record<string, ChaseItem> }).items} names={names} />
        </details>
      ) : <p className="notice notice-blocked">Nothing is approved, so nothing is chased.</p>}

      {current?.status === "draft" ? (
        <div className="panel stack" style={{ maxWidth: "none" }}>
          <h2 style={{ marginTop: 0 }}>Draft version {current.version_no}</h2>
          <ActionForm key={`${current.id}:${current.row_version}`} action={saveChasing} what="Saving the chasing" submitLabel="Save">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={current.id} />
            {CHASE_KINDS.map(([kind, label]) => {
              const x = items[kind];
              return (
                <fieldset className="stack" key={kind}><legend>{label}</legend>
                  <label className="inline"><input type="checkbox" name={`${kind}.on`} defaultChecked={!!x} /> Chase these</label>
                  <label>Remind the owner every (hours)<input name={`${kind}.remind`} type="number" min={1} max={720} defaultValue={x?.remind_every_hours ?? ""} /></label>
                  <label className="inline"><input type="radio" name={`${kind}.escalate`} value="no" defaultChecked={x ? x.escalate_after_hours === null : false} /> Not escalated</label>
                  <label className="inline"><input type="radio" name={`${kind}.escalate`} value="yes" defaultChecked={x ? x.escalate_after_hours !== null : false} /> Escalated after</label>
                  <label>Hours before escalating<input name={`${kind}.after`} type="number" min={1} max={2160} defaultValue={x?.escalate_after_hours ?? ""} /></label>
                  <label>Escalate to people<select name={`${kind}.people`} multiple size={4} defaultValue={x?.escalate_to?.person_ids ?? []}>
                    {(people ?? []).filter((p) => !p.deactivated_at).map((p) => <option key={p.id} value={p.id}>{p.given_name} {p.family_name}</option>)}</select></label>
                  <label>and/or everyone holding<select name={`${kind}.types`} multiple size={3} defaultValue={x?.escalate_to?.appointment_type_ids ?? []}>
                    {(types ?? []).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select></label>
                </fieldset>
              );
            })}
          </ActionForm>
          <ActionForm action={proposeChasing} what="Proposing the chasing" submitLabel="Propose for approval">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={current.id} />
            <input type="hidden" name="row_version" value={current.row_version} />
          </ActionForm>
        </div>
      ) : current?.status === "proposed" ? (
        <div className="panel"><h2 style={{ marginTop: 0 }}>Version {current.version_no}: proposed, waiting for approval</h2><ChasingView items={items} names={names} /></div>
      ) : (
        <ActionForm action={startChasingDraft} what="Starting a draft" submitLabel={approved ? "Start a new version from this one" : "Start the first version"}>
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
        </ActionForm>
      )}
    </>
  );
}
