import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { recordFacilitated } from "../venue/inductions/actions";

export const metadata = { title: "Facilitated induction" };

// Q47: an appointed facilitator records an assisted or facilitated induction for someone
// without suitable technology, or after they have used all their attempts.
export default async function Facilitate() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/facilitate");
  const db = await supabaseServer();
  const [versions, courses, people] = await Promise.all([
    db.from("course_version").select("id, course_id, version_no").eq("status", "published"),
    db.from("induction_course").select("id, title"),
    db.from("person").select("id, given_name, family_name").order("family_name"),
  ]);
  const title = new Map((courses.data ?? []).map((c) => [c.id, c.title]));
  return (
    <>
      <h1>Record a facilitated induction</h1>
      <p className="muted">Go through the induction with the person, check their identity and their understanding, and have them acknowledge the declaration. Only an appointed induction facilitator can record this.</p>
      <ActionForm action={recordFacilitated} what="Recording this induction" submitLabel="Record completion">
        <input type="hidden" name="key" value={randomUUID()} />
        <label>Induction
          <select name="version_id" required>
            {(versions.data ?? []).map((v) => <option key={v.id} value={v.id}>{title.get(v.course_id)} (version {v.version_no})</option>)}
          </select>
        </label>
        <label>Person
          <select name="person_id" required>
            {(people.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.given_name} {p.family_name}</option>)}
          </select>
        </label>
        <label>How it was delivered
          <select name="method" required defaultValue="assisted">
            <option value="assisted">Assisted: they took it with help</option>
            <option value="facilitated">Facilitated: delivered to them in person</option>
          </select>
        </label>
        <label>How you checked who they are<input name="identity_check" required minLength={5} /></label>
        <label>How you checked they understood<textarea name="understanding_check" required minLength={5} rows={2} /></label>
        <label className="inline"><input type="checkbox" name="acknowledged" /> They acknowledged the briefing and the declaration</label>
      </ActionForm>
    </>
  );
}
