// Shapes returned by api.authority_overview, api.my_appointments and api.grant_options (S1a,
// D-026). Every permission is decided by the database; these are for display only.

export interface Appointment {
  id: string; row_version: number; is_root: boolean; venue_id: string; venue: string;
  appointee_person_id: string; appointee: string; type: string; version_no: number;
  actions: Array<{ code: string; description: string }>; classes: string[]; scope: string[];
  valid_from: string; valid_to: string | null; review_due_on: string | null; limitations: string | null;
  root_evidence_ref: string | null; competence_evidence: string[];
  appointed_by: string | null; recorded_by: string | null; recorded_by_person_id: string | null; confirmed_by: string | null;
  under: { id: string; appointee: string; type: string } | null;
  status: string; state: string; state_words: string; next_step: string | null; revoked_reason: string | null;
  can_confirm?: boolean; can_revoke_root?: boolean; can_revoke?: boolean; can_grant?: boolean; can_delegate?: boolean;
}

export interface Delegation {
  id: string; row_version: number; venue: string; delegator: string; delegator_person_id: string;
  delegate: string; delegate_person_id: string; actions: string[]; classes: string[]; scope: string[];
  valid_from: string; valid_to: string; reason: string; in_force: boolean; status: string;
}

export interface ScopeItem {
  area_id: string | null; include_descendants: boolean | null; system_id: string | null;
  system_type_id: string | null; restrict_to_area_id: string | null;
}

/** Action descriptions carry the source question in brackets; people do not need it. */
export function plain(description: string): string {
  return description.replace(/\s*\((?:Q\d|D-|P\d|S\d|invariant|CLAUDE)[^)]*\)\s*$/, "");
}

/** The scope JSON api.grant_appointment expects, from the form's area, below and system boxes. */
export function scopesFrom(form: FormData): Array<Record<string, unknown>> {
  const areas = form.getAll("area").map(String);
  const below = new Set(form.getAll("below").map(String));
  const systems = form.getAll("system").map(String);
  const types = form.getAll("system_type").map(String);
  return [
    ...areas.map((id) => ({ area_id: id, include_descendants: below.has(id) })),
    ...systems.map((id) => ({ system_id: id })),
    ...types.map((id) => ({ system_type_id: id })),
  ];
}
