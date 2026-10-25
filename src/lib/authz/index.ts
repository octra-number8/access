// Thin client for the single authorisation service (D-003).
//
// Every decision is made in Postgres by authz.evaluate / authz.require. This module
// never decides anything: it calls the database, passes the result through
// unchanged, and gives denials the shape the interface needs (CLAUDE.md §6).

import type { AuthorityAction } from "./actions";

export type { AuthorityAction } from "./actions";
export { AUTHORITY_ACTIONS } from "./actions";

/** The scope a decision is about. Mirrors the jsonb target accepted by authz.evaluate. */
export interface AuthzTarget {
  customer_id: string;
  venue_id?: string;
  area_id?: string;
  system_id?: string;
  permit_class_id?: string;
  record_id: string;
  target_type: string;
  subject_person_id?: string;
  excluded_person_ids?: string[];
  owner_appointment_id?: string;
}

export interface Capacity {
  appointmentId?: string;
  delegationId?: string;
}

export interface AuthzAllowed {
  ok: true;
  allowed: true;
  action: AuthorityAction;
  basis:
    | "appointment" | "tenant_admin" | "platform_admin" | "subject"
    | "organisation_admin" | "invitee" | "service" | "link_holder";
  actor_kind: "user" | "tenant_admin" | "platform_admin" | "organisation_admin" | "service";
  actor_person_id?: string;
  acting_appointment_id?: string | null;
  acting_delegation_id?: string | null;
}

// Refusal codes come from the database. Known ones are listed for convenience; the set
// grows with each phase, so any string is accepted.
export type DenialCode =
  | "unknown_action" | "not_authenticated" | "not_platform_admin" | "not_found"
  | "separation_of_duties" | "not_tenant_admin" | "not_subject" | "not_organisation_admin"
  | "capacity_not_valid" | "capacity_selection_required" | "no_covering_appointment"
  | "idempotency_key_reused" | "evidence_incomplete" | "person_restricted" | "organisation_restricted"
  | "link_expired" | "link_revoked" | "link_wrong_account" | "invalid_content" | "not_ready"
  | "retry_not_yet" | "assisted_review_required" | "too_soon"
  | "no_screening" | "engagement_not_active" | "answers_incomplete" | "not_draft" | "not_open"
  | "has_recommendations" | "no_change" | "not_proposed"
  | (string & {});

export interface AuthzDenied {
  ok: false;
  allowed: false;
  action: string;
  code: DenialCode;
  reason: string;
  missing: string;
  resolvable_by: string;
  options?: Array<{ appointment_id?: string; delegation_id?: string }>;
}

export type AuthzResult = AuthzAllowed | AuthzDenied;

/** Result of a write RPC. */
export type WriteResult =
  | { ok: true; id: string; decision_context_id: string; replayed: boolean; [extra: string]: unknown }
  | AuthzDenied;

/** The four things every blocked action must state (CLAUDE.md §6). */
export interface BlockedExplanation {
  unavailable: string;
  why: string;
  missing: string;
  whoCanResolve: string;
}

/** Raised when a decision was made against a record that has since changed (PT409). */
export class ConflictError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConflictError";
  }
}

/** The subset of a Supabase client this module needs. */
export interface RpcClient {
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{
    data: unknown;
    error: { code?: string; message: string } | null;
  }>;
}

export function isDenied(result: AuthzResult | WriteResult): result is AuthzDenied {
  return result.ok === false;
}

export function explain(denied: AuthzDenied, unavailable: string): BlockedExplanation {
  return {
    unavailable,
    why: denied.reason,
    missing: denied.missing,
    whoCanResolve: denied.resolvable_by,
  };
}

/** A fresh key per user intent (one form submission), reused on retry of that intent. */
export function newIdempotencyKey(): string {
  return crypto.randomUUID();
}

/** May the signed-in user take this action now, and in which capacity? */
export async function check(
  client: RpcClient,
  action: AuthorityAction,
  target: AuthzTarget,
  capacity: Capacity = {},
): Promise<AuthzResult> {
  const { data, error } = await client.rpc("check", {
    p_action: action,
    p_target: target,
    p_acting_appointment_id: capacity.appointmentId ?? null,
    p_acting_delegation_id: capacity.delegationId ?? null,
  });
  if (error) throw new Error(error.message);
  return data as AuthzResult;
}

/** Calls a write RPC. Denials come back as values; conflicts are thrown. */
export async function write(
  client: RpcClient,
  fn: string,
  args: Record<string, unknown> & { p_idempotency_key: string },
): Promise<WriteResult> {
  const { data, error } = await client.rpc(fn, args);
  if (error) {
    if (error.code === "PT409") throw new ConflictError(error.message);
    throw new Error(error.message);
  }
  return data as WriteResult;
}
