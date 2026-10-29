import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { AppointmentCard } from "@/components/appointment-card";
import { ScopePicker } from "@/components/scope-picker";
import { type Appointment, plain, type ScopeItem } from "@/lib/authority";
import { toVenueLocal } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { grantAppointment, grantDelegation } from "../../authority-actions";

export const metadata = { title: "Appoint or delegate" };

interface Options {
  ok: true; appointment: Appointment; timezone: string; can_grant: boolean; can_delegate: boolean;
  types: Array<{ id: string; type: string; version_no: number; actions: string[]; class_ids: string[]; requires_competence_evidence: boolean }>;
  classes: Array<{ id: string; name: string }>;
  areas: Array<{ id: string; name: string; depth: number; with_below: boolean }>;
  systems: Array<{ id: string; name: string; type: string }>;
  people: Array<{ id: string; name: string }>;
  valid_to: string | null;
  delegable: Array<{ code: string; description: string }>;
  my_scope: Array<{ item: ScopeItem; words: string }>;
  delegates: Array<{ appointment_id: string; person: string; type: string; class_ids: string[]; scope_indexes: number[]; valid_to: string | null }>;
}

// S1a (D-026): appointing and delegating from one of your own appointments in force. The choices
// shown are those this appointment could allow; the database checks every one again.
export default async function AppointFrom({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const session = await getSession();
  if (!session) redirect(`/sign-in?next=/appointments/${id}`);
  const db = await supabaseServer();
  const { data } = await db.rpc("grant_options", { p_appointment_id: id });
  if (!data?.ok) {
    return <><h1>Appoint or delegate</h1><p>{(data as { reason?: string } | null)?.reason ?? "This appointment is not available."} Your appointments are listed on <Link href="/me#appointments">Your details</Link>.</p></>;
  }
  const o = data as Options;
  const tz = o.timezone;
  const k = () => randomUUID();
  const className = new Map(o.classes.map((c) => [c.id, c.name]));
  const until = o.valid_to ? toVenueLocal(o.valid_to, tz) : undefined;

  return (
    <>
      <p><Link href="/me#appointments">Your appointments</Link> · <Link href="/venue/authority">Authority</Link></p>
      <h1>Appoint or delegate</h1>
      <p>From your appointment below. Anything you give must sit within it: its types, classes, places and dates.</p>
      <AppointmentCard a={o.appointment} tz={tz} />

      <h2>Make an appointment</h2>
      {!o.can_grant ? <p>This appointment does not allow you to make appointments.</p>
        : o.types.length === 0 ? <p>This appointment names no appointment types you may grant, or none of them has an approved version.</p>
        : o.people.length === 0 ? <p>No one else at this customer has a login yet. A tenant administrator can invite them to sign in.</p> : (
        <ActionForm action={grantAppointment} what="Making the appointment" submitLabel="Make appointment">
          <input type="hidden" name="key" value={k()} /><input type="hidden" name="venue_id" value={o.appointment.venue_id} />
          <input type="hidden" name="acting_appointment_id" value={o.appointment.id} /><input type="hidden" name="tz" value={tz} />
          <label>Appointee<select name="appointee" required defaultValue="">
            <option value="" disabled>Choose a person</option>
            {o.people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
          <label>Appointment type<select name="type_version_id" required defaultValue="">
            <option value="" disabled>Choose a type</option>
            {o.types.map((t) => <option key={t.id} value={t.id}>{t.type} (version {t.version_no})</option>)}</select></label>
          <details><summary className="text-sm">What each type allows</summary>
            {o.types.map((t) => (
              <div key={t.id}><strong>{t.type}</strong>{t.requires_competence_evidence ? <span className="muted text-sm"> · needs competence evidence</span> : null}
                <ul>{t.actions.map((x) => <li key={x}>{plain(x)}</li>)}</ul>
                <p className="muted text-sm">Classes you may include: {t.class_ids.length ? t.class_ids.map((c) => className.get(c)).join(", ") : "none"}</p></div>
            ))}
          </details>
          {o.classes.length ? (
            <fieldset className="stack"><legend>Permit classes</legend>
              {o.classes.map((c) => <label key={c.id} className="inline"><input type="checkbox" name="class" value={c.id} /> {c.name}</label>)}
              <p className="muted text-sm m-0">Only classes the chosen type allows are accepted.</p>
            </fieldset>
          ) : null}
          <ScopePicker areas={o.areas} systems={o.systems} />
          <label>Starts<input type="datetime-local" name="valid_from" required max={until} /></label>
          <label>Ends<input type="datetime-local" name="valid_to" required max={until} /></label>
          {until ? <p className="muted text-sm m-0">Your appointment ends {until.replace("T", " ")}; this one cannot outlast it.</p> : null}
          <label>Review due (optional)<input type="date" name="review_due_on" /></label>
          <label>Limitations (optional)<textarea name="limitations" maxLength={2000} rows={2} /></label>
          <label>Competence evidence (reference)<input name="competence" maxLength={300} placeholder="Required if the type needs it" /></label>
        </ActionForm>
      )}

      <h2>Delegate</h2>
      {!o.can_delegate ? <p>This appointment does not allow you to delegate.</p>
        : o.delegable.length === 0 ? <p>None of the actions this appointment allows can be delegated.</p>
        : o.delegates.length === 0 ? <p>No one else holds an appointment in force at this venue. A delegate must hold their own appointment (invariant 7).</p> : (
        <>
          <p className="muted">A delegate must hold their own appointment in force. What you delegate must sit within both appointments; it lapses as soon as either ends.</p>
          <div className="table-wrap"><table className="stacked">
            <thead><tr><th scope="col">Possible delegate</th><th scope="col">Classes both cover</th><th scope="col">Places both cover</th></tr></thead>
            <tbody>{o.delegates.map((d) => (
              <tr key={d.appointment_id}>
                <td data-label="Delegate">{d.person} <span className="muted text-sm">({d.type})</span></td>
                <td data-label="Classes">{d.class_ids.length ? d.class_ids.map((c) => className.get(c)).join(", ") : "None"}</td>
                <td data-label="Places">{d.scope_indexes.length ? d.scope_indexes.map((i) => o.my_scope[i]?.words).join("; ") : "None: their appointment covers no whole part of yours"}</td>
              </tr>
            ))}</tbody>
          </table></div>
          <ActionForm action={grantDelegation} what="Delegating" submitLabel="Delegate">
            <input type="hidden" name="key" value={k()} /><input type="hidden" name="appointment_id" value={o.appointment.id} />
            <input type="hidden" name="tz" value={tz} /><input type="hidden" name="my_scope" value={JSON.stringify(o.my_scope.map((s) => s.item))} />
            <label>Delegate<select name="delegate_appointment_id" required defaultValue="">
              <option value="" disabled>Choose a person and their appointment</option>
              {o.delegates.filter((d) => d.scope_indexes.length).map((d) => <option key={d.appointment_id} value={d.appointment_id}>{d.person} ({d.type})</option>)}</select></label>
            <fieldset className="stack"><legend>Actions</legend>
              {o.delegable.map((x) => <label key={x.code} className="inline"><input type="checkbox" name="action" value={x.code} /> {plain(x.description)}</label>)}
            </fieldset>
            {o.classes.length ? (
              <fieldset className="stack"><legend>Permit classes</legend>
                {o.classes.map((c) => <label key={c.id} className="inline"><input type="checkbox" name="class" value={c.id} /> {c.name}</label>)}
              </fieldset>
            ) : null}
            <fieldset className="stack"><legend>Where</legend>
              {o.my_scope.map((s, i) => <label key={i} className="inline"><input type="checkbox" name="scope" value={i} /> {s.words}</label>)}
            </fieldset>
            <label>Starts<input type="datetime-local" name="valid_from" required max={until} /></label>
            <label>Ends<input type="datetime-local" name="valid_to" required max={until} /></label>
            <label>Reason<input name="reason" required maxLength={1000} placeholder="For example: Cover during annual leave, 3 to 14 March" /></label>
          </ActionForm>
        </>
      )}
    </>
  );
}
