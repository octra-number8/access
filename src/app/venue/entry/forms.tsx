import { ActionForm } from "@/components/ActionForm";
import type { Purpose } from "@/lib/gate";
import type { AreaOption } from "../../jobs/job-fields";
import { type Audience, saveAudience, savePurpose } from "./actions";

type Option = { id: string; label: string };
const KINDS: Option[] = [
  { id: "employee", label: "Employees" }, { id: "agency", label: "Agency workers" }, { id: "self_employed", label: "Self-employed" },
  { id: "volunteer", label: "Volunteers" }, { id: "subcontractor", label: "Subcontractors" }, { id: "exhibitor", label: "Exhibitors" },
];

function Inductions({ courses, chosen }: { courses: Option[]; chosen?: string[] }) {
  return (
    <fieldset className="stack"><legend>Inductions needed</legend>
      <label className="inline"><input type="radio" name="inductions" value="none" required defaultChecked={chosen?.length === 0} /> None</label>
      <label className="inline"><input type="radio" name="inductions" value="listed" defaultChecked={!!chosen?.length} /> These:</label>
      {courses.map((c) => <label className="inline" key={c.id} style={{ paddingLeft: "1.75rem" }}>
        <input type="checkbox" name="induction_course_ids" value={c.id} defaultChecked={chosen?.includes(c.id)} /> {c.label}</label>)}
    </fieldset>
  );
}

function Escort({ chosen, always }: { chosen?: string; always: string }) {
  return (
    <fieldset className="stack"><legend>Escort</legend>
      <label className="inline"><input type="radio" name="escort" value="never" required defaultChecked={chosen === "never"} /> Not needed</label>
      <label className="inline"><input type="radio" name="escort" value="always" defaultChecked={chosen === "always"} /> {always}</label>
    </fieldset>
  );
}

export function AudienceForm({ versionId, newKey, audience, capacities, courses, areas }: {
  versionId: string; newKey: string; audience?: Audience; capacities: Option[]; courses: Option[]; areas: AreaOption[];
}) {
  const a = audience;
  return (
    <ActionForm action={saveAudience} what="Saving this audience" submitLabel={a ? "Save audience" : "Add audience"}>
      <input type="hidden" name="key" value={newKey} />
      <input type="hidden" name="version_id" value={versionId} />
      <input type="hidden" name="audience_key" value={a?.key ?? ""} />
      <label>Name<input name="name" required defaultValue={a?.name} placeholder="e.g. Build crews" /></label>
      <fieldset className="stack"><legend>Organisations engaged as</legend>
        {capacities.map((c) => <label className="inline" key={c.id}><input type="checkbox" name="capacities" value={c.id} defaultChecked={a?.capacities.includes(c.id)} /> {c.label}</label>)}
      </fieldset>
      <fieldset className="stack"><legend>People working for them as</legend>
        {KINDS.map((k) => <label className="inline" key={k.id}><input type="checkbox" name="relationship_kinds" value={k.id} defaultChecked={a?.relationship_kinds.includes(k.id)} /> {k.label}</label>)}
      </fieldset>
      <label>When
        <select name="event_phase" required defaultValue={a ? (a.event_phase ?? "always") : ""}>
          <option value="">— Choose —</option><option value="always">At any time</option>
          <option value="build">Only during an event&apos;s build</option><option value="live">Only during an event&apos;s live phase</option>
          <option value="breakdown">Only during an event&apos;s breakdown</option>
        </select>
      </label>
      <Inductions courses={courses} chosen={a?.induction_course_ids} />
      <Escort chosen={a?.escort} always="Always escorted" />
      <fieldset className="stack"><legend>May enter</legend>
        {areas.map((ar) => <label className="inline" key={ar.id} style={{ paddingLeft: `${ar.depth * 1.25}rem` }}>
          <input type="checkbox" name="area_ids" value={ar.id} defaultChecked={a?.area_ids.includes(ar.id)} /> {ar.name}</label>)}
      </fieldset>
    </ActionForm>
  );
}

export function PurposeForm({ versionId, newKey, purpose, courses }: { versionId: string; newKey: string; purpose?: Purpose; courses: Option[] }) {
  const p = purpose;
  return (
    <ActionForm action={savePurpose} what="Saving this purpose" submitLabel={p ? "Save purpose" : "Add purpose"}>
      <input type="hidden" name="key" value={newKey} />
      <input type="hidden" name="version_id" value={versionId} />
      <input type="hidden" name="purpose_key" value={p?.key ?? ""} />
      <label>Name<input name="name" required defaultValue={p?.name} placeholder="e.g. Escorted survey" /></label>
      <label>What it allows<input name="allows" required defaultValue={p?.allows} placeholder="e.g. Looking and measuring" /></label>
      <label>What it does not allow<input name="prohibits" required defaultValue={p?.prohibits} placeholder="e.g. Any work, tools or touching plant" /></label>
      <Inductions courses={courses} chosen={p?.induction_course_ids} />
      <Escort chosen={p?.escort} always="Visitors are always escorted" />
      <fieldset className="stack"><legend>Occupier consent</legend>
        <label className="inline"><input type="radio" name="occupier_consent" value="yes" required defaultChecked={p?.occupier_consent === true} /> The occupier of each area must consent</label>
        <label className="inline"><input type="radio" name="occupier_consent" value="no" defaultChecked={p?.occupier_consent === false} /> Not needed</label>
      </fieldset>
      <p className="muted">A purpose never includes work. Roof access without work is a purpose like any other, approved by the venue&apos;s technical authority with its conditions (Q162).</p>
    </ActionForm>
  );
}
