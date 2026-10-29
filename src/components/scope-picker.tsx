// Areas, systems and system types to choose an appointment's scope from (D-008). Only what the
// page offers is shown; the database still checks the result is within the appointer's own scope.
export function ScopePicker({ areas, systems, systemTypes }: {
  areas: Array<{ id: string; name: string; depth: number; with_below?: boolean }>;
  systems: Array<{ id: string; name: string; type: string }>;
  systemTypes?: Array<{ id: string; label: string }>;
}) {
  return (
    <fieldset className="stack"><legend>Where it applies</legend>
      {areas.length ? (
        <div>
          <p className="muted text-sm m-0">Areas. &quot;And below&quot; includes every area inside it.</p>
          {areas.map((a) => (
            <div key={a.id} style={{ paddingLeft: `${a.depth * 1.25}rem` }}>
              <label className="inline"><input type="checkbox" name="area" value={a.id} /> {a.name}</label>
              {a.with_below !== false ? <label className="inline muted text-sm" style={{ marginLeft: ".75rem" }}><input type="checkbox" name="below" value={a.id} defaultChecked /> and below</label> : null}
            </div>
          ))}
        </div>
      ) : <p className="muted">No areas are available.</p>}
      {systems.length ? (
        <div>
          <p className="muted text-sm m-0">Individual systems</p>
          {systems.map((s) => <div key={s.id}><label className="inline"><input type="checkbox" name="system" value={s.id} /> {s.name} <span className="muted">({s.type})</span></label></div>)}
        </div>
      ) : null}
      {systemTypes?.length ? (
        <div>
          <p className="muted text-sm m-0">Every system of a type</p>
          {systemTypes.map((t) => <div key={t.id}><label className="inline"><input type="checkbox" name="system_type" value={t.id} /> Every {t.label} system</label></div>)}
        </div>
      ) : null}
    </fieldset>
  );
}
