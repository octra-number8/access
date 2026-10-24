// Scanner process: signs in as the malware_scanner service account, claims leased
// jobs, scans, records results, and reports health. Outbound connections only.
// Logs carry version ids and outcomes, never file contents or personal data.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { ping, reload, scan, version, type ClamdAddress } from "./clamd.js";
import { fromVerdict, onDownloadFailure, preflight, signaturesFresh, type Outcome, type ScanJob } from "./worker.js";

function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined || v === "") throw new Error(`missing environment variable ${name}`);
  return v;
}

const config = {
  supabaseUrl: env("SUPABASE_URL"),
  anonKey: env("SUPABASE_ANON_KEY"),
  email: env("SCANNER_EMAIL"),
  password: env("SCANNER_PASSWORD"),
  clamd: {
    host: env("CLAMD_HOST", "127.0.0.1"),
    port: Number(env("CLAMD_PORT", "3310")),
    timeoutMs: Number(env("CLAMD_TIMEOUT_MS", "60000")),
  } satisfies ClamdAddress,
  // Platform settings agreed in D-013 (S4).
  pollMs: Number(env("POLL_MS", "5000")),
  leaseSeconds: Number(env("LEASE_SECONDS", "120")),
  heartbeatMs: Number(env("HEARTBEAT_MS", "60000")),
  signatureMaxAgeHours: Number(env("SIGNATURE_MAX_AGE_HOURS", "24")),
  bucket: env("DOCUMENTS_BUCKET", "documents"),
};

// A client bound to the api schema (the only one exposed).
type Db = SupabaseClient<any, "public", "api">;

const log = (event: string, fields: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ at: new Date().toISOString(), event, ...fields }));

let stopping = false;
process.on("SIGTERM", () => (stopping = true));
process.on("SIGINT", () => (stopping = true));

type State = "scanning" | "signatures_stale" | "clamd_unavailable";

async function health(): Promise<{ state: State; engine: string; sigVersion: string; sigDate: Date }> {
  if (!(await ping(config.clamd))) {
    return { state: "clamd_unavailable", engine: "unknown", sigVersion: "unknown", sigDate: new Date(0) };
  }
  const v = await version(config.clamd);
  const state: State = signaturesFresh(v, new Date(), config.signatureMaxAgeHours) ? "scanning" : "signatures_stale";
  return { state, engine: v.engine, sigVersion: v.signatureVersion, sigDate: v.signatureDate };
}

async function record(db: Db, job: ScanJob, outcome: Outcome, engine: string) {
  // A stable key: if the call is retried, the database replays the first result.
  const { data, error } = await db.rpc("record_scan_result", {
    p_idempotency_key: `scan-result:${job.version_id}`,
    p_version_id: job.version_id,
    p_result: outcome.result,
    p_engine: engine,
    p_detail: outcome.detail,
  });
  if (error || !data?.ok) throw new Error(`record_scan_result failed: ${error?.message ?? data?.code}`);
  log("scanned", { version_id: job.version_id, result: outcome.result, attempts: job.attempts });
}

async function processOne(db: Db, engine: string): Promise<boolean> {
  const { data, error } = await db.rpc("claim_scan_job", { p_lease_seconds: config.leaseSeconds });
  if (error || !data?.ok) throw new Error(`claim_scan_job failed: ${error?.message ?? data?.code}`);
  const job = data.job as ScanJob | null;
  if (!job) return false;

  const download = await db.storage.from(config.bucket).download(job.storage_path);
  if (download.error || !download.data) {
    const giveUp = onDownloadFailure(job, download.error?.message ?? "no data");
    if (giveUp) await record(db, job, giveUp, engine);
    else log("download_failed_will_retry", { version_id: job.version_id, attempts: job.attempts });
    return true;
  }
  const file = Buffer.from(await download.data.arrayBuffer());
  const outcome = preflight(job, file) ?? fromVerdict(await scan(config.clamd, file));
  await record(db, job, outcome, engine);
  return true;
}

async function main() {
  // Only the api schema is exposed (0001); the scanner reaches nothing else.
  const db = createClient(config.supabaseUrl, config.anonKey, {
    auth: { persistSession: false, autoRefreshToken: true },
    db: { schema: "api" },
  });
  const signIn = await db.auth.signInWithPassword({ email: config.email, password: config.password });
  if (signIn.error) throw new Error(`scanner sign-in failed: ${signIn.error.message}`);
  log("started");

  let lastBeat = 0;
  let lastReload = 0;
  while (!stopping) {
    const h = await health();
    if (Date.now() - lastBeat >= config.heartbeatMs) {
      const beat = await db.rpc("scanner_heartbeat", {
        p_engine_version: h.engine, p_signature_version: h.sigVersion,
        p_signature_date: h.sigDate.toISOString(), p_state: h.state,
      });
      if (beat.error || !beat.data?.ok) log("heartbeat_failed", { message: beat.error?.message ?? beat.data?.code });
      lastBeat = Date.now();
    }
    let worked = false;
    if (h.state === "scanning") {
      try {
        worked = await processOne(db, h.engine);
      } catch (e) {
        // The lease will expire and the file will be offered again; nothing is marked.
        log("scan_error", { message: (e as Error).message });
      }
    } else {
      log("not_scanning", { state: h.state });
      // Signatures on disk may be newer than those clamd has loaded. Ask it to reload,
      // at most every 5 minutes; scanning resumes only once the new version is live.
      if (h.state === "signatures_stale" && Date.now() - lastReload >= 300_000) {
        lastReload = Date.now();
        log("reload_requested", { accepted: await reload(config.clamd) });
      }
    }
    if (!worked) await new Promise((r) => setTimeout(r, config.pollMs));
  }
  log("stopped");
}

main().catch((e) => {
  log("fatal", { message: (e as Error).message });
  process.exit(1);
});
