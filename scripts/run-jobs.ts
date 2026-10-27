// Local stand-in for the host's scheduler (P8-6): calls the job tick every minute, as Vercel
// Cron does in production (vercel.json). Reads CRON_SECRET from .env.local; prints counts only.
//   node scripts/run-jobs.ts            (every minute until stopped)
//   node scripts/run-jobs.ts --once
import { readFileSync } from "node:fs";

const env = Object.fromEntries(readFileSync(new URL("../.env.local", import.meta.url), "utf8").split("\n")
  .filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
const site = (env.SITE_URL ?? "http://localhost:3000").replace(/\/$/, "");

async function tick() {
  const r = await fetch(`${site}/api/jobs/tick`, { headers: { authorization: `Bearer ${env.CRON_SECRET}` } });
  console.log(new Date().toISOString(), r.status, JSON.stringify(await r.json()));
}

await tick();
if (!process.argv.includes("--once")) setInterval(tick, 60_000);
