"use server";

// Server actions. Each calls one database function as the signed-in user and passes
// its decision back unchanged (D-003): nothing here decides who may do what.

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import type { ActionResult } from "@/components/ActionForm";
import { ConflictError, write } from "@/lib/authz";
import { uploadDocument } from "@/lib/documents";
import { serverEnv } from "@/lib/env";
import { sendMail } from "@/lib/mail";
import { supabaseServer } from "@/lib/supabase/server";

function text(form: FormData, name: string): string {
  return String(form.get(name) ?? "").trim();
}
function optional(form: FormData, name: string): string | null {
  return text(form, name) || null;
}
function safeNext(next: string): string {
  // Only same-site relative paths, never another origin.
  return next.startsWith("/") && !next.startsWith("//") ? next : "/";
}

async function run(fn: string, args: Record<string, unknown>, done: string): Promise<ActionResult> {
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

function failure(e: unknown): ActionResult {
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
  return { ok: false, code: "error", reason: message, missing: "A valid request", resolvable_by: "You, or Octra support" };
}

// ---- Sign-in (6-digit code, works across devices) -----------------------------------

export async function sendCode(_: ActionResult, form: FormData): Promise<ActionResult> {
  const email = text(form, "email").toLowerCase();
  if (!email.includes("@")) {
    return { ok: false, code: "email", reason: "Enter a valid email address.", missing: "Your email address", resolvable_by: "You" };
  }
  const db = await supabaseServer();
  const { error } = await db.auth.signInWithOtp({ email, options: { shouldCreateUser: true } });
  if (error) return failure(error);
  return { ok: true, message: `We have emailed a 6-digit code to ${email}.`, detail: "Enter it below." };
}

export async function verifyCode(_: ActionResult, form: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  const { error } = await db.auth.verifyOtp({ email: text(form, "email").toLowerCase(), token: text(form, "code"), type: "email" });
  if (error) {
    return { ok: false, code: "code", reason: "That code is not valid or has expired.", missing: "A current code", resolvable_by: "You: request a new code" };
  }
  redirect(safeNext(text(form, "next")));
}

export async function signOut() {
  const db = await supabaseServer();
  await db.auth.signOut();
  redirect("/");
}

// ---- Invitations ---------------------------------------------------------------------

export async function inviteOrganisation(_: ActionResult, form: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const email = text(form, "email").toLowerCase();
    const days = Number(text(form, "days"));
    const r = await write(db, "create_organisation_invitation", {
      p_idempotency_key: text(form, "key"),
      p_venue_id: text(form, "venue_id"),
      p_capacity_code: text(form, "capacity"),
      p_invitee_given_name: text(form, "given_name"),
      p_invitee_family_name: text(form, "family_name"),
      p_invitee_email: email,
      p_owner_person_id: text(form, "owner_person_id"),
      p_expires_at: new Date(Date.now() + days * 86_400_000).toISOString(),
      p_engagement_valid_from: new Date(text(form, "from")).toISOString(),
      p_engagement_valid_to: optional(form, "to") ? new Date(text(form, "to")).toISOString() : null,
    });
    if (!r.ok) return r as ActionResult;
    if (r.replayed) return { ok: true, message: "This invitation was already created." };
    return deliver(email, "You have been invited to work at a venue",
      `You have been invited to set up your organisation on Octra Access.\n\nOpen this link to accept:\n${serverEnv().siteUrl}/invitations/${r.token}\n\nThe invitation expires in ${days} days. If you were not expecting it, ignore this email.`);
  } catch (e) {
    return failure(e);
  }
}

export async function invitePerson(_: ActionResult, form: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const email = text(form, "email").toLowerCase();
    const r = await write(db, "create_person_invitation", {
      p_idempotency_key: text(form, "key"),
      p_organisation_id: text(form, "organisation_id"),
      p_relationship_kind: text(form, "kind"),
      p_invitee_given_name: text(form, "given_name"),
      p_invitee_family_name: text(form, "family_name"),
      p_invitee_email: email,
      p_expires_at: new Date(Date.now() + 14 * 86_400_000).toISOString(),
    });
    if (!r.ok) return r as ActionResult;
    if (r.replayed) return { ok: true, message: "This invitation was already created." };
    return deliver(email, "You have been invited to join an organisation",
      `You have been invited to join an organisation on Octra Access.\n\nOpen this link to accept:\n${serverEnv().siteUrl}/invitations/${r.token}\n\nIf you were not expecting it, ignore this email.`);
  } catch (e) {
    return failure(e);
  }
}

