import "server-only";
import { createHash, randomUUID } from "node:crypto";
import { write, type WriteResult } from "./authz";
import { MAX_UPLOAD_BYTES, sniff } from "./filetype";
import type { Db } from "./supabase/server";
import { documentsBucket } from "./supabase/storage";

export interface UploadInput {
  bytes: Uint8Array;
  ownerKind: "organisation" | "person";
  organisationId: string | null;
  personId: string | null;
  documentTypeId: string;
  title: string;
  documentId?: string;
  issuer?: string;
  reference?: string;
  expiresOn?: string;
  idempotencyKey: string;
}

type Refusal = { ok: false; code: string; reason: string; missing: string; resolvable_by: string };

/**
 * Registers the file with the database (which decides whether this user may submit
 * it), then stores it. The file stays unreleasable until the scanner marks it clean.
 */
export async function uploadDocument(db: Db, input: UploadInput): Promise<WriteResult | Refusal> {
  if (input.bytes.length === 0 || input.bytes.length > MAX_UPLOAD_BYTES) {
    return refusal("file_size", "Files must be between 1 byte and 20 MB.", "A smaller file");
  }
  const mediaType = sniff(input.bytes);
  if (!mediaType) {
    return refusal("file_type", "Only PDF, JPEG and PNG files are accepted, checked by their content.", "A PDF, JPEG or PNG file");
  }
  const result = await write(db, "submit_document", {
    p_idempotency_key: input.idempotencyKey,
    p_document_id: input.documentId ?? randomUUID(),
    p_version_id: randomUUID(),
    p_owner_kind: input.ownerKind,
    p_organisation_id: input.organisationId,
    p_person_id: input.personId,
    p_document_type_id: input.documentTypeId,
    p_title: input.title,
    p_sha256_hex: createHash("sha256").update(input.bytes).digest("hex"),
    p_media_type: mediaType,
    p_size_bytes: input.bytes.length,
    p_issuer: input.issuer ?? null,
    p_reference: input.reference ?? null,
    p_valid_from: null,
    p_expires_on: input.expiresOn || null,
  });
  if (!result.ok || result.replayed) return result;
  const stored = await documentsBucket().upload(String(result.storage_path), input.bytes, {
    contentType: mediaType,
    upsert: false,
  });
  if (stored.error) {
    // The version stays pending; the scanner gives up on a missing file as rejected.
    return refusal("storage_failed", "The file could not be stored. Please try again.", "A successful upload");
  }
  return result;
}

/** A 60-second download link, only after the database has authorised and audited it. */
export async function downloadLink(db: Db, versionId: string): Promise<{ ok: true; url: string } | Refusal> {
  const { data, error } = await db.rpc("document_access", { p_version_id: versionId });
  if (error) throw new Error(error.message);
  if (!data.ok) return data as Refusal;
  const signed = await documentsBucket().createSignedUrl(data.storage_path, 60, { download: true });
  if (signed.error) return refusal("storage_failed", "The file could not be retrieved.", "Try again shortly");
  return { ok: true, url: signed.data.signedUrl };
}

function refusal(code: string, reason: string, missing: string): Refusal {
  return { ok: false, code, reason, missing, resolvable_by: "You" };
}
