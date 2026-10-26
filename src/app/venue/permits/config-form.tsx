"use client";

import { useState } from "react";
import { ActionForm } from "@/components/ActionForm";
import { type ClassConfig, CONTROL_KIND, type RouteStep } from "@/lib/permits";
import { slug } from "@/lib/screening/content";
import { saveClassSettings } from "./actions";

const choice = (v: boolean | undefined) => (v === undefined ? "" : v ? "yes" : "no");

/** Route, notice, evidence, flags and declarations of a draft class configuration. No field has a default. */
export function ConfigForm({ versionId, config, newKey, systemTypes, courses, competencies }: {
  versionId: string; config: ClassConfig; newKey: string;
  systemTypes: Array<{ id: string; label: string }>; courses: Array<{ id: string; title: string }>; competencies: Array<{ id: string; label: string }>;
}) {
  const [route, setRoute] = useState<RouteStep[]>(config.route);
  const [name, setName] = useState("");
  const [kind, setKind] = useState<RouteStep["kind"]>("review");
  const [group, setGroup] = useState(1);
  const [when, setWhen] = useState("");
  const e = config.evidence;
  const pc = config.physical_controls;
  const fw = pc?.find((c) => c.kind === "fire_watch") as { during_work: boolean; post_work_minutes: number } | undefined;
  return (
    <ActionForm action={saveClassSettings} what="Saving this configuration" submitLabel="Save configuration">
      <input type="hidden" name="key" value={newKey} />
      <input type="hidden" name="version_id" value={versionId} />
      <input type="hidden" name="route" value={JSON.stringify(route)} />
      <fieldset className="stack"><legend>Approval route</legend>
        <p className="muted m-0">Steps in the same group run in parallel; groups run in order. Occupier and landlord steps are one per party of that role on the job.</p>
        {route.length === 0 ? <p className="m-0">No steps yet.</p> : (
          <ul>{route.map((s) => (
            <li key={s.key}>Group {s.group}: {s.name} ({s.kind.replace("_", " ")}){s.when ? " — only when the job touches that system type" : ""}{" "}
              <button type="button" className="secondary" onClick={() => setRoute(route.filter((x) => x.key !== s.key))}>Remove</button></li>
          ))}</ul>
        )}
        <div className="grid gap-3 sm:grid-cols-4">
          <label>Step name<input value={name} onChange={(ev) => setName(ev.target.value)} placeholder="e.g. Method review" /></label>
          <label>Kind
            <select value={kind} onChange={(ev) => setKind(ev.target.value as RouteStep["kind"])}>
              <option value="review">Review</option><option value="occupier">Occupier approval</option>
              <option value="landlord_operator">Landlord or operator approval</option><option value="external">External decision</option>
            </select>
          </label>
          <label>Group<input type="number" min={1} value={group} onChange={(ev) => setGroup(Number(ev.target.value))} /></label>
          <label>Only when the job touches
            <select value={when} onChange={(ev) => setWhen(ev.target.value)}>
              <option value="">— Always —</option>
              {systemTypes.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}
            </select>
          </label>
        </div>
        <button type="button" className="secondary" disabled={!name.trim()} onClick={() => {
          setRoute([...route, { key: slug(name, route.map((s) => s.key)), name: name.trim(), kind, group, ...(when ? { when: { system_type_id: when } } : {}) }]);
          setName(""); setWhen("");
        }}>Add step</button>
      </fieldset>
      <fieldset className="stack"><legend>Notice (no default: zero must be chosen if none)</legend>
        <div className="grid gap-3 sm:grid-cols-2">
          <label>Amount<input name="notice_amount" type="number" min={0} defaultValue={config.notice?.amount ?? ""} /></label>
          <label>Unit
            <select name="notice_unit" defaultValue={config.notice?.unit ?? ""}>
              <option value="">— Choose —</option><option value="working_days">Working days</option>
              <option value="calendar_days">Calendar days</option><option value="hours">Hours</option>
            </select>
          </label>
          <label>The venue&apos;s cut-off time applies
            <select name="cutoff_applies" defaultValue={choice(config.notice?.cutoff_applies)}><option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option></select>
          </label>
          <label>A resubmission restarts the notice (Q88)
            <select name="restart" defaultValue={choice(config.notice?.restart_on_resubmission)}><option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option></select>
          </label>
        </div>
      </fieldset>
      <fieldset className="stack"><legend>What the team needs</legend>
        {courses.length === 0 && competencies.length === 0 ? <p className="m-0 muted">The venue has no induction courses or competency types yet.</p> : null}
        {courses.map((c) => <label className="inline" key={c.id}><input type="checkbox" name="induction_course_ids" value={c.id} defaultChecked={e?.induction_course_ids.includes(c.id)} /> Everyone: induction {c.title}</label>)}
        {competencies.map((c) => <label className="inline" key={c.id}><input type="checkbox" name="team_competency_type_ids" value={c.id} defaultChecked={e?.team_competency_type_ids.includes(c.id)} /> Everyone: {c.label}</label>)}
        {competencies.map((c) => <label className="inline" key={`s${c.id}`}><input type="checkbox" name="supervisor_competency_type_ids" value={c.id} defaultChecked={e?.supervisor_competency_type_ids.includes(c.id)} /> Supervisor: {c.label}</label>)}
      </fieldset>
      <fieldset className="stack"><legend>Physical controls (P6-8)</legend>
        <p className="m-0 muted">A permit of this class is issued, accepted and restarted only with these in place. There is no default.</p>
        <label>Does this class need physical controls?
          <select name="controls_choice" defaultValue={pc === undefined ? "" : pc.length === 0 ? "none" : "some"}>
            <option value="">— Choose —</option><option value="none">None</option><option value="some">Yes: the ones ticked below</option>
          </select>
        </label>
        {(["isolation", "impairment", "exclusion_zone", "fire_watch"] as const).map((k) => (
          <label className="inline" key={k}><input type="checkbox" name="control_kind" value={k} defaultChecked={pc?.some((c) => c.kind === k)} /> {CONTROL_KIND[k]}</label>
        ))}
        <div className="row">
          <label>Fire watch during the work
            <select name="fire_watch_during" defaultValue={fw ? (fw.during_work ? "yes" : "no") : ""}><option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option></select>
          </label>
          <label>Fire watch after the work (minutes, Q130)<input name="fire_watch_minutes" type="number" min={0} step={1} defaultValue={fw?.post_work_minutes ?? ""} /></label>
        </div>
      </fieldset>
      <fieldset className="stack"><legend>While the permit is live</legend>
        <p className="m-0 muted">None of these has a default. Leave a field blank until the venue has decided it.</p>
        <div className="row">
          <label>Extensions allowed (times, Q108)<input name="extension_count" type="number" min={0} step={1} defaultValue={config.extension?.max_count ?? ""} /></label>
          <label>Total extension (hours)<input name="extension_hours" type="number" min={0} step="any" defaultValue={config.extension?.max_total_hours ?? ""} /></label>
        </div>
        <label>People added to the team after issue (Q106)
          <select name="worker_add" defaultValue={config.worker_add ?? ""}><option value="">— Choose —</option>
            <option value="supervisor">The supervisor adds them, after the checks</option>
            <option value="issuer_approval">An issuer approves each addition</option></select>
        </label>
        <div className="row">
          <label>Revalidation while live (Q112)
            <select name="revalidation" defaultValue={config.revalidation?.mode ?? ""}><option value="">— Choose —</option>
              <option value="none">Not needed</option><option value="interval">Every so many hours</option></select>
          </label>
          <label>Every (hours)<input name="revalidation_hours" type="number" min={0} step="any"
            defaultValue={config.revalidation?.mode === "interval" ? config.revalidation.every_hours : ""} /></label>
        </div>
      </fieldset>
      <label>Late-notice exceptions prohibited (Q93)
        <select name="override_prohibited" defaultValue={choice(config.override_prohibited)}><option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option></select>
      </label>
      <label>Submission declaration, one item per line (Q68)<textarea name="submission_declaration" rows={3} defaultValue={config.submission_declaration.join("\n")} /></label>
      <label>Acceptance declaration, one item per line (Q101)<textarea name="acceptance_declaration" rows={3} defaultValue={config.acceptance_declaration.join("\n")} /></label>
      <label>Hand-back declaration, one item per line (Q113)<textarea name="hand_back_declaration" rows={3} defaultValue={(config.hand_back_declaration ?? []).join("\n")} /></label>
      <label>Hand-back inspection (Q114)
        <select name="hand_back_inspection" defaultValue={config.hand_back_inspection ?? ""}><option value="">— Choose —</option>
          <option value="in_person">Inspected in person</option><option value="remote_allowed">May be accepted remotely</option></select>
      </label>
    </ActionForm>
  );
}
