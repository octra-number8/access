import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { authoriseEmergency, linkRetrospective, publishEmergencyConfig, publishEmergencyContacts } from "../controls/actions";

export const metadata = { title: "Emergency work" };

type Emergency = {
  id: string; reference: string; category: string; description: string; why_could_not_wait: string; organisation: string; authorised_by: string;
  at: string; deadline_at: string; venue_timezone: string; job_reference: string | null; work_package_id: string | null;
  retrospective_submitted: boolean; overdue: boolean;
};

// Emergency and urgent make-safe work (Q91-Q97, P6-11): the register, the decision that
// lets it start, and the retrospective permit that must follow.
export default async function EmergencyWork() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/emergency");
  const db = await supabaseServer();
  const [{ data: reg }, { data: venues }, { data: configs }, { data: contacts }, { data: areas }, { data: systems }, { data: orgs }, { data: people }, { data: jobs }] =
    await Promise.all([
      db.rpc("emergency_register"),
      db.from("venue").select("id, name, timezone"),
      db.from("emergency_config_version").select("venue_id, categories, retrospective_hours, effective_from, change_reason").order("effective_from", { ascending: false }),
      db.from("venue_emergency_contacts").select("venue_id, contacts, effective_from").order("effective_from", { ascending: false }),
      db.from("area").select("id, name, venue_id").order("name"),
      db.from("system").select("id, name, venue_id").is("retired_at", null).order("name"),
      db.from("organisation").select("id, legal_name").order("legal_name"),
      db.from("person").select("id, given_name, family_name").order("family_name"),
      db.from("work_package").select("id, reference, venue_id, performing_organisation_id, status").neq("status", "cancelled").order("reference"),
    ]);
  const emergencies = ((reg as { emergencies?: Emergency[] } | null)?.emergencies ?? []);
  const k = () => randomUUID();
  const hidden = (n: string, v: string) => <input type="hidden" name={n} value={v} />;
  const authorityVenues = (venues ?? []).filter((v) => session.appointmentVenueIds.includes(v.id));
  const adminVenues = (venues ?? []).filter(() => session.tenantAdminCustomerIds.length > 0);
  const myOrgs = session.organisationAdmin.map((o) => o.organisation_id);
  const linkable = emergencies.filter((e) => !e.work_package_id);

  return (
    <>
      <h1>Emergency work</h1>
      <p className="muted">Emergency or urgent make-safe work can start on an appointed authority&apos;s recorded decision. It is not a permit. A full
        retrospective permit must follow by the venue&apos;s deadline; missing the deadline approves nothing.</p>

      <h2>Register (Q96)</h2>
      {emergencies.length === 0 ? <p>No emergency work recorded.</p> : (
        <div className="table-wrap"><table>
          <thead><tr><th scope="col">Reference</th><th scope="col">Work</th><th scope="col">Authorised</th><th scope="col">Retrospective permit</th></tr></thead>
          <tbody>{emergencies.map((e) => (
            <tr key={e.id}>
              <td>{e.reference}<div className="muted">{e.category}</div></td>
              <td>{e.description}<div className="muted">{e.organisation} · why it could not wait: {e.why_could_not_wait}</div></td>
              <td>{e.authorised_by}<div className="muted">{venueTime(e.at, e.venue_timezone)}</div></td>
              <td>{e.retrospective_submitted ? <>Submitted: <Link href={`/jobs/${e.work_package_id}`}>{e.job_reference}</Link></>
                : <>{e.overdue ? <strong>Overdue</strong> : "Due"} by {venueTime(e.deadline_at, e.venue_timezone)}
                    {e.job_reference ? <div className="muted">Job <Link href={`/jobs/${e.work_package_id}`}>{e.job_reference}</Link> linked, permit not yet submitted</div>
                      : <div className="muted">— the organisation, by linking its job</div>}</>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}

      {myOrgs.length > 0 && linkable.length > 0 ? (
        <details className="panel" open><summary><strong>Link your retrospective job (Q97)</strong></summary>
          <ActionForm action={linkRetrospective} what="Linking the retrospective job" submitLabel="Link">
            {hidden("key", k())}
            <label>Emergency work<select name="emergency_id" required defaultValue=""><option value="">— Choose —</option>
              {linkable.map((e) => <option key={e.id} value={e.id}>{e.reference}: {e.description}</option>)}</select></label>
            <label>Your job for it<select name="work_package_id" required defaultValue=""><option value="">— Choose —</option>
              {(jobs ?? []).filter((j) => myOrgs.includes(j.performing_organisation_id)).map((j) => <option key={j.id} value={j.id}>{j.reference}</option>)}</select></label>
            <p className="m-0 text-sm muted">Create a job for the work on the jobs page first. The person who authorised the emergency cannot review or issue its permits.</p>
          </ActionForm>
        </details>
      ) : null}

      {authorityVenues.map((v) => {
        const cfg = (configs ?? []).find((c) => c.venue_id === v.id);
        return (
          <section key={v.id}>
            <h2>Authorise emergency work at {v.name}</h2>
            {!cfg ? <p className="notice">The venue has not defined its emergency work categories and retrospective deadline, so emergency work cannot be authorised here.</p> : (
              <details className="panel"><summary><strong>Authorise emergency work</strong> (deadline for the retrospective permit: {cfg.retrospective_hours} hours)</summary>
                <ActionForm action={authoriseEmergency} what="Authorising emergency work" submitLabel="Authorise the work to start">
                  {hidden("key", k())}{hidden("venue_id", v.id)}
                  <label>Category (Q91)<select name="category" required defaultValue=""><option value="">— Choose —</option>
                    {cfg.categories.map((c: string) => <option key={c} value={c}>{c}</option>)}</select></label>
                  <label>The work<input name="description" required /></label>
                  <label>Why it could not wait for a permit (Q96)<textarea name="why" required rows={2} /></label>
                  <fieldset className="stack"><legend>Areas</legend>
                    {(areas ?? []).filter((a) => a.venue_id === v.id).map((a) => <label key={a.id} className="inline"><input type="checkbox" name="area_ids" value={a.id} /> {a.name}</label>)}
                  </fieldset>
                  <fieldset className="stack"><legend>Systems (if any)</legend>
                    {(systems ?? []).filter((x) => x.venue_id === v.id).map((x) => <label key={x.id} className="inline"><input type="checkbox" name="system_ids" value={x.id} /> {x.name}</label>)}
                  </fieldset>
                  <label>Organisation doing the work<select name="organisation_id" required defaultValue=""><option value="">— Choose —</option>
                    {(orgs ?? []).map((o) => <option key={o.id} value={o.id}>{o.legal_name}</option>)}</select></label>
                  <label>People doing the work<select name="person_ids" multiple required size={5}>
                    {(people ?? []).map((x) => <option key={x.id} value={x.id}>{x.given_name} {x.family_name}</option>)}</select></label>
                  <label>Controls applied now (Q94)<textarea name="controls" required rows={2} /></label>
                </ActionForm>
              </details>
            )}
            <details><summary>Emergency definitions for {v.name}</summary>
              {cfg ? <p className="m-0">In force: {cfg.categories.join("; ")}. Retrospective permit within {cfg.retrospective_hours} hours. <span className="muted">Source: {cfg.change_reason}</span></p> : null}
              <ActionForm action={publishEmergencyConfig} what="Publishing the definitions" submitLabel="Publish">
                {hidden("key", k())}{hidden("venue_id", v.id)}
                <label>Categories, one per line (Q91)<textarea name="categories" required rows={3} /></label>
                <label>Hours within which the retrospective permit is due (Q97)<input name="hours" type="number" min={0} step="any" required /></label>
                <label>Source<input name="reason" required placeholder="e.g. Emergency procedure rev. 1" /></label>
              </ActionForm>
            </details>
          </section>
        );
      })}

      {adminVenues.map((v) => {
        const current = (contacts ?? []).find((c) => c.venue_id === v.id)?.contacts as Array<{ label: string; phone: string }> | undefined;
        return (
          <section key={`c${v.id}`}>
            <h2>Emergency contacts for {v.name}</h2>
            <p className="muted">Shown on every live permit at the venue. Venue numbers only, never a person&apos;s own.</p>
            {current ? <ul>{current.map((c) => <li key={c.label}>{c.label}: {c.phone}</li>)}</ul> : <p>Not published: live permits say so.</p>}
            <details><summary>Publish emergency contacts</summary>
              <ActionForm action={publishEmergencyContacts} what="Publishing the contacts" submitLabel="Publish">
                {hidden("key", k())}{hidden("venue_id", v.id)}
                <label>One per line, as label: number<textarea name="contacts" required rows={3} placeholder={"Control room: 020 7000 0000\nFirst aid: 020 7000 0001"}
                  defaultValue={current?.map((c) => `${c.label}: ${c.phone}`).join("\n")} /></label>
                <label>Why it is changing<input name="reason" required /></label>
              </ActionForm>
            </details>
          </section>
        );
      })}
    </>
  );
}
