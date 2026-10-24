// The scanner's decisions, free of I/O so they can be tested directly.
//
// Fail closed (D-013): a file is reported clean only when its bytes match what was
// registered, its content is the declared type, and clamd says OK. Every other path
// either records a non-clean outcome or leaves the file pending for a retry.

import { createHash } from "node:crypto";
import type { ClamdVerdict, ClamdVersion } from "./clamd.js";
import { sniff } from "./filetype.js";

export interface ScanJob {
  version_id: string;
  storage_path: string;
  media_type: string;
  size_bytes: number;
  sha256: string;
  attempts: number;
}

export type Outcome =
  | { result: "clean"; detail: null }
  | { result: "infected"; detail: string }
  | { result: "rejected"; detail: string };

/** Downloads that keep failing are given up on after this many leases. */
export const MAX_DOWNLOAD_ATTEMPTS = 3;

export function signaturesFresh(v: ClamdVersion, now: Date, maxAgeHours: number): boolean {
  return now.getTime() - v.signatureDate.getTime() <= maxAgeHours * 3_600_000;
}

/** Checks the file is exactly what was registered before it is ever scanned. */
export function preflight(job: ScanJob, file: Buffer): Outcome | null {
  if (file.length !== job.size_bytes) {
    return { result: "rejected", detail: `size ${file.length} does not match registered ${job.size_bytes}` };
  }
  const sha = createHash("sha256").update(file).digest("hex");
  if (sha !== job.sha256) {
    return { result: "rejected", detail: "content does not match the registered SHA-256" };
  }
  const actual = sniff(file);
  if (actual !== job.media_type) {
    return { result: "rejected", detail: `declared ${job.media_type}, content is ${actual ?? "not an accepted type"}` };
  }
  return null;
}

export function fromVerdict(v: ClamdVerdict): Outcome {
  switch (v.kind) {
    case "clean":
      return { result: "clean", detail: null };
    case "infected":
      return { result: "infected", detail: v.signature };
    case "not_fully_scanned":
      return { result: "rejected", detail: `could not be fully scanned: ${v.detail}` };
  }
}

/** A missing or unreadable object: retry via lease expiry, then give up as rejected. */
export function onDownloadFailure(job: ScanJob, error: string): Outcome | null {
  return job.attempts >= MAX_DOWNLOAD_ATTEMPTS
    ? { result: "rejected", detail: `file could not be retrieved after ${job.attempts} attempts: ${error}` }
    : null;
}
