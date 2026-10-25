// Plain-English wording for a job's recorded state and its next action (Q54, CLAUDE.md §6).
// A state says what was recorded; "routed" never means the work may start.

export interface JobDetail {
  ok: true;
  id: string; reference: string; status: string; row_version: number; cancel_reason: string | null;
  venue_id: string; venue: string; work_type: string; event: string | null;
  performing_organisation_id: string; performing_organisation: string; created_by: string;
  revision: {
    id: string; no: number; title: string; scope: string; method: string | null; window_from: string; window_to: string;
    contact_person_id: string; contact: string; supervisor_person_id: string | null; supervisor: string | null;
    areas: Array<{ id: string; name: string }>; systems: Array<{ id: string; name: string }>;
    parties: Array<{ organisation_id: string; name: string; role: string }>;
  };
  revisions: Array<{ no: number; kind: string; reason: string | null; title: string; at: string; by: string }>;
  draft_answers: Record<string, string[]> | null;
  draft_selected: string[] | null;
  screening: null | {
    version_no: number; approved_by: string; approved_at: string; submitted_at: string; submitted_by: string;
    answers: Array<{ question: string; answer: string }>;
  };
  recommendations: Array<{
    id: string; status: string; row_version: number; applicant_selected: boolean; permit_class_id: string; class_name: string;
    reasons: Array<{ rule_key: string; rationale: string }>;
    challenge: null | { reason: string; at: string; by: string; documents: number };
    decision: null | { outcome: string; reason: string; at: string; by: string };
  }>;
  holds: Array<{
    id: string; status: string; row_version: number; class_name: string;
    reasons: Array<{ rule_key: string; rationale: string }>;
    evidence: Array<{ decider: string; organisation: string; reference: string | null; scope: string; decided_on: string; conditions: string | null; documents: number }>;
    decision: null | { outcome: string; reason: string; at: string; by: string };
  }>;
  no_permit_required: Array<{ scope: string; reason: string; at: string; by: string; for_class: string | null }>;
  routable_blockers: null | {
    open_recommendations: number; open_challenges: number; open_holds: number; refused_holds: number; needs_no_permit_decision: boolean;
  };
}

export const JOB_STATE: Record<string, string> = {
  draft: "Draft",
  screening: "Screening: permits being settled",
  routed: "Permit routing settled",
  cancelled: "Cancelled",
};

export const RECOMMENDATION_STATE: Record<string, string> = {
  recommended: "Recommended: waiting for the applicant",
  accepted: "Accepted by the applicant",
  challenged: "Challenged: waiting for the venue's authority",
  upheld: "Challenge decided: the permit is required",
  not_required: "Challenge decided: no permit required for the stated scope",
  superseded: "Replaced by a change to the job",
};

export const HOLD_STATE: Record<string, string> = {
  open: "Held: waiting for external evidence to be accepted",
  accepted: "External evidence accepted",
  refused: "External evidence refused: this work cannot go ahead as described",
  superseded: "Replaced by a change to the job",
};

export const ROLE: Record<string, string> = {
  performing: "Performing organisation", commissioning: "Commissioning", principal_contractor: "Principal contractor",
  affected_occupier: "Affected occupier", landlord_operator: "Landlord or operator",
};

/** Classes the job needs: recommendations the applicant accepted, or whose challenge was decided as required. */
export function requiredClasses(j: JobDetail): string[] {
  return j.recommendations.filter((r) => r.status === "accepted" || r.status === "upheld").map((r) => r.class_name);
}

/** The next action on a job and who owns it. */
export function nextAction(j: JobDetail): { what: string; who: string } | null {
  if (j.status === "cancelled") return null;
  if (j.status === "draft") return { what: "Answer the screening questions and submit the job", who: j.performing_organisation };
  if (j.status === "routed") {
    const needed = requiredClasses(j);
    return needed.length > 0
      ? { what: `Permits needed: ${needed.join(", ")}. Permit requests are not yet available in Octra`, who: j.performing_organisation }
      : { what: "No permit needed for the job as described. Entry is still decided at the gate", who: "—" };
  }
  const b = j.routable_blockers;
  if (!b) return null;
  if (b.refused_holds > 0) return { what: "Change the job or cancel it: external evidence was refused", who: j.performing_organisation };
  if (b.open_recommendations > 0) return { what: `Accept or challenge ${b.open_recommendations} recommendation${b.open_recommendations === 1 ? "" : "s"}`, who: j.performing_organisation };
  const waitingEvidence = j.holds.filter((h) => h.status === "open" && h.evidence.length === 0).length;
  if (waitingEvidence > 0) return { what: "Provide the external evidence for specialist work", who: j.performing_organisation };
  const forAuthority = [
    b.open_challenges > 0 ? `${b.open_challenges} challenge${b.open_challenges === 1 ? "" : "s"}` : null,
    b.open_holds > 0 ? `external evidence for ${b.open_holds} specialist item${b.open_holds === 1 ? "" : "s"}` : null,
  ].filter(Boolean);
  if (forAuthority.length > 0) return { what: `Decide ${forAuthority.join(" and ")}`, who: "The venue's screening authority" };
  if (b.needs_no_permit_decision) return { what: "Decide whether any permit is needed: screening recommended none", who: "The venue's screening authority" };
  return null;
}

export const day = (iso: string) => new Date(iso).toLocaleDateString("en-GB", { timeZone: "UTC" });
/** The last day of a window whose end is exclusive midnight. */
export const lastDay = (iso: string) => new Date(new Date(iso).getTime() - 1).toLocaleDateString("en-GB", { timeZone: "UTC" });
export const isoDay = (iso: string) => new Date(iso).toISOString().slice(0, 10);
export const isoLastDay = (iso: string) => new Date(new Date(iso).getTime() - 1).toISOString().slice(0, 10);
