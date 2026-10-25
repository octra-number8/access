"use server";

import { redirect } from "next/navigation";
import type { ActionResult } from "@/components/ActionForm";
import { write } from "@/lib/authz";
import { supabaseServer } from "@/lib/supabase/server";

export async function claimLink(_: ActionResult, form: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  const r = await write(db, "claim_induction_link", {
    p_idempotency_key: String(form.get("key")), p_token: String(form.get("token")),
  });
  if (!r.ok) return r as ActionResult;
  redirect(`/learn/${String(r.course_id)}`);
}
