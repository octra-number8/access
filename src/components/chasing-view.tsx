// The venue's chasing in words, for the venue and for the appointee who approves it.
export const CHASE_KINDS: Array<[string, string]> = [
  ["approval_step", "Decisions waiting on a permit step"],
  ["rfi", "Information requested from a contractor"],
  ["hand_back", "Hand-backs due"],
  ["fire_watch", "Fire watches not started when work stopped (critical)"],
  ["impairment", "Impairments past their approved time (critical)"],
  ["invitation", "Invitations not yet accepted"],
];
const LABEL: Record<string, string> = Object.fromEntries(CHASE_KINDS);

export interface ChaseItem { remind_every_hours: number; escalate_after_hours: number | null; escalate_to?: { person_ids: string[]; appointment_type_ids: string[] } }

export function ChasingView({ items, names }: { items: Record<string, ChaseItem>; names: Map<string, string> }) {
  const entries = Object.entries(items);
  if (entries.length === 0) return <p>Nothing is chased.</p>;
  return (
    <ul>{entries.map(([k, x]) => (
      <li key={k}><strong>{LABEL[k] ?? k}</strong>: owners reminded every {x.remind_every_hours} h;{" "}
        {x.escalate_after_hours === null ? "not escalated" : `escalated after ${x.escalate_after_hours} h to ${[
          ...(x.escalate_to?.person_ids ?? []).map((id) => names.get(id) ?? "someone"),
          ...(x.escalate_to?.appointment_type_ids ?? []).map((id) => `every ${names.get(id) ?? "appointee"}`),
        ].join(", ")}`}.</li>
    ))}</ul>
  );
}
