import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { createCourse, createDraft, sendLink } from "./actions";

export const metadata = { title: "Inductions" };

const STATUS: Record<string, string> = {
  draft: "Draft", in_review: "Waiting for the H&S authority", published: "Published",
  superseded: "Superseded", withdrawn: "Withdrawn",
};

export default async function Inductions() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/inductions");
  if (session.tenantAdminCustomerIds.length === 0) return <p>Induction authoring is available to tenant administrators only.</p>;
  const db = await supabaseServer();
  const [venues, events, courses, versions, people] = await Promise.all([
    db.from("venue").select("id, name").in("customer_id", session.tenantAdminCustomerIds),
    db.from("event").select("id, name, venue_id"),
    db.from("induction_course").select("id, code, title, venue_id, event_id").order("code"),
    db.from("course_version").select("id, course_id, version_no, status").order("version_no", { ascending: false }),
    db.from("person").select("id, given_name, family_name").in("customer_id", session.tenantAdminCustomerIds).order("family_name"),
  ]);
  return (
    <>
      <h1>Inductions</h1>
      <p className="muted">Write or import an induction here; the venue&apos;s H&amp;S authority publishes it. Completing an induction records a briefing. It is not permission to enter or to work.</p>

      {(courses.data ?? []).map((c) => {
        const vs = (versions.data ?? []).filter((v) => v.course_id === c.id);
        const published = vs.find((v) => v.status === "published");
        const preparing = vs.find((v) => v.status === "draft" || v.status === "in_review");
        return (
          <div className="panel" key={c.id}>
            <h2 className="mt-0">{c.title} <span className="muted text-base font-normal">({c.code})</span></h2>
            <ul>
              {vs.map((v) => (
                <li key={v.id}><Link href={`/venue/inductions/${v.id}`}>Version {v.version_no}</Link> — {STATUS[v.status] ?? v.status}</li>
              ))}
            </ul>
            {!preparing ? (
              <ActionForm action={createDraft} what="Starting a new draft" submitLabel={vs.length ? "Start a new version" : "Start the first version"}>
                <input type="hidden" name="key" value={randomUUID()} />
                <input type="hidden" name="course_id" value={c.id} />
              </ActionForm>
            ) : null}
            {published ? (
              <>
                <h3>Send a personal induction link</h3>
                <ActionForm action={sendLink} what="Sending this link" submitLabel="Email the link">
                  <input type="hidden" name="key" value={randomUUID()} />
                  <input type="hidden" name="course_id" value={c.id} />
                  <label>Person
                    <select name="person_id" required>
                      {(people.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.given_name} {p.family_name}</option>)}
                    </select>
                  </label>
                  <label>Link valid for (days)<input name="days" type="number" min={1} max={60} required defaultValue={14} /></label>
                </ActionForm>
              </>
            ) : null}
          </div>
        );
      })}

      <h2>New course</h2>
      <ActionForm action={createCourse} what="Creating this course" submitLabel="Create course">
        <input type="hidden" name="key" value={randomUUID()} />
        <label>Venue
          <select name="venue_id" required>{(venues.data ?? []).map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select>
        </label>
        <label>Event (optional)
          <select name="event_id" defaultValue="">
            <option value="">— The venue, not one event —</option>
            {(events.data ?? []).map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}
          </select>
        </label>
        <label>Short code (letters, digits, hyphens)<input name="code" required pattern="[A-Za-z0-9_\-]{1,40}" /></label>
        <label>Title<input name="title" required /></label>
        <label>Who it is for<input name="audience" /></label>
      </ActionForm>
    </>
  );
}
