import Link from "next/link";
import { redirect } from "next/navigation";
import { Blocked, type Denial } from "@/components/Blocked";
import type { JobDetail } from "@/lib/jobs";
import type { ScreeningContent } from "@/lib/screening/content";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { ScreeningJourney } from "./journey";

export const metadata = { title: "Screening questions" };

export default async function Screening({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!(await getSession())) redirect(`/sign-in?next=/jobs/${id}/screening`);
  const db = await supabaseServer();
  const { data } = await db.rpc("work_package_detail", { p_work_package_id: id });
  if (!data?.ok) return <Blocked what="This job" denial={data as Denial} />;
  const j = data as JobDetail;
  if (j.status !== "draft") redirect(`/jobs/${id}`);
  const [{ data: version }, { data: classes }] = await Promise.all([
    db.from("screening_set_version").select("id, version_no, content").eq("venue_id", j.venue_id).eq("status", "approved").maybeSingle(),
    db.from("permit_class").select("id, name").eq("venue_id", j.venue_id).eq("handling", "permit").is("retired_at", null).order("name"),
  ]);
  if (!version) {
    return (
      <>
        <p><Link href={`/jobs/${id}`}>Back to the job</Link></p>
        <div className="notice notice-blocked">
          <p className="notice-title">Screening is not available yet</p>
          <p>Why: this venue has no approved activity screening, so jobs cannot be screened.</p>
          <p>Who can resolve it: the venue&apos;s technical authority. Your job is saved as a draft meanwhile.</p>
        </div>
      </>
    );
  }
  return (
    <ScreeningJourney jobId={j.id} reference={j.reference} title={j.revision.title} rowVersion={j.row_version}
      content={version.content as ScreeningContent} classes={classes ?? []}
      initialAnswers={j.draft_answers ?? {}} initialSelected={j.draft_selected ?? []} />
  );
}
