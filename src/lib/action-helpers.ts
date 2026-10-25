import "server-only";

// Helpers shared by the server action files. Each action calls one database function as
// the signed-in user and passes its decision back unchanged (D-003).

import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/components/ActionForm";
import { ConflictError, write } from "@/lib/authz";
import { supabaseServer } from "@/lib/supabase/server";

export function text(form: FormData, name: string): string {
  return String(form.get(name) ?? "").trim();
}
export function optional(form: FormData, name: string): string | null {
  return text(form, name) || null;
}
export function safeNext(next: string): string {
  // Only same-site relative paths, never another origin.
  return next.startsWith("/") && !next.startsWith("//") ? next : "/";
}

export async function run(fn: string, args: Record<string, unknown>, done: string): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const r = await write(db, fn, args as Record<string, unknown> & { p_idempotency_key: string });
    if (!r.ok) return r as ActionResult;
    revalidatePath("/", "layout");
    return { ok: true, message: r.replayed ? `${done} (already done).` : `${done}.` };
  } catch (e) {
    return failure(e);
  }
}

export function failure(e: unknown): ActionResult {
  if (e instanceof ConflictError) {
    return { ok: false, code: "conflict", reason: "This record changed since you opened it.",
             missing: "The latest version of the page", resolvable_by: "You: refresh and try again" };
  }
  const message = (e as Error).message ?? "";
  // Never show raw database errors (internal names, constraint text). Messages the
  // database functions raise deliberately are written for people and pass through.
  if (/violates|constraint|relation "|column "|syntax|permission denied|function .* does not exist/i.test(message)) {
    console.error("refused by a data rule:", message);
    return { ok: false, code: "data_rule", reason: "This was refused by one of the system's data rules.",
             missing: "A request that meets the rules", resolvable_by: "You, or Octra support if it keeps happening" };
  }
  // Database functions raise short lower-case sentences; show them as sentences.
  const reason = message ? message.charAt(0).toUpperCase() + message.slice(1) + (/[.!?]$/.test(message) ? "" : ".") : "Something went wrong.";
  return { ok: false, code: "error", reason, missing: "A request that meets this rule", resolvable_by: "You, or Octra support" };
}
