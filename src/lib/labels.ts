// Plain-English wording for recorded states, shared by every screen that shows them.
// A label says what was recorded, never that someone is competent or safe (CLAUDE.md §1).

export const RELATIONSHIP_KIND: Record<string, string> = {
  employee: "Employee", agency: "Agency worker", self_employed: "Self-employed",
  subcontractor: "Subcontractor", volunteer: "Volunteer", exhibitor: "Exhibitor",
};

export const RELATIONSHIP_STATE: Record<string, string> = {
  invited: "waiting for the person to accept",
  active: "accepted",
  declined: "declined by the person",
  ended: "ended",
};

export const VERIFY_METHOD: Record<string, string> = {
  issuer_register: "the issuer's register",
  original_seen: "the original card or certificate, seen in person",
  issuer_confirmation: "confirmation from the issuer",
};

export interface Verification {
  method: string; source_checked: string; holder_match: boolean; scope: string;
  valid_until: string | null; outcome: string; created_at: string;
}

/** What a verification records: a check against a source for a scope, not a certificate of competence. */
export function verificationText(v: Verification | undefined): string {
  if (!v) return "Not checked by the venue";
  const when = new Date(v.created_at).toLocaleDateString("en-GB");
  const until = v.valid_until ? `, recorded as valid until ${new Date(v.valid_until).toLocaleDateString("en-GB")}` : "";
  return v.outcome === "verified"
    ? `Checked against ${VERIFY_METHOD[v.method] ?? v.method} on ${when} for: ${v.scope}${until}`
    : `Checked on ${when} and could not be confirmed (${VERIFY_METHOD[v.method] ?? v.method})`;
}

export const date = (d: string | null | undefined) => (d ? new Date(d).toLocaleDateString("en-GB") : "—");
