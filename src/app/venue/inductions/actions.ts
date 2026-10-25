"use server";

// Induction authoring, review, links and facilitation. Each action calls one database
// function as the signed-in user and returns its decision unchanged (D-003).

import { createHash, randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import type { ActionResult } from "@/components/ActionForm";
import { failure } from "@/lib/action-helpers";
import { write } from "@/lib/authz";
import type { CourseContent } from "@/lib/induction/content";
import { fromInductStarter, parseBrief } from "@/lib/induction/import";
import { maxInductionMediaBytes, sniffInductionMedia } from "@/lib/induction/media";
import { serverEnv } from "@/lib/env";
import { sendMail } from "@/lib/mail";
import { inductionMediaBucket } from "@/lib/supabase/storage";
import { supabaseServer } from "@/lib/supabase/server";

const t = (f: FormData, n: string) => String(f.get(n) ?? "").trim();
const opt = (f: FormData, n: string) => t(f, n) || null;

/** Problems from the database (content checks, readiness) are listed under the reason. */
function withProblems(r: { ok: false; reason: string; problems?: string[] } & Record<string, unknown>): ActionResult {
  const problems = Array.isArray(r.problems) ? ` ${r.problems.join(" ")}` : "";
  return { ...(r as object), reason: `${r.reason}${problems}` } as ActionResult;
}

async function run(fn: string, args: Record<string, unknown>, done: string): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const r = await write(db, fn, args as Record<string, unknown> & { p_idempotency_key: string });
    if (!r.ok) return withProblems(r as never);
    revalidatePath("/", "layout");
    return { ok: true, message: r.replayed ? `${done} (already done).` : `${done}.` };
  } catch (e) {
    return failure(e);
  }
}

async function versionRow(versionId: string) {
  const db = await supabaseServer();
  const { data } = await db.from("course_version").select("row_version").eq("id", versionId).single();
  return data?.row_version as number;
}

async function content(versionId: string): Promise<CourseContent> {
  const db = await supabaseServer();
  const { data } = await db.rpc("course_content", { p_version_id: versionId });
  if (!data?.ok) throw new Error("This induction could not be read.");
  return data.content as CourseContent;
}

async function save(versionId: string, next: CourseContent, key: string, done: string, sourceRef?: string): Promise<ActionResult> {
  return run("save_course_draft", {
    p_idempotency_key: key, p_version_id: versionId, p_expected_version: await versionRow(versionId),
    p_content: next, p_source_ref: sourceRef ?? null,
  }, done);
}

export async function createCourse(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_induction_course", {
    p_idempotency_key: t(f, "key"), p_venue_id: t(f, "venue_id"), p_code: t(f, "code").toUpperCase(),
    p_title: t(f, "title"), p_audience: opt(f, "audience"), p_event_id: opt(f, "event_id"),
  }, "Course created");
}

export async function createDraft(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("create_course_draft", { p_idempotency_key: t(f, "key"), p_course_id: t(f, "course_id"), p_language: "en-GB" },
    "Draft started");
}

/** Imports a brief (.md) or an OCTRA Induct starter (.json) into the draft (D-015). */
export async function importContent(_: ActionResult, f: FormData): Promise<ActionResult> {
  const file = f.get("file");
  if (!(file instanceof File) || file.size === 0 || file.size > 2 * 1024 * 1024) {
    return { ok: false, code: "file", reason: "Choose the brief (.md) or starter template (.json), up to 2 MB.", missing: "A file", resolvable_by: "You" };
  }
  try {
    const text = await file.text();
    const parsed = file.name.toLowerCase().endsWith(".json") ? fromInductStarter(JSON.parse(text)) : parseBrief(text);
    const versionId = t(f, "version_id");
    const saved = await save(versionId, parsed.content, t(f, "key"), "Imported", file.name);
    if (!saved || saved.ok === false) return saved;
    const db = await supabaseServer();
    for (const op of parsed.openPoints) {
      const r = await write(db, "add_open_point", { p_idempotency_key: randomUUID(), p_version_id: versionId, p_text: op.text, p_owner_text: op.owner });
      if (!r.ok) return r as ActionResult;
    }
    revalidatePath("/", "layout");
    return {
      ok: true,
      message: `Imported ${parsed.content.modules.length} sections, ${parsed.content.questions.length} questions and ${parsed.content.declaration.length} declaration items as a draft.`,
      detail: [`${parsed.openPoints.length} open points to resolve before review.`, ...parsed.notes].join(" "),
    };
  } catch (e) {
    return failure(e);
  }
}

