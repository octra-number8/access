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
