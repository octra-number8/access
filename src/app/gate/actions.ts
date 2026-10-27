"use server";

// The gate (phase 7c, D-020). Each action calls one database function as the signed-in
// operator; the database evaluates entry and decides who may act. Nothing here is cached:
// every scan is a fresh evaluation against the live record (invariant 11).

import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/components/ActionForm";
import type { Denial } from "@/components/Blocked";
import { failure, optional, run, text } from "@/lib/action-helpers";
import { write } from "@/lib/authz";
import type { EntryResult } from "@/lib/gate";
import { fromVenueLocal } from "@/lib/permits";
import { supabaseServer } from "@/lib/supabase/server";

export type ScanOutcome =
  | { ok: true; evaluationId: string; result: EntryResult; pass: { number: string; kind: string } | null; evaluatedAt: string; holders: string[] }
  | Denial;

/** A scanned code ("OCTRA1:…") or a typed pass number. */
export async function scanPass(gatePointId: string, input: string, key: string): Promise<ScanOutcome> {
  const value = input.trim();
  if (!value) return { ok: false, code: "invalid_content", reason: "Scan a pass or type its number.", missing: "A pass", resolvable_by: "The operator" };
  const db = await supabaseServer();
  try {
    const r = value.toUpperCase().startsWith("OCTRA1:")
      ? await write(db, "scan_entry", { p_idempotency_key: key, p_gate_point_id: gatePointId, p_payload: value })
      : await write(db, "lookup_entry", { p_idempotency_key: key, p_gate_point_id: gatePointId, p_pass_number: value });
    if (!r.ok) return r as Denial;
    const x = r as unknown as { evaluation_id: string; result: EntryResult; pass: { number: string; kind: string } | null };
    const needsAuthority = x.result.reasons.some((reason) => reason.overridable && !reason.overridden_by);
    const holders = needsAuthority ? (((await db.rpc("gate_override_holders", { p_gate_point_id: gatePointId })).data as string[] | null) ?? []) : [];
    return { ok: true, evaluationId: x.evaluation_id, result: x.result, pass: x.pass, evaluatedAt: new Date().toISOString(), holders };
  } catch (e) {
    return failure(e) as Denial;
  }
}

export async function recordGateAction(_: ActionResult, f: FormData): Promise<ActionResult> {
  const action = text(f, "action");
  const r = await run("record_gate_action", {
    p_idempotency_key: text(f, "key"), p_evaluation_id: text(f, "evaluation_id"), p_direction: text(f, "direction"),
    p_identity_method: text(f, "identity"), p_action: action, p_note: optional(f, "note"), p_escort_name: optional(f, "escort"),
  }, action === "admitted" ? "Recorded: let through" : action === "refused" ? "Recorded: refused" : "Recorded: referred to an access authority");
  return r;
}

export async function overrideEntry(_: ActionResult, f: FormData): Promise<ActionResult> {
  const until = text(f, "until");
  const r = await run("override_entry", {
    p_idempotency_key: text(f, "key"), p_person_id: text(f, "person_id"), p_gate_point_id: text(f, "gate_point_id"),
    p_reason_codes: f.getAll("reason_codes").map(String), p_purpose: text(f, "purpose"), p_reason: text(f, "reason"),
    p_valid_to: until ? fromVenueLocal(until, text(f, "tz")) : null, p_escort: optional(f, "escort"),
  }, "Override recorded. The operator scans the pass again for a new result");
  revalidatePath("/gate");
  return r;
}

// ---- Offline (Q198–Q203, phase 7d) -------------------------------------------------------------
export interface ManifestEntry {
  person_id: string; name: string; organisation: string | null; pass_numbers: string[]; outcome: EntryResult["outcome"];
  audience: string | null; areas: string[]; escort: string; reasons: Array<{ words: string; owner: string }>; notices: string[];
}
export interface Manifest {
  manifest_id: string; made_at: string; max_age_minutes: number; gate_point: string; venue: string; timezone: string;
  instruction: string; steps: string[]; entries: ManifestEntry[];
}
export interface FallbackEntry {
  client_entry_id: string; recorded_at: string; person_id?: string; pass_number?: string; name_given: string; organisation_given?: string;
  purpose: string; contacted: string; direction: "in" | "out"; identity_method: string; decision: string; notes?: string;
}
export type Uploaded = { ok: true; added: number; already_uploaded: number; exceptions: Array<{ code: string; words: string; owner: string }> } | Denial;

/** A read-only snapshot for look-up during an outage. Never current authorisation (invariant 11). */
export async function downloadManifest(gatePointId: string, key: string): Promise<({ ok: true } & Manifest) | Denial> {
  const db = await supabaseServer();
  try {
    const r = await write(db, "download_manifest", { p_idempotency_key: key, p_gate_point_id: gatePointId });
    return r as unknown as ({ ok: true } & Manifest) | Denial;
  } catch (e) {
    return failure(e) as Denial;
  }
}

export async function uploadFallback(gatePointId: string, manifestId: string | null, entries: FallbackEntry[], key: string): Promise<Uploaded> {
  const db = await supabaseServer();
  try {
    const r = await write(db, "submit_fallback_entries", { p_idempotency_key: key, p_gate_point_id: gatePointId, p_manifest_id: manifestId, p_entries: entries });
    if (!r.ok) {
      const problems = (r as unknown as { problems?: string[] }).problems;
      return { ...(r as Denial), reason: problems?.length ? `${r.reason} ${problems.join(" ")}` : r.reason };
    }
    revalidatePath("/gate/reconcile");
    return r as unknown as Uploaded;
  } catch (e) {
    return failure(e) as Denial;
  }
}

/** Whether Octra can be reached now. */
export async function ping(): Promise<boolean> {
  return true;
}

export async function resolveException(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("resolve_reconciliation_exception", { p_idempotency_key: text(f, "key"), p_exception_id: text(f, "id"), p_note: text(f, "note") },
    "Resolved, with your note");
}
