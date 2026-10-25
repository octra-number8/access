"use client";

import { useState } from "react";
import { ActionForm } from "@/components/ActionForm";
import type { ClassConfig, RouteStep } from "@/lib/permits";
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
      <label>Needs physical controls (isolation, impairment or fire watch)
        <select name="requires_physical_controls" defaultValue={choice(config.requires_physical_controls)}><option value="">— Choose —</option><option value="yes">Yes: cannot be issued until live controls exist</option><option value="no">No</option></select>
      </label>
      <label>Late-notice exceptions prohibited (Q93)
        <select name="override_prohibited" defaultValue={choice(config.override_prohibited)}><option value="">— Choose —</option><option value="yes">Yes</option><option value="no">No</option></select>
      </label>
      <label>Submission declaration, one item per line (Q68)<textarea name="submission_declaration" rows={3} defaultValue={config.submission_declaration.join("\n")} /></label>
      <label>Acceptance declaration, one item per line (Q101)<textarea name="acceptance_declaration" rows={3} defaultValue={config.acceptance_declaration.join("\n")} /></label>
    </ActionForm>
  );
}
