"use server";

// The person's own inbox and their choice for routine notices (Q210, P8-4). Reading a notice
// changes nothing on the record it is about.

import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/components/ActionForm";
import { failure, text } from "@/lib/action-helpers";
import { supabaseServer } from "@/lib/supabase/server";

export async function markRead(_: ActionResult, f: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const { data, error } = await db.rpc("mark_notifications_read", { p_ids: f.getAll("id").map(String) });
    if (error) throw new Error(error.message);
    revalidatePath("/", "layout");
    return { ok: true, message: `${(data as { marked: number }).marked} marked as read.` };
  } catch (e) {
    return failure(e);
  }
}

export async function setPreference(_: ActionResult, f: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const { data, error } = await db.rpc("set_notification_preference", { p_mode: text(f, "mode") });
    if (error) throw new Error(error.message);
    if (!(data as { ok: boolean }).ok) return data as ActionResult;
    revalidatePath("/inbox");
    return { ok: true, message: "Saved." };
  } catch (e) {
    return failure(e);
  }
}