async function deliver(to: string, subject: string, body: string): Promise<ActionResult> {
  revalidatePath("/", "layout");
  const sent = await sendMail(to, subject, body);
  return sent.ok
    ? { ok: true, message: `Invitation created and emailed to ${to}.` }
    : { ok: false, code: "delivery_failed", reason: `The invitation was created but the email could not be sent: ${sent.error}`,
        missing: "A delivered email", resolvable_by: "You: cancel it and invite again, or contact Octra support" };
}

export async function acceptInvitation(_: ActionResult, form: FormData): Promise<ActionResult> {
  if (form.get("notice_read") !== "on") {
    return { ok: false, code: "notice", reason: "Please confirm you have read the privacy notice.",
             missing: "Your confirmation", resolvable_by: "You" };
  }
  const db = await supabaseServer();
  try {
    const r = await write(db, "accept_invitation", {
      p_idempotency_key: text(form, "key"),
      p_token: text(form, "token"),
      p_privacy_notice_version_id: text(form, "notice_id"),
      p_legal_name: optional(form, "legal_name"),
      p_trading_name: optional(form, "trading_name"),
      p_company_number: optional(form, "company_number"),
      p_given_name: optional(form, "given_name"),
      p_family_name: optional(form, "family_name"),
      p_relationship_kind: optional(form, "relationship_kind"),
    });
    if (!r.ok) return r as ActionResult;
    if (r.status === "awaiting_match") {
      return { ok: true, message: "Thank you. The venue will confirm your organisation's details before you continue.",
               detail: "You will be able to sign in and carry on once they have." };
    }
  } catch (e) {
    return failure(e);
  }
  redirect("/");
}

export async function declineInvitation(_: ActionResult, form: FormData): Promise<ActionResult> {
  return run("decline_invitation", { p_idempotency_key: text(form, "key"), p_token: text(form, "token") }, "Invitation declined");
}

// ---- Documents and decisions ---------------------------------------------------------

export async function uploadDocumentAction(_: ActionResult, form: FormData): Promise<ActionResult> {
  const file = form.get("file");
  if (!(file instanceof File) || file.size === 0) {
    return { ok: false, code: "file", reason: "Choose a file to upload.", missing: "A file", resolvable_by: "You" };
  }
  const db = await supabaseServer();
  try {
    const r = await uploadDocument(db, {
      bytes: new Uint8Array(await file.arrayBuffer()),
      ownerKind: text(form, "owner_kind") as "organisation" | "person",
      organisationId: optional(form, "organisation_id"),
      personId: optional(form, "person_id"),
      documentTypeId: text(form, "document_type_id"),
      title: text(form, "title") || file.name,
      issuer: optional(form, "issuer") ?? undefined,
      reference: optional(form, "reference") ?? undefined,
      expiresOn: optional(form, "expires_on") ?? undefined,
      idempotencyKey: text(form, "key"),
    });
    if (!r.ok) return r as ActionResult;
    revalidatePath("/", "layout");
    return r.scan_status === "pending"
      ? { ok: true, message: "Uploaded.", detail: "It will be available once the malware check has finished." }
      : { ok: true, message: "Uploaded.", detail: "It is available now. Files are not malware-scanned at present." };
  } catch (e) {
    return failure(e);
  }
}

export async function reviewDocumentAction(_: ActionResult, form: FormData): Promise<ActionResult> {
  const codes = String(form.get("criteria_codes") ?? "").split(",").filter(Boolean);
  const results = Object.fromEntries(codes.map((c) => [c, form.get(`criterion_${c}`) === "on"]));
  return run("review_document", {
    p_idempotency_key: text(form, "key"),
    p_version_id: text(form, "version_id"),
    p_criteria_version_id: text(form, "criteria_version_id"),
    p_outcome: text(form, "outcome"),
    p_criteria_results: results,
    p_scope_wording: text(form, "scope_wording"),
    p_conditions: optional(form, "conditions"),
  }, "Review recorded");
}

export async function approveEngagementAction(_: ActionResult, form: FormData): Promise<ActionResult> {
  return run("approve_engagement", {
    p_idempotency_key: text(form, "key"),
    p_engagement_id: text(form, "engagement_id"),
    p_expected_version: Number(text(form, "row_version")),
  }, "Engagement approved");
}
