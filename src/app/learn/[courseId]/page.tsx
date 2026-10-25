import { redirect } from "next/navigation";
import { Blocked, type Denial } from "@/components/Blocked";
import type { LearnerCourse } from "@/components/learner/types";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Journey } from "./journey";

export const metadata = { title: "Induction" };

export default async function Learn({ params }: { params: Promise<{ courseId: string }> }) {
  const { courseId } = await params;
  if (!(await getSession())) redirect(`/sign-in?next=/learn/${courseId}`);
  const db = await supabaseServer();
  const { data } = await db.rpc("learner_course", { p_course_id: courseId });
  if (!data?.ok) return <Blocked what="This induction" denial={data as Denial} />;
  return <Journey course={data as LearnerCourse} />;
}
