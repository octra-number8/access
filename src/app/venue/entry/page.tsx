import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { EntryRulesView, OutageView, PurposesView } from "@/components/gate/config-view";
import { OVERRIDABLE_WORDS, type Purpose } from "@/lib/gate";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { venueAreas } from "../../jobs/data";
import {
  createGatePoint, type EntryRules, type OutageProcedure, proposeEntryRules, proposePurposes, removeAudience, removePurpose, saveNeverOverridable,
  saveOutage, startEntryDraft, startOutageDraft, startPurposesDraft,
} from "./actions";
import { AudienceForm, PurposeForm } from "./forms";

export const metadata = { title: "Entry set-up" };

const STATE: Record<string, string> = { draft: "draft", proposed: "proposed, waiting for an access authority" };

// Entry rules, gate points and visit purposes (P7-2, Q121, Q191, §11). Drafted and proposed
// here by the tenant administrator; approved on the decisions page by an access authority.
export default async function EntrySetup() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/entry");
  if (session.tenantAdminCustomerIds.length === 0) return <p>Entry set-up is available to tenant administrators only.</p>;
  const db = await supabaseServer();
  const { data: venues } = await db.from("venue").select("id, name, timezone").in("customer_id", session.tenantAdminCustomerIds).order("name");
  const venue = (venues ?? [])[0];
  if (!venue) return <p>No venue yet.</p>;
  const { data: outageVersions } = await db.from("venue_config_version").select("id, version_no, status, content, row_version").eq("venue_id", venue.id)
    .eq("kind", "outage_procedure").in("status", ["draft", "proposed", "approved"]).order("version_no", { ascending: false });
  const [{ data: rules }, { data: purposeVersions }, { data: points }, { data: capacities }, { data: courses }, areas] = await Promise.all([
    db.from("entry_rule_version").select("id, version_no, status, content, row_version, decision_reason").eq("venue_id", venue.id)
      .in("status", ["draft", "proposed", "approved"]).order("version_no", { ascending: false }),
    db.from("venue_config_version").select("id, version_no, status, content, row_version").eq("venue_id", venue.id).eq("kind", "access_purposes")
      .in("status", ["draft", "proposed", "approved"]).order("version_no", { ascending: false }),
    db.from("gate_point").select("id, name, area_id").eq("venue_id", venue.id).is("retired_at", null).order("name"),
    db.from("engagement_capacity").select("code, label"),
    db.from("induction_course").select("id, title").eq("venue_id", venue.id),
    venueAreas(db, venue.id),
  ]);
  const capOptions = (capacities ?? []).map((c) => ({ id: c.code, label: c.label }));
  const courseOptions = (courses ?? []).map((c) => ({ id: c.id, label: c.title }));
  const names = new Map<string, string>([...capOptions.map((c) => [c.id, c.label] as [string, string]), ...courseOptions.map((c) => [c.id, c.label] as [string, string]),
    ...areas.map((a) => [a.id, a.name] as [string, string])]);
  const ruleApproved = (rules ?? []).find((r) => r.status === "approved");
  const ruleCurrent = (rules ?? []).find((r) => r.status !== "approved");
  const purApproved = (purposeVersions ?? []).find((r) => r.status === "approved");
  const purCurrent = (purposeVersions ?? []).find((r) => r.status !== "approved");
  const outApproved = (outageVersions ?? []).find((r) => r.status === "approved");
  const outCurrent = (outageVersions ?? []).find((r) => r.status !== "approved");
  const k = () => randomUUID();

  return (
    <>
      <p><Link href="/venue">Venue administration</Link> · <Link href="/venue/passes">Card passes</Link></p>
      <h1>Entry set-up — {venue.name}</h1>
      <div className="notice">
        <p className="notice-title">For the venue&apos;s access authority to approve</p>
        <p>Who may be here, when, with which inductions and escorts, and the purposes a visit can have, are drafted here and approved by an appointed access authority who did not write them. Nothing has a default. Until rules are approved, the gate answers &ldquo;Check with the venue&apos;s access authority&rdquo; for everyone.</p>
      </div>

      <h2>Entry rules</h2>
      {ruleApproved ? (
        <details className="panel" open={!ruleCurrent}><summary><strong>Version {ruleApproved.version_no} in use</strong></summary>
          <EntryRulesView content={ruleApproved.content as EntryRules} names={names} />
        </details>
      ) : <p className="notice notice-blocked">No entry rules are approved.</p>}
      {ruleCurrent?.status === "draft" ? (
        <div className="panel stack" style={{ maxWidth: "none" }}>
          <h3>Draft version {ruleCurrent.version_no}</h3>
          {(ruleCurrent.content as EntryRules).audiences.map((a) => (
            <details key={a.key}><summary>{a.name}</summary>
              <AudienceForm versionId={ruleCurrent.id} newKey={k()} audience={a} capacities={capOptions} courses={courseOptions} areas={areas} />
              <ActionForm action={removeAudience} what="Removing this audience" submitLabel="Remove audience" secondary>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="version_id" value={ruleCurrent.id} />
                <input type="hidden" name="audience_key" value={a.key} />
              </ActionForm>
            </details>
          ))}
          <details><summary>Add an audience</summary>
            <AudienceForm versionId={ruleCurrent.id} newKey={k()} capacities={capOptions} courses={courseOptions} areas={areas} />
          </details>
          <details><summary>Refusals that can never be overridden here</summary>
            <ActionForm action={saveNeverOverridable} what="Saving this choice" submitLabel="Save">
              <input type="hidden" name="key" value={k()} />
              <input type="hidden" name="version_id" value={ruleCurrent.id} />
              <p className="muted">Beyond the fixed ones. Tick none to let an access authority set aside any of these; saving records the choice.</p>
              {Object.entries(OVERRIDABLE_WORDS).map(([code, words]) => (
                <label className="inline" key={code}><input type="checkbox" name="codes" value={code}
                  defaultChecked={(ruleCurrent.content as EntryRules).never_overridable?.includes(code)} /> {words}</label>
              ))}
            </ActionForm>
          </details>
          <EntryRulesView content={ruleCurrent.content as EntryRules} names={names} />
          <ActionForm action={proposeEntryRules} what="Proposing these rules" submitLabel="Propose to the access authority">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={ruleCurrent.id} />
            <input type="hidden" name="row_version" value={ruleCurrent.row_version} />
            <p className="muted">Once proposed it cannot be edited. Whoever wrote or proposed it cannot approve it.</p>
          </ActionForm>
        </div>
      ) : ruleCurrent?.status === "proposed" ? (
        <div className="panel"><h3>Version {ruleCurrent.version_no}: {STATE.proposed}</h3>
          <EntryRulesView content={ruleCurrent.content as EntryRules} names={names} /></div>
      ) : (
        <ActionForm action={startEntryDraft} what="Starting a draft" submitLabel={ruleApproved ? "Start a new version from this one" : "Start the first version"}>
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
        </ActionForm>
      )}

      <h2>Gate points</h2>
      {(points ?? []).length === 0 ? <p>None yet.</p> : (
        <ul>{(points ?? []).map((p) => <li key={p.id}>{p.name} <span className="muted">· {names.get(p.area_id) ?? "an area"}</span></li>)}</ul>
      )}
      <details><summary>Add a gate point</summary>
        <ActionForm action={createGatePoint} what="Adding this gate point" submitLabel="Add gate point">
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
          <label>Name<input name="name" required placeholder="e.g. North service gate" /></label>
          <label>The area it opens into<select name="area_id" required>{areas.map((a) => <option key={a.id} value={a.id}>{"— ".repeat(a.depth)}{a.name}</option>)}</select></label>
          <p className="muted">Operators and override authorities need appointments covering this area.</p>
        </ActionForm>
      </details>

      <h2>Visit purposes</h2>
      {purApproved ? (
        <details className="panel" open={!purCurrent}><summary><strong>Version {purApproved.version_no} in use</strong></summary>
          <PurposesView purposes={(purApproved.content as { purposes: Purpose[] }).purposes} names={names} />
        </details>
      ) : <p className="notice notice-blocked">No visit purposes are approved, so no visit can be asked for.</p>}
      {purCurrent?.status === "draft" ? (
        <div className="panel stack" style={{ maxWidth: "none" }}>
          <h3>Draft version {purCurrent.version_no}</h3>
          {((purCurrent.content as { purposes?: Purpose[] }).purposes ?? []).map((p) => (
            <details key={p.key}><summary>{p.name}</summary>
              <PurposeForm versionId={purCurrent.id} newKey={k()} purpose={p} courses={courseOptions} />
              <ActionForm action={removePurpose} what="Removing this purpose" submitLabel="Remove purpose" secondary>
                <input type="hidden" name="key" value={k()} />
                <input type="hidden" name="version_id" value={purCurrent.id} />
                <input type="hidden" name="purpose_key" value={p.key} />
              </ActionForm>
            </details>
          ))}
          <details><summary>Add a purpose</summary><PurposeForm versionId={purCurrent.id} newKey={k()} courses={courseOptions} /></details>
          <ActionForm action={proposePurposes} what="Proposing these purposes" submitLabel="Propose to the access authority">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={purCurrent.id} />
            <input type="hidden" name="row_version" value={purCurrent.row_version} />
          </ActionForm>
        </div>
      ) : purCurrent?.status === "proposed" ? (
        <div className="panel"><h3>Version {purCurrent.version_no}: {STATE.proposed}</h3>
          <PurposesView purposes={(purCurrent.content as { purposes: Purpose[] }).purposes} names={names} /></div>
      ) : (
        <ActionForm action={startPurposesDraft} what="Starting a draft" submitLabel={purApproved ? "Start a new version from this one" : "Start the first version"}>
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
        </ActionForm>
      )}

      <h2>Outage procedure</h2>
      <p className="muted">What gate staff do when Octra cannot be reached (Q199, Q201), and how long a downloaded manifest may be used for look-up (Q198). There is no default: until it is approved, gate devices cannot keep a manifest and an outage means the manual procedure only.</p>
      {outApproved ? (
        <details className="panel" open={!outCurrent}><summary><strong>Version {outApproved.version_no} in use</strong></summary>
          <OutageView content={outApproved.content as OutageProcedure} />
        </details>
      ) : <p className="notice notice-blocked">No outage procedure is approved.</p>}
      {outCurrent?.status === "draft" ? (
        <div className="panel stack" style={{ maxWidth: "none" }}>
          <h3>Draft version {outCurrent.version_no}</h3>
          <ActionForm key={`${outCurrent.id}:${outCurrent.row_version}`} action={saveOutage} what="Saving the outage procedure" submitLabel="Save">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={outCurrent.id} />
            <label>Instruction shown on the offline banner
              <textarea name="instruction" rows={2} defaultValue={(outCurrent.content as OutageProcedure).instruction ?? ""}
                placeholder="e.g. The control room leads. Admit only after the supervisor or access authority confirms." /></label>
            <label>Steps, one per line
              <textarea name="steps" rows={5} defaultValue={(outCurrent.content as OutageProcedure).steps.join("\n")} /></label>
            <label>How long a manifest may be used, in minutes (1 to 1440)
              <input name="max_age" type="number" min={1} max={1440} step={1} defaultValue={(outCurrent.content as OutageProcedure).manifest_max_age_minutes ?? ""} /></label>
            <label>Refresh the manifest automatically every, in minutes (optional; shorter than the time above)
              <input name="refresh" type="number" min={1} max={1439} step={1} defaultValue={(outCurrent.content as OutageProcedure).manifest_refresh_minutes ?? ""} />
              <span className="muted text-sm">Each refresh is a new manifest, kept and disposed of like any other. Leave empty and gate staff refresh it by hand.</span></label>
          </ActionForm>
          <ActionForm action={proposePurposes} what="Proposing the outage procedure" submitLabel="Propose to the access authority">
            <input type="hidden" name="key" value={k()} />
            <input type="hidden" name="version_id" value={outCurrent.id} />
            <input type="hidden" name="row_version" value={outCurrent.row_version} />
          </ActionForm>
        </div>
      ) : outCurrent?.status === "proposed" ? (
        <div className="panel"><h3>Version {outCurrent.version_no}: {STATE.proposed}</h3><OutageView content={outCurrent.content as OutageProcedure} /></div>
      ) : (
        <ActionForm action={startOutageDraft} what="Starting a draft" submitLabel={outApproved ? "Start a new version from this one" : "Start the first version"}>
          <input type="hidden" name="key" value={k()} />
          <input type="hidden" name="venue_id" value={venue.id} />
        </ActionForm>
      )}
    </>
  );
}
