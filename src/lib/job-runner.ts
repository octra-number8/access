import "server-only";

// The scheduled job runner (P8-6, D-021). It signs in as the job runner service account, never
// with the service role key, and each database function checks that account's purpose: expiry,
// the notification jobs, and email delivery. Every run is logged; a failed step is logged and
// the others still run. Nothing here decides anything (invariant 10).

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { publicEnv, serverEnv } from "./env";
import { sendMail } from "./mail";

interface Email { delivery_ids: string[]; to: string | null; subject: string; body: string; link: string | null }

export function jobsEnv() {
  const need = (n: string) => { const v = process.env[n]; if (!v) throw new Error(`missing environment variable ${n}`); return v; };
  return { email: need("JOB_RUNNER_EMAIL"), password: need("JOB_RUNNER_PASSWORD"), cronSecret: need("CRON_SECRET") };
}

async function runnerClient(): Promise<SupabaseClient> {
  const env = jobsEnv();
  const db = createClient(publicEnv.supabaseUrl, publicEnv.supabaseAnonKey, { auth: { persistSession: false }, db: { schema: "api" } });
  const { error } = await db.auth.signInWithPassword({ email: env.email, password: env.password });
  if (error) throw new Error("the job runner could not sign in");
  return db as unknown as SupabaseClient;
}

async function rpc(db: SupabaseClient, fn: string, args: Record<string, unknown> = {}) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  if (data && data.allowed === false) throw new Error(`${fn}: ${data.reason ?? "refused"}`);
  return data;
}

async function deliver(db: SupabaseClient, claim: "claim_email_batch" | "claim_digest_batch"): Promise<{ sent: number; failed: number }> {
  const site = serverEnv().siteUrl.replace(/\/$/, "");
  let sent = 0, failed = 0;
  for (let round = 0; round < 10; round++) {
    const batch = (await rpc(db, claim, { p_limit: 20, p_lease_seconds: 120 })) as { emails: Email[] };
    if (!batch.emails.length) break;
    for (const e of batch.emails) {
      const body = `${e.body}\n\n${e.link ? `Open it in Octra (sign-in needed): ${site}${e.link}\n\n` : ""}You can choose how you receive routine notices in Octra. Critical notices are always emailed.`;
      const r = e.to ? await sendMail(e.to, e.subject, body) : { ok: false as const, error: "no address" };
      await rpc(db, "record_email_result", { p_delivery_ids: e.delivery_ids, p_ok: r.ok, p_error: r.ok ? null : r.error });
      if (r.ok) sent += 1; else failed += 1;
    }
  }
  return { sent, failed };
}

/** One tick of the scheduler. Safe to run as often as it is called. */
export async function runJobs(): Promise<Record<string, unknown>> {
  const db = await runnerClient();
  const out: Record<string, unknown> = {};
  const step = async (job: string, fn: () => Promise<Record<string, unknown>>, logged: boolean) => {
    try {
      const counts = await fn();
      out[job] = counts;
      if (logged) await rpc(db, "record_job_run", { p_job: job, p_outcome: "ok", p_counts: counts });
    } catch (e) {
      out[job] = { error: (e as Error).message };
      await rpc(db, "record_job_run", { p_job: job, p_outcome: "failed", p_counts: {}, p_error: (e as Error).message }).catch(() => undefined);
    }
  };
  await step("expiry", async () => ({ expired: ((await rpc(db, "expire_permits")) as { expired?: number }).expired ?? 0 }), true);
  // The notification jobs log their own run.
  await step("notifications", async () => (await rpc(db, "run_notification_jobs")) as Record<string, unknown>, false);
  await step("email", async () => ({ ...(await deliver(db, "claim_email_batch")), digests: await deliver(db, "claim_digest_batch") }), true);
  await db.auth.signOut();
  return out;
}
