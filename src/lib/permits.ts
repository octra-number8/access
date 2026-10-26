// Permit configuration and wording (phase 5c, D-018). A state says what was recorded;
// only "Active" means the defined work may proceed, and only within its conditions.

import type { ScreeningQuestion } from "./screening/content";

export interface RouteStep {
  key: string; name: string; kind: "review" | "occupier" | "landlord_operator" | "external"; group: number;
  when?: { system_type_id: string };
}

export interface ClassConfig {
  questions: ScreeningQuestion[];
  route: RouteStep[];
  submission_declaration: string[];
  acceptance_declaration: string[];
  /** Replaced by physical_controls (P6-8); kept only to read older versions. */
  requires_physical_controls?: boolean;
  physical_controls?: PhysicalControl[];
  override_prohibited?: boolean;
  // Live rules (phase 6a): each must be chosen; none has a default.
  extension?: { max_count: number; max_total_hours: number };
  worker_add?: "supervisor" | "issuer_approval";
  revalidation?: { mode: "none" } | { mode: "interval"; every_hours: number };
  // Hand-back (phase 6c): what the supervisor confirms, and how it is inspected. No default.
  hand_back_declaration?: string[];
  hand_back_inspection?: "in_person" | "remote_allowed";
  notice?: { amount: number; unit: "working_days" | "calendar_days" | "hours"; cutoff_applies: boolean; restart_on_resubmission: boolean };
  evidence?: { induction_course_ids: string[]; team_competency_type_ids: string[]; supervisor_competency_type_ids: string[] };
}

export type PhysicalControl =
  | { kind: "isolation" } | { kind: "impairment" } | { kind: "exclusion_zone" }
  | { kind: "fire_watch"; during_work: boolean; post_work_minutes: number };

export const CONTROL_KIND: Record<PhysicalControl["kind"], string> = {
  isolation: "Isolation", impairment: "Impairment", fire_watch: "Fire watch", exclusion_zone: "Exclusion zone",
};

export const EMPTY_CONFIG: ClassConfig = { questions: [], route: [], submission_declaration: [], acceptance_declaration: [] };

export const PERMIT_STATE: Record<string, string> = {
  draft: "Draft",
  submitted: "Submitted",
  under_review: "Under review",
  more_information_required: "More information required",
  approved_for_issue: "Approved for issue",
  issued_awaiting_acceptance: "Issued, awaiting acceptance",
  active: "Active",
  refused: "Refused",
  cancelled: "Cancelled",
  expired: "Expired",
  suspended: "Suspended",
  hand_back_pending: "Hand-back pending",
  closed: "Closed",
};

export const STEP_KIND: Record<string, string> = {
  review: "Review", occupier: "Occupier approval", landlord_operator: "Landlord or operator approval", external: "External decision",
};

export const OUTCOME: Record<string, string> = {
  no_further_comments: "Reviewed for the stated scope, no further comments",
  conditions: "Reviewed for the stated scope, with conditions",
  more_information: "More information asked for",
  refused: "Refused",
  not_applicable: "Not applicable",
  reopened: "Decision withdrawn",
};

export const NOTICE_UNIT: Record<string, string> = { working_days: "working days", calendar_days: "calendar days", hours: "hours" };

export function noticeText(n: ClassConfig["notice"]): string {
  if (!n) return "Not set";
  if (n.amount === 0) return "No notice (chosen)";
  return `${n.amount} ${NOTICE_UNIT[n.unit] ?? n.unit}${n.cutoff_applies ? ", counted from the next day after the cut-off" : ""}${n.restart_on_resubmission ? "; restarts when resubmitted" : ""}`;
}

