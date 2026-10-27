"use server";

// A person's own pass (P7-3). The code is computed in the database from a secret that never
// leaves it; this only fetches the current one for the signed-in person.

import type { ActionResult } from "@/components/ActionForm";
import { run, text } from "@/lib/action-helpers";
import { supabaseServer } from "@/lib/supabase/server";

export type PhoneCode = { ok: true; pass_number: string; payload: string; seconds_left: number } | { ok: false; reason: string };

export async function phoneCode(venueId: string): Promise<PhoneCode> {
  const db = await supabaseServer();
  const { data, error } = await db.rpc("phone_pass_code", { p_venue_id: venueId });
  if (error || !data) return { ok: false, reason: "The code could not be fetched." };
  return data as PhoneCode;
}

export async function createPhonePass(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_phone_pass", { p_idempotency_key: text(f, "key"), p_venue_id: text(f, "venue_id") }, "Your phone pass is ready");
}
