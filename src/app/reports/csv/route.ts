import { isDay, parseScope, type Report, toCsv } from "@/lib/dashboard";
import { supabaseServer } from "@/lib/supabase/server";

// The report on screen, as CSV. Signed in as the person: the database decides the rows.
export async function GET(request: Request) {
  const url = new URL(request.url);
  const target = parseScope(url.searchParams.get("scope") ?? undefined);
  const kind = url.searchParams.get("kind") ?? "";
  const from = url.searchParams.get("from") ?? undefined;
  const to = url.searchParams.get("to") ?? undefined;
  const db = await supabaseServer();
  const { data: auth } = await db.auth.getUser();
  if (!auth.user) return new Response("Sign in to download reports.", { status: 401 });
  if (!target || !isDay(from) || !isDay(to) || !/^[a-z_]+$/.test(kind)) return new Response("Choose a report, what it covers and a period.", { status: 400 });
  const { data } = await db.rpc("report", { p_kind: kind, p_venue_id: target.venueId, p_from: from, p_to: to, p_organisation_id: target.organisationId });
  if (!data?.ok) return new Response((data as { reason?: string } | null)?.reason ?? "The report could not be produced.", { status: 403 });
  const r = data as Report;
  return new Response("﻿" + toCsv(r.columns, r.rows), {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="octra-${kind}-${from}-to-${to}.csv"`,
      "Cache-Control": "no-store",
    },
  });
}
