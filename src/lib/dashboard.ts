// Dashboards and reports (Q204, Q205, Q209): actions with what is needed, who owns it and when.
// The database builds every item from the checks the decisions use; this file only words them.
import { type PermitSummary, SUSPENSION_KIND } from "./permits";

export interface DashItem {
  kind: string; title: string; what: string; who: string; at: string | null; at_label: string; link: string; overdue: boolean;
  items?: string[];
}

export interface VenueDashboard {
  ok: true; venue: string; timezone: string; from: string; to: string;
  work: Array<PermitSummary & { starts_at: string; event: string | null; phase: string | null }>;
  visits: Array<{ id: string; reference: string; status: string; organisation: string; purpose: string | null; areas: string[]; from: string; to: string; roster: number }>;
  due: DashItem[]; stopped: DashItem[]; closing: DashItem[]; affecting: DashItem[];
}

export interface OrganisationDashboard {
  ok: true; organisation: string;
  jobs: Array<{ id: string; reference: string; status: string; title: string; venue: string; timezone: string; from: string; to: string;
                permits: Array<{ id: string; class_name: string; kind: string; status: string; missing: Array<{ problem: string; who: string }> }> }>;
  visits: Array<{ id: string; reference: string; status: string; venue: string; timezone: string; purpose: string | null; from: string; to: string;
                  consents_waiting: boolean; consents_refused: boolean }>;
  returned: DashItem[]; workers: DashItem[]; venue_decisions: DashItem[]; live: PermitSummary[];
}

export const PHASE: Record<string, string> = { build: "Build", live: "Live event", breakdown: "Breakdown" };

/** What a live permit needs next, and who owns it. */
export function permitNeeds(p: PermitSummary): Array<{ what: string; who: string }> {
  const out: Array<{ what: string; who: string }> = [];
  if (p.status === "hand_back_pending") out.push({ what: p.duties ? `Handed back; ${p.duties} duty(ies) still outstanding` : "Handed back; ready to accept", who: "A hand-back acceptor" });
  if (p.status === "expired") out.push({ what: `Expired with ${p.duties} duty(ies) outstanding: close it out`, who: "Its supervisor or an issuer" });
  for (const h of p.holding) out.push({ what: `${SUSPENSION_KIND[h.kind] ?? h.kind}: ${h.reason}`, who: h.who });
  if (p.status === "suspended" && p.holding.length === 0) out.push({ what: "Every stop lifted: waiting for re-acceptance", who: "Its supervisor" });
  if (p.status === "issued_awaiting_acceptance") out.push({ what: "Waiting for acceptance at the workface", who: "Its supervisor" });
  if (p.extension_pending) out.push({ what: "An extension is waiting to be acknowledged", who: "Its supervisor" });
  if (p.revalidation_overdue) out.push({ what: "Revalidation overdue: work must not continue until confirmed", who: "Its supervisor" });
  if (p.area_return_pending) out.push({ what: "Areas handed back, waiting for a decision", who: "A hand-back acceptor" });
  if (p.abandoned) out.push({ what: "Flagged abandoned: still to be closed out", who: "An issuer" });
  return out;
}

/** What the organisation does next on a permit it has requested, before it is live. */
export function requestNeeds(status: string): string | null {
  switch (status) {
    case "draft": return "Prepare and submit the request";
    case "more_information_required": return "Answer the information request and resubmit";
    case "submitted": case "under_review": return "Waiting for the venue's decisions";
    case "approved_for_issue": return "Waiting to be issued";
    case "issued_awaiting_acceptance": return "Accept at the workface";
    case "refused": return "Refused: change the job or cancel it";
    default: return null;
  }
}

// ---- Reports ------------------------------------------------------------------------------------

export const REPORT_KINDS: Array<{ key: string; label: string; venueOnly?: boolean; about: string }> = [
  { key: "approval_lead_times", label: "Approval lead times", about: "Each step decision: when the request was submitted, when it was decided and by whom." },
  { key: "returns", label: "Returns and information requests", about: "Each information request, exactly what was asked, and when it was answered." },
  { key: "late_requests", label: "Late requests and emergency work", about: "Late-notice and restriction-conflict requests and emergency work, by organisation, work type and stated cause (Q96)." },
  { key: "hand_backs", label: "Hand-backs", about: "Each hand-back, its decision, how long it waited, and any duties still outstanding." },
  { key: "gate_activity", label: "Gate activity", venueOnly: true, about: "Evaluations, scans, overrides, offline entries and outage exceptions, by gate and day." },
  { key: "visit_attendance", label: "Visit attendance", about: "Each visit's roster: who arrived and left, and who did not attend." },
];

export interface Report {
  ok: true; kind: string; venue: string; timezone: string; from: string; to: string; organisation: string | null;
  columns: Array<{ key: string; label: string }>;
  rows: Array<Record<string, string | number | null>>;
}

/**
 * CSV (RFC 4180) for a report. A cell that a spreadsheet would read as a formula is prefixed with
 * an apostrophe, so text typed by a contractor can never run as one.
 */
export function toCsv(columns: Report["columns"], rows: Report["rows"]): string {
  const cell = (v: unknown) => {
    let s = v === null || v === undefined ? "" : String(v);
    if (/^[=+\-@\t\r]/.test(s) && !/^-?\d+(\.\d+)?$/.test(s)) s = `'${s}`;
    return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [columns.map((c) => cell(c.label)).join(","), ...rows.map((r) => columns.map((c) => cell(r[c.key])).join(","))].join("\r\n") + "\r\n";
}

/** Today in a time zone, as YYYY-MM-DD. */
export function dayIn(tz: string, offsetDays = 0): string {
  const d = new Date(Date.now() + offsetDays * 86_400_000);
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}

/** A report's scope: "venue:<id>" for the venue's side, "org:<organisation>:<venue>" for an organisation's own rows. */
export function parseScope(scope: string | undefined): { venueId: string; organisationId: string | null } | null {
  const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
  const v = scope?.match(new RegExp(`^venue:(${uuid})$`));
  if (v) return { venueId: v[1]!, organisationId: null };
  const o = scope?.match(new RegExp(`^org:(${uuid}):(${uuid})$`));
  return o ? { venueId: o[2]!, organisationId: o[1]! } : null;
}

export const isDay = (s: string | undefined): s is string => !!s && /^\d{4}-\d{2}-\d{2}$/.test(s);