/** Uploads a file for one block (image, video, captions, document) and attaches it. */
export async function attachMedia(_: ActionResult, f: FormData): Promise<ActionResult> {
  const file = f.get("file");
  if (!(file instanceof File) || file.size === 0) {
    return { ok: false, code: "file", reason: "Choose a file.", missing: "A file", resolvable_by: "You" };
  }
  const bytes = new Uint8Array(await file.arrayBuffer());
  const type = sniffInductionMedia(bytes);
  if (!type || bytes.length > maxInductionMediaBytes(type)) {
    return { ok: false, code: "file_type", reason: "Use a JPEG, PNG, PDF, WebVTT captions file (up to 20 MB) or MP4 video (up to 200 MB), checked by its content.", missing: "A suitable file", resolvable_by: "You" };
  }
  try {
    const versionId = t(f, "version_id");
    const mediaId = randomUUID();
    const db = await supabaseServer();
    const reg = await write(db, "register_induction_media", {
      p_idempotency_key: t(f, "key"), p_venue_id: t(f, "venue_id"), p_media_id: mediaId,
      p_sha256_hex: createHash("sha256").update(bytes).digest("hex"), p_media_type: type, p_size_bytes: bytes.length,
      p_original_name: file.name,
    });
    if (!reg.ok) return reg as ActionResult;
    const stored = await inductionMediaBucket().upload(String(reg.storage_path), bytes, { contentType: type, upsert: false });
    if (stored.error) return { ok: false, code: "storage_failed", reason: "The file could not be stored. Please try again.", missing: "A successful upload", resolvable_by: "You" };
    const c = await content(versionId);
    const block = c.modules.find((m) => m.key === t(f, "module_key"))?.blocks[Number(t(f, "block_index"))] as Record<string, unknown> | undefined;
    if (!block) return { ok: false, code: "block", reason: "That block no longer exists.", missing: "The block", resolvable_by: "You: refresh" };
    block[t(f, "field") === "caption_media_id" ? "caption_media_id" : "media_id"] = mediaId;
    return save(versionId, c, randomUUID(), "File attached");
  } catch (e) {
    return failure(e);
  }
}

/** Sets what imports never decide: reading times, module kinds, safety-critical questions. */
export async function saveStructure(_: ActionResult, f: FormData): Promise<ActionResult> {
  try {
    const versionId = t(f, "version_id");
    const c = await content(versionId);
    for (const m of c.modules) {
      const s = Number(t(f, `min_${m.key}`));
      if (!Number.isInteger(s) || s < 0) return { ok: false, code: "min", reason: `Enter a reading time in whole seconds for "${m.title}".`, missing: "A reading time", resolvable_by: "You" };
      m.min_seconds = s;
      const kind = t(f, `kind_${m.key}`);
      if (["core", "role", "area", "event_phase"].includes(kind)) m.kind = kind as typeof m.kind;
    }
    for (const q of c.questions) q.safety_critical = f.get(`critical_${q.key}`) === "on";
    return save(versionId, c, t(f, "key"), "Reading times and safety-critical questions saved");
  } catch (e) {
    return failure(e);
  }
}

