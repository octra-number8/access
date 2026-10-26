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
