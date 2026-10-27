import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import type { Purpose } from "@/lib/gate";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { organisationPeople, venueAreas } from "../../jobs/data";
import { requestAccess } from "../actions";

export const metadata = { title: "Ask for a visit" };

// Q121–Q125: an organisation with an active engagement asks for a visit or a series, for one
// of the venue's approved purposes, with a named roster of its own people.
export default async function NewVisit({ searchParams }: { searchParams: Promise<{ engagement?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/visits/new");
  const db = await supabaseServer();
  let q = db.from("engagement").select("id, venue_id, organisation_id, capacity_code").eq("status", "active");
  if (session.tenantAdminCustomerIds.length === 0) q = q.in("organisation_id", session.organisationAdmin.map((o) => o.organisation_id));
  const { data: engagements } = await q;
  const [{ data: venues }, { data: orgs }] = await Promise.all([
    db.from("venue").select("id, name, timezone").in("id", (engagements ?? []).map((e) => e.venue_id)),
    db.from("organisation").select("id, legal_name").in("id", (engagements ?? []).map((e) => e.organisation_id)),
  ]);
  const venue = new Map((venues ?? []).map((v) => [v.id, v]));
  const orgName = new Map((orgs ?? []).map((o) => [o.id, o.legal_name]));
  const label = (e: { venue_id: string; organisation_id: string }) => `${orgName.get(e.organisation_id) ?? "Organisation"} at ${venue.get(e.venue_id)?.name ?? "venue"}`;

  if ((engagements ?? []).length === 0) {
    return (
      <>
        <h1>Ask for a visit</h1>
        <div className="notice notice-blocked">
          <p className="notice-title">Asking for a visit is not available</p>
          <p>Why: a visit is asked for by an organisation whose engagement at the venue is active.</p>
          <p>What is missing: an active engagement for an organisation you administer.</p>
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
        <h1>Ask for a visit</h1>
        <p>Which organisation is visiting, and where?</p>
        <ul>{(engagements ?? []).map((e) => <li key={e.id}><Link href={`/visits/new?engagement=${e.id}`}>{label(e)}</Link></li>)}</ul>
      </>
    );
  }
  const v = venue.get(chosen.venue_id)!;
  const [{ data: config }, areas, people] = await Promise.all([
    db.from("venue_config_version").select("content").eq("venue_id", v.id).eq("kind", "access_purposes").eq("status", "approved").maybeSingle(),
    venueAreas(db, v.id),
    organisationPeople(db, chosen.organisation_id),
  ]);
  const purposes = ((config?.content as { purposes?: Purpose[] } | undefined)?.purposes ?? []);

  return (
    <>
      <p><Link href="/visits">All visits</Link></p>
      <h1>Ask for a visit</h1>
      <p>{label(chosen)}</p>
      {purposes.length === 0 ? (
        <div className="notice notice-blocked">
          <p className="notice-title">Asking for a visit is not available</p>
          <p>Why: the venue has not approved its visit purposes yet (Q121).</p>
          <p>Who can resolve it: the venue&apos;s tenant administrator drafts them; an access authority approves them.</p>
        </div>
      ) : (
        <ActionForm action={requestAccess} what="Asking for this visit" submitLabel="Ask for the visit">
          <input type="hidden" name="key" value={randomUUID()} />
          <input type="hidden" name="venue_id" value={v.id} />
          <input type="hidden" name="organisation_id" value={chosen.organisation_id} />
          <input type="hidden" name="tz" value={v.timezone} />
          <fieldset className="stack"><legend>Purpose</legend>
            {purposes.map((p, i) => (
              <label className="inline" key={p.key}><input type="radio" name="purpose_key" value={p.key} required defaultChecked={i === 0 && purposes.length === 1} />
                <span><strong>{p.name}</strong>. Allows: {p.allows}. Not allowed: {p.prohibits}.
                  <span className="muted">{p.escort === "always" ? " Always escorted." : ""}{p.occupier_consent ? " Occupiers of the areas must consent." : ""}</span></span>
              </label>
            ))}
          </fieldset>
          <label>What the visit is for<textarea name="description" required rows={2} placeholder="e.g. Survey the lighting bar ahead of next week's job" /></label>
          <fieldset className="stack"><legend>Where</legend>
            {areas.map((a) => (
              <label className="inline" key={a.id} style={{ paddingLeft: `${a.depth * 1.25}rem` }}><input type="checkbox" name="area_ids" value={a.id} /> {a.name}</label>
            ))}
          </fieldset>
          <label>From ({v.timezone})<input name="from" type="datetime-local" required /></label>
          <label>To<input name="to" type="datetime-local" required /></label>
          <p className="muted">For a series of visits, give the whole period; each arrival is recorded at the gate. Nothing renews automatically.</p>
          <fieldset className="stack"><legend>Who is coming</legend>
            {people.length === 0 ? <p>No one currently works with this organisation.</p> : people.map((p) => (
              <label className="inline" key={p.id}><input type="checkbox" name="person_ids" value={p.id} /> {p.name}</label>
            ))}
          </fieldset>
          <p className="muted">An access authority decides the request. A visit never allows work: if work follows, start a job from the visit once it is approved.</p>
        </ActionForm>
      )}
    </>
  );
}
