// Every blocked action states what is unavailable, why, what is missing and who can
// resolve it (CLAUDE.md §6). The wording comes from the database's decision.
export interface Denial {
  ok: false;
  code: string;
  reason: string;
  missing: string;
  resolvable_by: string;
  evidence?: EvidenceLine[];
  /** Each thing still in the way, in words (for example what still depends on an area). */
  problems?: string[];
}

export interface EvidenceLine {
  code: string;
  label: string;
  state: string;
  blocking: boolean;
  expires_on: string | null;
  resolvable_by: string | null;
}

export function Blocked({ what, denial }: { what: string; denial: Denial }) {
  return (
    <div className="notice notice-blocked" role="alert">
      <p className="notice-title">{what} is not available</p>
      <dl>
        <dt>Why</dt>
        <dd>{denial.reason}</dd>
        <dt>What is missing</dt>
        <dd>{denial.missing}</dd>
        <dt>Who can resolve it</dt>
        <dd>{denial.resolvable_by}</dd>
      </dl>
      {denial.problems?.length ? <ul>{denial.problems.map((p) => <li key={p}>{p}</li>)}</ul> : null}
      {denial.evidence ?<EvidenceList lines={denial.evidence} /> : null}
    </div>
  );
}

const STATE_TEXT: Record<string, string> = {
  satisfied: "In place for these dates",
  expires_within_window: "In place, but expires during these dates",
  missing: "Not submitted",
  scan_pending: "Being checked for malware",
  not_reviewed: "Waiting for review",
  more_information_required: "Returned for more information",
  not_accepted: "Not accepted",
  expired: "Expired before these dates",
  not_verified: "Not verified",
};

// A status records a decision; it is never a safety rating (D-005).
export function EvidenceList({ lines }: { lines: EvidenceLine[] }) {
  if (lines.length === 0) return <p className="muted">No evidence is required for this decision.</p>;
  return (
    <table className="evidence">
      <thead>
        <tr><th scope="col">Requirement</th><th scope="col">Recorded state</th><th scope="col">Who can resolve it</th></tr>
      </thead>
      <tbody>
        {lines.map((l) => (
          <tr key={l.code}>
            <td>{l.label}</td>
            <td>
              {STATE_TEXT[l.state] ?? l.state}
              {l.expires_on ? ` (${l.expires_on})` : ""}
              {l.blocking ? <span className="tag">Blocks this decision</span> : null}
            </td>
            <td>{l.resolvable_by ?? "—"}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
