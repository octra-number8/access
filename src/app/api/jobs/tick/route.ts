// The scheduler's entry point (P8-6). Called every minute by the host's scheduler with the
// shared secret; anything else is refused. It reports counts only, never record content.

import { timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";
import { jobsEnv, runJobs } from "@/lib/job-runner";

export const dynamic = "force-dynamic";

function authorised(header: string | null): boolean {
  const expected = Buffer.from(`Bearer ${jobsEnv().cronSecret}`);
  const given = Buffer.from(header ?? "");
  return given.length === expected.length && timingSafeEqual(given, expected);
}

export async function GET(request: Request) {
  if (!authorised(request.headers.get("authorization"))) return NextResponse.json({ ok: false }, { status: 401 });
  try {
    return NextResponse.json({ ok: true, jobs: await runJobs() });
  } catch (e) {
    console.error("job tick failed:", (e as Error).message);
    return NextResponse.json({ ok: false, error: "The job runner could not run." }, { status: 500 });
  }
}
