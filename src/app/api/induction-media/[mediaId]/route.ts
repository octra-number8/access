// Releases an induction file only after api.induction_media_access has checked it belongs
// to the learner's course (or the caller authors or reviews it), as a short-lived link.
import { NextResponse } from "next/server";
import { inductionMediaBucket } from "@/lib/supabase/storage";
import { supabaseServer } from "@/lib/supabase/server";

export async function GET(request: Request, { params }: { params: Promise<{ mediaId: string }> }) {
  const { mediaId } = await params;
  const course = new URL(request.url).searchParams.get("course");
  const db = await supabaseServer();
  const { data } = await db.rpc("induction_media_access", { p_media_id: mediaId, p_course_id: course });
  if (!data?.ok) return NextResponse.json(data ?? { ok: false }, { status: 404, headers: { "Cache-Control": "no-store" } });
  const signed = await inductionMediaBucket().createSignedUrl(data.storage_path, 300);
  if (signed.error) return NextResponse.json({ ok: false, code: "storage_failed" }, { status: 502 });
  return NextResponse.redirect(signed.data.signedUrl, { status: 303, headers: { "Cache-Control": "no-store" } });
}
