import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { createJob } from "../actions";
import { organisationPeople, venueAreas } from "../data";
import { JobFields } from "../job-fields";

export const metadata = { title: "Start a job" };

// Q48-Q50: one journey for every kind of job, within an approved engagement.
export default async function NewJob({ searchParams }: { searchParams: Promise<{ engagement?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/jobs/new");
  const db = await supabaseServer();
  const adminOrgs = session.organisationAdmin.map((o) => o.organisation_id);
  let q = db.from("engagement").select("id, venue_id, organisation_id, capacity_code").eq("status", "active");
  if (session.tenantAdminCustomerIds.length === 0) q = q.in("organisation_id", adminOrgs);
  const { data: engagements } = await q;
  const [{ data: venues }, { data: orgs }] = await Promise.all([
    db.from("venue").select("id, name").in("id", (engagements ?? []).map((e) => e.venue_id)),
    db.from("organisation").select("id, legal_name").in("id", (engagements ?? []).map((e) => e.organisation_id)),
  ]);
  const venueName = new Map((venues ?? []).map((v) => [v.id, v.name]));
  const orgName = new Map((orgs ?? []).map((o) => [o.id, o.legal_name]));
  const label = (e: { venue_id: string; organisation_id: string; capacity_code: string }) =>
    `${orgName.get(e.organisation_id) ?? "Organisation"} at ${venueName.get(e.venue_id) ?? "venue"} (${e.capacity_code.replace(/_/g, " ")})`;

  if ((engagements ?? []).length === 0) {
    return (
      <>
        <h1>Start a job</h1>
        <div className="notice notice-blocked">
          <p className="notice-title">Starting a job is not available</p>
          <p>Why: work can be started only for an organisation whose engagement at the venue has been approved.</p>
          <p>What is missing: an active engagement for your organisation.</p>
          <p>Who can resolve it: the venue&apos;s compliance authority, once the evidence it needs is in place.</p>
        </div>
      </>
    );
  }
  const params = await searchParams;
  const chosen = (engagements ?? []).find((e) => e.id === params.engagement) ?? ((engagements ?? []).length === 1 ? engagements![0] : null);
  if (!chosen) {
    return (
      <>
        <h1>Start a job</h1>
        <p>Which organisation is doing the work, and where?</p>
        <ul>{(engagements ?? []).map((e) => <li key={e.id}><Link href={`/jobs/new?engagement=${e.id}`}>{label(e)}</Link></li>)}</ul>
      </>
    );
  }

  const [{ data: workTypes }, areas, people] = await Promise.all([
    db.from("work_type").select("id, label").eq("venue_id", chosen.venue_id).is("retired_at", null).order("label"),
    venueAreas(db, chosen.venue_id),
    organisationPeople(db, chosen.organisation_id),
  ]);
  const me = people.find((p) => session.personIds.includes(p.id))?.id ?? people[0]?.id;

  return (
    <>
      <p><Link href="/jobs">All jobs</Link></p>
      <h1>Start a job</h1>
      <p>{label(chosen)}</p>
      {(workTypes ?? []).length === 0 ? (
        <p className="notice notice-blocked">This venue has not set up any work types yet. Its administrator adds them on the screening set-up page.</p>
      ) : (
        <ActionForm action={createJob} what="Starting this job" submitLabel="Save as a draft">
          <input type="hidden" name="key" value={randomUUID()} />
          <input type="hidden" name="venue_id" value={chosen.venue_id} />
          <input type="hidden" name="engagement_id" value={chosen.id} />
          <fieldset className="stack"><legend>What kind of job</legend>
            {(workTypes ?? []).map((w, i) => (
              <label className="inline" key={w.id}><input type="radio" name="work_type_id" value={w.id} required defaultChecked={i === 0} /> {w.label}</label>
            ))}
          </fieldset>
          <JobFields areas={areas} people={people} defaults={{ contact: me }} />
          <p className="muted">Next you answer the venue&apos;s screening questions. Nothing is sent to the venue until you submit.</p>
        </ActionForm>
      )}
    </>
  );
}
