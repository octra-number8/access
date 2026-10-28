// Retention categories (phase 8d, §16.2). Their names, triggers and methods come from the
// database (core.retention_categories); this list only names the form fields.
export const RETENTION_CATEGORIES = [
  "gate_scans", "gate_outage", "visits", "inductions", "notifications", "document_files", "rejected_uploads",
] as const;

export interface RetentionCategory {
  code: string; name: string; trigger: string; method: string; never_while: string;
  rule: { days: number; basis: string } | null;
}

export interface DisposalBatch {
  id: string; reference: string; category: string; status: "proposed" | "confirmed" | "declined"; listed_count: number;
  period_days: number; listed_at: string; row_version: number; rule_version: number; rule_approver_person_id: string;
  held_back: Array<{ hold_id: string; reference: string; matter: string; count: number }>;
  decided_by: string | null; decided_at: string | null; decision_reason: string | null; disposed_count: number | null; kept_count: number | null;
  items: Array<{ label: string | null; trigger_at: string; kept_reason?: string | null }>;
}

export const HOLD_STATE: Record<string, string> = {
  requested: "Requested, awaiting a decision", active: "In force", refused: "Refused", lifted: "Lifted",
};