export interface PermitDetail {
  ok: true;
  id: string; kind: "work_approval" | "child"; status: string; row_version: number;
  class: { id: string; code: string; name: string };
  class_version: { id: string; no: number; content: ClassConfig } | null;
  work_package_id: string; job_reference: string; job_status: string; job_title: string;
  performing_organisation_id: string; performing_organisation: string; venue_id: string; venue_timezone: string;
  parent: { id: string; status: string; class_name: string } | null;
  children: Array<{ id: string; status: string; class_name: string }>;
  draft: { answers: Record<string, string[]>; window_from: string | null; window_to: string | null; document_version_ids: string[] };
  job_window: { from: string; to: string };
  job_areas: string[];
  version: null | {
    id: string; no: number; answers: Record<string, string[]>; window_from: string; window_to: string; declaration: string[];
    declared_by: string; submitted_at: string; documents: Array<{ id: string; title: string; version_no: number }>;
  };
  versions: Array<{ no: number; at: string; by: string; responds_to_rfi: boolean }>;
  steps: Array<{
    id: string; key: string; name: string; kind: string; group: number; open: boolean; party: string | null; areas: string[];
    decision: null | { id: string; outcome: string; reason: string; scope_wording: string | null; by: string; by_person_id: string; at: string;
      conditions: Array<{ id: string; text: string; acknowledge: boolean }>; external: Record<string, unknown> | null };
    previous: null | { outcome: string; reason: string; scope_wording: string | null; by: string };
  }>;
  rfis: Array<{ id: string; version_no: number; message: string; items: Array<{ about?: string; text: string }>; asked_by: string; step: string; at: string;
    responses: string[] | null }>;
  team: Array<{ person_id: string; name: string; role: string }>;
  exceptions: Array<{ id: string; kind: string; reason: string; consequence: string; restriction: string | null; by: string; at: string;
    decision: null | { outcome: string; conditions: string | null; reason: string; by: string; at: string } }>;
  restrictions: Array<{ id: string; effect: string; reason: string; from: string; to: string }>;
  notice: { known: boolean; problem?: string; earliest_start?: string; compliant?: boolean; measured_from?: string };
  blockers: Array<{ check: string; problem: string; who: string }> | null;
  draft_problems: string[] | null;
  snapshot: null | { id: string; issued_at: string; issuer: string; content: {
    steps: Array<{ key: string; name: string; decision: { outcome: string; scope_wording: string | null; conditions: Array<{ id: string; text: string; acknowledge: boolean }> } }>;
    team: Array<{ person_id: string; name: string; role: string }>;
    class_version: { acceptance_declaration: string[] };
    version: { window_from: string; window_to: string };
    job: { title: string; scope: string; method: string | null; areas: Array<{ name: string }> };
    exceptions: Array<{ kind: string; outcome: string; conditions: string | null }>;
  } };
  acceptance: null | { accepted_at: string; by: string; briefed: string[]; briefed_at: string };
  // Live state (phase 6).
  window_end: string | null;
  held: boolean;
  reissue_pending: boolean;
  last_accepted_at: string | null;
  suspensions: Array<{ id: string; kind: string; category: string | null; reason: string; by: string | null; at: string; holding: boolean;
    who_lifts: string; lift: null | { id: string; via: string; reason: string; conditions: string[]; by: string; at: string } }>;
  open_lifts: Array<{ id: string; conditions: string[]; at: string }>;
  team_live: Array<{ member_id: string; person_id: string; name: string; role: string; added_live: boolean; approval_required: boolean;
    approved_at: string | null; briefed_at: string | null; counts: boolean; added_at: string; removed_at: string | null;
    removal_reason: string | null; removed_by: string | null }>;
  extensions: Array<{ id: string; previous_end: string; new_end: string; reason: string; by: string; at: string; acknowledged_at: string | null; sha256: string }>;
  extension_rule: { max_count: number; max_total_hours: number } | null;
  worker_add_rule: string | null;
  revalidation: { chosen: boolean; required: boolean; every_hours?: number; last_at?: string; due_at?: string; overdue?: boolean };
  reacceptances: Array<{ at: string; by: string; briefed: string[] }>;
  controls: PermitControls;
  close_out: PermitCloseOut;
  emergency_contacts: Array<{ label: string; phone: string }> | null;
}

export interface Blocker { check?: string; duty?: string; problem: string; who: string }

export interface PermitControls {
  required: PhysicalControl[] | null;
  blockers: Blocker[];
  isolations: Array<{ id: string; system: string; points: string; status: string; row_version: number; failure_open: boolean;
    locks: Array<{ id: string; person_id: string; name: string; lock_ref: string; on_at: string }>; steps: Array<{ step: string; by: string; at: string }> }>;
  impairments: Array<{ id: string; system: string; zones: string; status: string; row_version: number; max_hours: number | null;
    impaired_at: string | null; due_at: string | null; overdue: boolean; failure_open: boolean }>;
  fire_watches: Array<{ id: string; phase: string; watcher: string; status: string; row_version: number; minimum_minutes: number;
    started_at: string | null; ended_at: string | null; earliest_end: string | null }>;
  exclusion_zones: Array<{ id: string; description: string; area: string | null; status: string; row_version: number; removed_at: string | null }>;
  custody: Array<{ id: string; item: string; kind: string; reference: string; holder: string; issued_at: string; returned_at: string | null }>;
}

