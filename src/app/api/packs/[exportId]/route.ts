// Releases a permit pack only after the database has authorised and audited the release, as a
// 60-second attachment link from private storage (CLAUDE.md §5, P8-8).
import { NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase/server";
import { packsBucket } from "@/lib/supabase/storage";

export async function GET(_: Request, { params }: { params: Promise<{ exportId: string }> }) {
  const { exportId } = await params;
  const db = await supabaseServer();
  const { data: auth } = await db.auth.getUser();
  if (!auth.user) return NextResponse.json({ ok: false, code: "not_authenticated" }, { status: 401 });
  if (!/^[0-9a-f-]{36}$/.test(exportId)) return NextResponse.json({ ok: false, code: "not_found" }, { status: 404 });
  const { data, error } = await db.rpc("pack_access", { p_export_id: exportId });
  if (error) throw new Error(error.message);
  const noStore = { "Cache-Control": "no-store" };
  if (!data.ok) return NextResponse.json(data, { status: data.code === "not_found" ? 404 : 409, headers: noStore });
  const signed = await packsBucket().createSignedUrl(data.storage_path, 60, { download: data.file_name });
  if (signed.error) return NextResponse.json({ ok: false, code: "storage_failed", reason: "The pack could not be retrieved." }, { status: 502, headers: noStore });
  return NextResponse.redirect(signed.data.signedUrl, { status: 303, headers: noStore });
}