export async function saveSettings(_: ActionResult, f: FormData): Promise<ActionResult> {
  const num = (n: string) => (t(f, n) === "" ? null : Number(t(f, n)));
  const bool = (n: string) => (t(f, n) === "" ? null : t(f, n) === "yes");
  const mode = opt(f, "validity_mode");
  return run("set_course_settings", {
    p_idempotency_key: t(f, "key"), p_version_id: t(f, "version_id"), p_expected_version: await versionRow(t(f, "version_id")),
    p_pass_mark_percent: num("pass_mark"), p_all_critical_required: bool("all_critical"), p_max_attempts: num("max_attempts"),
    p_retry_delay_minutes: num("retry_delay"), p_shuffle_options: bool("shuffle"), p_validity_mode: mode,
    p_validity_days: mode === "days_from_completion" ? num("validity_days") : null,
    p_validity_until: mode === "fixed_date" && t(f, "validity_until") ? new Date(`${t(f, "validity_until")}T23:59:59`).toISOString() : null,
    p_signature_mode: opt(f, "signature_mode"),
  }, "Settings saved");
}

export async function resolveOpenPoint(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("resolve_open_point", {
    p_idempotency_key: t(f, "key"), p_open_point_id: t(f, "open_point_id"), p_expected_version: Number(t(f, "row_version")),
    p_resolution: t(f, "resolution"),
  }, "Open point resolved");
}

export async function submitVersion(_: ActionResult, f: FormData): Promise<ActionResult> {
  return run("submit_course_version", {
    p_idempotency_key: t(f, "key"), p_version_id: t(f, "version_id"), p_expected_version: await versionRow(t(f, "version_id")),
  }, "Submitted for review by the H&S authority");
}

export async function decideVersion(_: ActionResult, f: FormData): Promise<ActionResult> {
  const decision = t(f, "decision");
  return run("decide_course_version", {
    p_idempotency_key: t(f, "key"), p_version_id: t(f, "version_id"), p_expected_version: await versionRow(t(f, "version_id")),
    p_decision: decision, p_reason: opt(f, "reason"), p_acting_appointment_id: null,
  }, decision === "publish" ? "Published" : "Returned to the author");
}

/** Sends one person a personal induction link (P3-2). */
export async function sendLink(_: ActionResult, f: FormData): Promise<ActionResult> {
  const db = await supabaseServer();
  try {
    const days = Number(t(f, "days"));
    const r = await write(db, "issue_induction_link", {
      p_idempotency_key: t(f, "key"), p_course_id: t(f, "course_id"), p_person_id: t(f, "person_id"),
      p_expires_at: new Date(Date.now() + days * 86_400_000).toISOString(), p_via_organisation_id: opt(f, "organisation_id"),
    });
    if (!r.ok) return r as ActionResult;
    if (r.replayed) return { ok: true, message: "This link was already sent." };
    revalidatePath("/", "layout");
    const sent = await sendMail(String(r.email), "Your site induction",
      `Please complete your site induction before you arrive.\n\nOpen this link and sign in with this email address:\n${serverEnv().siteUrl}/induction/${r.token}\n\nThe link expires in ${days} days.`);
    return sent.ok
      ? { ok: true, message: `Induction link emailed to ${r.email}.` }
      : { ok: false, code: "delivery_failed", reason: `The link was created but the email could not be sent: ${sent.error}`, missing: "A delivered email", resolvable_by: "You: revoke it and send another" };
  } catch (e) {
    return failure(e);
  }
}

export async function recordFacilitated(_: ActionResult, f: FormData): Promise<ActionResult> {
  if (f.get("acknowledged") !== "on") {
    return { ok: false, code: "ack", reason: "The person must acknowledge the briefing and the declaration.", missing: "Their acknowledgement", resolvable_by: "You, with the person" };
  }
  return run("record_facilitated_completion", {
    p_idempotency_key: t(f, "key"), p_version_id: t(f, "version_id"), p_person_id: t(f, "person_id"), p_method: t(f, "method"),
    p_identity_check: t(f, "identity_check"), p_understanding_check: t(f, "understanding_check"), p_learner_acknowledged: true,
    p_acting_appointment_id: null,
  }, "Completion recorded");
}
