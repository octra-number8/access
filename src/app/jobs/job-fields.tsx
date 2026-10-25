// The fields that describe a job, shared by "start a job" and "change this job".

export interface AreaOption { id: string; name: string; depth: number }
export interface PersonOption { id: string; name: string }

export function JobFields({ areas, people, defaults }: {
  areas: AreaOption[];
  people: PersonOption[];
  defaults?: {
    title?: string; scope?: string; method?: string | null; start?: string; end?: string;
    contact?: string; supervisor?: string | null; areaIds?: string[]; parties?: unknown[];
  };
}) {
  const d = defaults ?? {};
  return (
    <>
      <label>Job title<input name="title" required defaultValue={d.title} placeholder="e.g. Replace sockets on stand 1" /></label>
      <label>What the work is (scope)<textarea name="scope" required rows={3} defaultValue={d.scope}
        placeholder="What will be done, to what, and where. Be specific: changes later may need screening again." /></label>
      <label>How it will be done (optional)<textarea name="method" rows={2} defaultValue={d.method ?? ""} /></label>
      <div className="grid gap-4 sm:grid-cols-2">
        <label>First day<input name="start" type="date" required defaultValue={d.start} /></label>
        <label>Last day<input name="end" type="date" required defaultValue={d.end} /></label>
      </div>
      <fieldset className="stack"><legend>Where (choose every area the work touches)</legend>
        {areas.map((a) => (
          <label className="inline" key={a.id} style={{ paddingLeft: `${a.depth * 1.25}rem` }}>
            <input type="checkbox" name="area_ids" value={a.id} defaultChecked={d.areaIds?.includes(a.id)} /> {a.name}
          </label>
        ))}
      </fieldset>
      <label>Contact for this job
        <select name="contact_person_id" required defaultValue={d.contact}>
          {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
      </label>
      <label>Supervisor (optional for now)
        <select name="supervisor_person_id" defaultValue={d.supervisor ?? ""}>
          <option value="">— Not yet named —</option>
          {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
      </label>
      <input type="hidden" name="parties" value={JSON.stringify(d.parties ?? [])} />
    </>
  );
}
