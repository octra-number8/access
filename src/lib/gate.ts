// The gate's result as the database returns it (core.entry_evaluation, D-020), and its words.
// Outcomes are words; colour, where used, only repeats them (CLAUDE.md §2).

export type Outcome = "admit" | "admit_with_escort" | "check" | "do_not_admit";

export interface EntryReason {
  code: string;
  severity: "check" | "do_not_admit";
  words: string;
  owner: string;
  overridable: boolean;
  overridden_by?: string;
}

export interface EntryResult {
  outcome: Outcome;
  person: { id: string; name: string } | null;
  organisation?: string | null;
  audience?: string | null;
  visit?: { id: string; reference: string; purpose: string; allows: string; prohibits: string;
            conditions: { escort?: string | null; no_photography?: boolean; confidentiality?: boolean; other?: string | null } } | null;
  areas?: string[];
  escort?: "never" | "always";
  inductions?: Array<{ course: string; valid_until: string | null }>;
  reasons: EntryReason[];
  overrides: Array<{ id: string; reasons: string[]; until: string; escort: string | null; purpose: string; by: string }>;
  notices: string[];
  entry_only?: string;
}

export const OUTCOME_WORDS: Record<Outcome, string> = {
  admit: "Admit",
  admit_with_escort: "Admit with escort",
  check: "Check",
  do_not_admit: "Do not admit",
};

/** The headline: "Check with [owner]" names who to check with (CLAUDE.md §2). */
export function outcomeHeadline(r: Pick<EntryResult, "outcome" | "reasons">): string {
  if (r.outcome !== "check") return OUTCOME_WORDS[r.outcome];
  const owner = r.reasons.find((x) => x.severity === "check" && !x.overridden_by)?.owner;
  // The operator's own checks (an unverified code) are not someone to check with.
  if (!owner || owner.startsWith("The operator")) return "Check";
  return `Check with ${owner.charAt(0).toLowerCase()}${owner.slice(1)}`;
}

export const IDENTITY_WORDS: Record<string, string> = {
  photo_id: "Photo ID seen",
  known_to_operator: "Known to me",
  not_checked: "Not checked",
};

export const ACTION_WORDS: Record<string, string> = {
  admitted: "Let through",
  refused: "Refused",
  referred: "Referred to an access authority",
};

/** The reasons a gate override may name (core.entry_reason_overridable), in words. */
export const OVERRIDABLE_WORDS: Record<string, string> = {
  no_reason: "No current engagement or visit",
  induction_missing: "Induction missing",
  no_rule: "No entry rule for the role",
};

export function inductionLine(i: { course: string; valid_until: string | null }, tz: string): string {
  if (!i.valid_until) return `${i.course}: not completed`;
  const until = new Date(i.valid_until);
  const d = until.toLocaleDateString("en-GB", { timeZone: tz });
  return until.getTime() < Date.now() ? `${i.course}: expired ${d}` : `${i.course}: valid until ${d}`;
}

// ---- Access visits (Q120–Q126) ---------------------------------------------------------------------
export interface Purpose {
  key: string; name: string; allows: string; prohibits: string;
  induction_course_ids: string[]; escort: "never" | "always"; occupier_consent: boolean;
}

export const VISIT_STATE: Record<string, string> = {
  requested: "Waiting for a decision",
  approved: "Approved",
  refused: "Refused",
  withdrawn: "Withdrawn",
  cancelled: "Cancelled",
};

/** "Approved" says a decision was recorded; once the window has passed, say so too. */
export function visitState(status: string, endsAt: string): string {
  if (status === "approved" && new Date(endsAt).getTime() < Date.now()) return "Approved (ended)";
  return VISIT_STATE[status] ?? status;
}
