import { OVERRIDABLE_WORDS, type Purpose } from "@/lib/gate";

// Entry rules and visit purposes in words, for the venue and for the access authority who
// approves them. `names` maps ids (areas, courses, capacities) to their names.

interface Audience {
  key: string; name: string; capacities: string[]; relationship_kinds: string[]; event_phase: string | null;
  induction_course_ids: string[]; escort: string; area_ids: string[];
}

const KIND_WORDS: Record<string, string> = {
  employee: "employees", agency: "agency workers", self_employed: "self-employed", volunteer: "volunteers", subcontractor: "subcontractors", exhibitor: "exhibitors",
};
const list = (ids: string[], names: Map<string, string>) => ids.map((i) => names.get(i) ?? "(unknown)").join(", ");

export function EntryRulesView({ content, names }: { content: { audiences: Audience[]; never_overridable?: string[] }; names: Map<string, string> }) {
  return (
    <>
      {content.audiences.length === 0 ? <p>No audiences yet.</p> : (
        <ul>{content.audiences.map((a) => (
          <li key={a.key}><strong>{a.name}</strong>: {list(a.capacities, names)}; {a.relationship_kinds.map((k) => KIND_WORDS[k] ?? k).join(", ")};{" "}
            {a.event_phase ? `only during an event's ${a.event_phase} phase` : "at any time"}; inductions:{" "}
            {a.induction_course_ids.length ? list(a.induction_course_ids, names) : "none needed"}; {a.escort === "always" ? "always escorted" : "no escort needed"};
            {" "}may enter {list(a.area_ids, names)}.</li>
        ))}</ul>
      )}
      <p>{content.never_overridable === undefined ? "Not yet chosen: which refusals can never be overridden here."
        : content.never_overridable.length === 0 ? "Beyond the fixed ones, every refusal can be overridden by an access authority."
        : `Never overridable here, beyond the fixed ones: ${content.never_overridable.map((c) => OVERRIDABLE_WORDS[c] ?? c).join(", ")}.`}</p>
      <p className="muted">Fixed, whatever the rules: a restriction, a revoked or unknown pass, and an inactive record are never overridden at a gate.</p>
    </>
  );
}

export function PurposesView({ purposes, names }: { purposes: Purpose[]; names: Map<string, string> }) {
  return purposes.length === 0 ? <p>No purposes yet.</p> : (
    <ul>{purposes.map((p) => (
      <li key={p.key}><strong>{p.name}</strong>. Allows: {p.allows}. Not allowed: {p.prohibits}. Inductions:{" "}
        {p.induction_course_ids.length ? list(p.induction_course_ids, names) : "none needed"}; {p.escort === "always" ? "always escorted" : "escort not required"};
        {" "}{p.occupier_consent ? "occupiers of the areas must consent" : "no occupier consent"}.</li>
    ))}</ul>
  );
}

export function OutageView({ content }: { content: { instruction?: string; steps: string[]; manifest_max_age_minutes?: number } }) {
  return (
    <>
      <p><strong>{content.instruction || "No instruction yet."}</strong></p>
      {content.steps.length ? <ol style={{ paddingLeft: "1.5rem", listStyle: "decimal" }}>{content.steps.map((s, i) => <li key={i}>{s}</li>)}</ol> : <p>No steps yet.</p>}
      <p>{content.manifest_max_age_minutes ? `A manifest may be used for look-up for ${content.manifest_max_age_minutes} minutes after it is made.`
        : "Not yet set: how long a manifest may be used."}</p>
    </>
  );
}