export interface PermitCloseOut {
  duties: Blocker[];
  live_area_ids: string[];
  hand_back_declaration: string[] | null;
  hand_back_inspection: string | null;
  hand_backs: Array<{ id: string; from: string; route: string; work_complete: boolean; remaining_work: string | null; area_state: string; by: string; at: string;
    decision: null | { outcome: string; inspection: string; reason: string; by: string; at: string } }>;
  area_returns: Array<{ id: string; areas: string[]; area_state: string; by: string; at: string; outcome: string | null; decided_by: string | null; reason: string | null }>;
  transferred: Array<{ kind: string; control_id: string; at: string; reason: string; owner: string | null }>;
  abandoned: null | { reason: string; by: string; at: string };
  close_out: null | { id: string; sha256: string; at: string };
  emergency: null | { id: string; reference: string; category: string; authorised_by: string; at: string; deadline_at: string;
    retrospective_submitted: boolean; overdue: boolean };
}

/** A live permit in a list (the board, or the team member's own permits). */
export interface PermitSummary {
  id: string; kind: string; status: string; class_name: string; job_reference: string; job_title: string; organisation: string;
  areas: string[]; window_end: string | null; venue_timezone: string; role?: string;
  holding: Array<{ id: string; kind: string; reason: string; at: string; who: string }>;
  reissue_pending: boolean; extension_pending: boolean; revalidation_overdue: boolean; duties: number; area_return_pending: boolean; abandoned: boolean;
}

export const STOP_CATEGORY: Record<string, string> = {
  unsafe_act: "Unsafe act or condition", change_in_conditions: "Change in conditions", control_failure: "A control has failed",
  emergency: "Emergency", weather: "Weather", instruction: "Instruction from an authority", other: "Other",
};

export const SUSPENSION_KIND: Record<string, string> = {
  stop: "Work stopped", job_stop: "Stopped with the rest of the job", area_stop: "Area stop", material_change: "The job changed",
  supervisor_change: "Supervisor changed", parent_ended: "The Work Approval ended", control_failure: "A control failed",
};

export const CONTROL_STATE: Record<string, string> = {
  requested: "Requested", authorised: "Authorised", refused: "Refused", withdrawn: "Withdrawn", applied: "Applied, not proved",
  proved: "Proved", removed: "Removed", returned: "Returned to service", impaired: "Impaired", tested: "Reinstatement tested",
  restored: "Restored", arranged: "Arranged", started: "Under way", ended: "Finished", set_up: "In place",
};

/** Time left until an instant, in words. */
export function timeLeft(to: string | null | undefined): string {
  if (!to) return "—";
  const ms = new Date(to).getTime() - Date.now();
  if (ms <= 0) return "ended";
  const h = Math.floor(ms / 3_600_000);
  return h >= 48 ? `${Math.floor(h / 24)} days left` : `${h} h ${Math.floor((ms % 3_600_000) / 60_000)} min left`;
}

/** Date and time in the venue's own time zone. */
export function venueTime(iso: string | null | undefined, tz: string): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-GB", { timeZone: tz, day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" });
}

function parts(ms: number, tz: string): Record<string, number> {
  const out: Record<string, number> = {};
  for (const p of new Intl.DateTimeFormat("en-GB", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit" }).formatToParts(new Date(ms))) {
    if (p.type !== "literal") out[p.type] = Number(p.value);
  }
  return out;
}
function offsetAt(ms: number, tz: string): number {
  const p = parts(ms, tz);
  return Date.UTC(p.year!, p.month! - 1, p.day!, p.hour!, p.minute!, p.second!) - Math.floor(ms / 1000) * 1000;
}

/** A datetime-local value ("YYYY-MM-DDTHH:mm") read as the venue's local time. */
export function fromVenueLocal(local: string, tz: string): string {
  const [d, t] = local.split("T");
  const [y, m, day] = d!.split("-").map(Number);
  const [h, mi] = (t ?? "00:00").split(":").map(Number);
  const wall = Date.UTC(y!, m! - 1, day!, h!, mi!);
  // A wall time can occur twice when clocks go back: take the earlier instant. When
  // clocks go forward and it never occurs, take the instant just after the gap.
  const candidates = [wall - offsetAt(wall - 6 * 3_600_000, tz), wall - offsetAt(wall + 6 * 3_600_000, tz)]
    .filter((ms) => toVenueLocal(new Date(ms).toISOString(), tz) === local.slice(0, 16));
  const ms = candidates.length ? Math.min(...candidates) : wall - offsetAt(wall + 6 * 3_600_000, tz);
  return new Date(ms).toISOString();
}

/** An instant as a datetime-local value in the venue's time zone. */
export function toVenueLocal(iso: string | null | undefined, tz: string): string {
  if (!iso) return "";
  const p = parts(new Date(iso).getTime(), tz);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${p.year}-${pad(p.month!)}-${pad(p.day!)}T${pad(p.hour!)}:${pad(p.minute!)}`;
}
