import "server-only";

// The pack builder (P8-8, P8-10). It runs as the job runner's service account, which holds the
// pack_builder purpose: it claims packs that an evidence.export appointee has requested, reads
// the evidence files the database names, checks each against its recorded SHA-256, builds the
// PDF and ZIP from the frozen content, stores the ZIP privately and records its files' hashes.
// The database refuses a record whose files are not the ones the pack names. Nothing here
// decides what a pack contains or who may have it.

import { readFile } from "node:fs/promises";
import path from "node:path";
import type { SupabaseClient } from "@supabase/supabase-js";
import { assemblePack, type PackContent, renderPackPdf, sha256Hex } from "./pack-format";
import { documentsBucket, packsBucket } from "./supabase/storage";

interface Claimed {
  id: string; reference: string; customer_id: string; content_text: string;
  files: Array<{ version_id: string; storage_path: string; sha256: string; media_type: string; name_in_pack: string }>;
}

// Geist, as shipped inside Next.js: Latin (with accents), Greek and Cyrillic. Characters it
// lacks are drawn as "?" in the PDF; pack.json always holds the exact text.
const FONT = path.join(process.cwd(), "node_modules", "next", "dist", "compiled", "@vercel", "og", "Geist-Regular.ttf");

async function rpc(db: SupabaseClient, fn: string, args: Record<string, unknown> = {}) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  if (data && data.allowed === false) throw new Error(`${fn}: ${data.reason ?? "refused"}`);
  return data;
}

async function buildOne(db: SupabaseClient, p: Claimed, font: Uint8Array): Promise<void> {
  const contentSha = sha256Hex(new TextEncoder().encode(p.content_text));
  const content = JSON.parse(p.content_text) as PackContent;
  const evidence: Array<{ name: string; bytes: Uint8Array }> = [];
  for (const f of p.files) {
    const got = await documentsBucket().download(f.storage_path);
    if (got.error || !got.data) throw new Error(`evidence file ${f.name_in_pack} could not be read`);
    const bytes = new Uint8Array(await got.data.arrayBuffer());
    if (sha256Hex(bytes) !== f.sha256) throw new Error(`evidence file ${f.name_in_pack} does not match its recorded SHA-256`);
    evidence.push({ name: f.name_in_pack, bytes });
  }
  const pdf = await renderPackPdf(content, contentSha, font);
  const built = assemblePack(p.reference, p.content_text, contentSha, pdf, evidence, new Date(content.made_at));
  const storagePath = `${p.customer_id}/${p.id}.zip`;
  // A pack is not released until the database records it as ready, so an earlier unfinished
  // attempt's object is simply replaced.
  const stored = await packsBucket().upload(storagePath, built.zip, { contentType: "application/zip", upsert: true });
  if (stored.error) throw new Error("the pack could not be stored");
  const r = await rpc(db, "record_pack_build", { p_export_id: p.id, p_ok: true, p_files: built.files, p_pack_sha256: built.sha256,
                                                 p_pack_bytes: built.zip.length, p_storage_path: storagePath });
  if (!r?.ok) throw new Error(r?.reason ?? "the pack was not recorded");
}

/** Builds every pack waiting. A pack that fails is recorded as failed for that attempt and retried. */
export async function buildPacks(db: SupabaseClient): Promise<{ built: number; failed: number }> {
  let built = 0, failed = 0, font: Uint8Array | null = null;
  for (let round = 0; round < 5; round++) {
    const claim = (await rpc(db, "claim_pack_builds", { p_limit: 5, p_lease_seconds: 300 })) as { packs: Claimed[] };
    if (!claim.packs.length) break;
    font ??= new Uint8Array(await readFile(FONT));
    for (const p of claim.packs) {
      try {
        await buildOne(db, p, font);
        built += 1;
      } catch (e) {
        failed += 1;
        // The reason is kept for operations; it never holds record content.
        await rpc(db, "record_pack_build", { p_export_id: p.id, p_ok: false, p_files: null, p_pack_sha256: null, p_pack_bytes: null,
                                             p_storage_path: null, p_error: (e as Error).message }).catch(() => undefined);
      }
    }
  }
  return { built, failed };
}
