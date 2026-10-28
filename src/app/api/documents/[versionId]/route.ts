// Releases a document only after the database has authorised and audited the access,
// as a 60-second attachment link served from the storage domain (CLAUDE.md §5).
import { NextResponse } from "next/server";
import { downloadLink } from "@/lib/documents";
import { supabaseServer } from "@/lib/supabase/server";

export async function GET(_: Request, { params }: { params: Promise<{ versionId: string }> }) {
  const { versionId } = await params;
  const db = await supabaseServer();
  const { data: auth } = await db.auth.getUser();
  if (!auth.user) return NextResponse.json({ ok: false, code: "not_authenticated" }, { status: 401 });
  const r = await downloadLink(db, versionId);
  if (!r.ok) {
    const status = r.code === "not_found" ? 404 : r.code === "disposed" ? 410 : 409;
    return NextResponse.json(r, { status, headers: { "Cache-Control": "no-store" } });
  }
  return NextResponse.redirect(r.url, { status: 303, headers: { "Cache-Control": "no-store" } });
}
