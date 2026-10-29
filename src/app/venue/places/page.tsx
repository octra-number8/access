import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import {
  createArea, createAreaKind, createSystem, createSystemType, endOwnership, linkSystemArea, recordOwnership, retireArea,
  retireSystem,
} from "../../places-actions";

export const metadata = { title: "Places and systems" };

interface Area {
  id: string; row_version: number; code: string; name: string; parent_id: string | null; depth: number; kind: string | null;
  retired_at: string | null; is_root: boolean; systems: string[];
}
interface Ownership {
  id: string; row_version: number; responsibility: string; organisation: string; engagement: string | null;
  valid_from: string; valid_to: string | null; evidence_ref: string | null; ends_from: string | null; end_reason: string | null;
  ended_by: string | null; current: boolean; ended: boolean;
}
interface System {
  id: string; row_version: number; code: string; name: string; description: string | null; type: string; retired_at: string | null;
  areas: Array<{ id: string; name: string }>; ownership: Ownership[];
}
interface Overview {
  ok: true; venue: { id: string; name: string; timezone: string }; can_manage: boolean;
  area_kinds: Array<{ id: string; code: string; label: string }>; areas: Area[];
  system_types: Array<{ id: string; code: string; label: string }>; systems: System[];
  organisations: Array<{ id: string; name: string; engagements: Array<{ id: string; capacity: string }> }> | null;
}

const RESPONSIBILITY: Record<string, string> = { owner: "Owns", maintainer: "Maintains", operator: "Operates", monitoring: "Monitors" };
const CODE_HINT = "Letters, numbers, - and _ only, up to 40 characters. It cannot be changed later.";

// S1b (D-026): the venue's areas and building systems, and who is responsible for each system.
// A register records places and responsibility; it grants no authority. Retiring is refused,
// with the reasons, while anything still depends on the area or system.
export default async function Places({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/places");
  const db = await supabaseServer();
  const { data: scopes } = await db.rpc("report_scopes");
  const venues = ((scopes as { venues?: Array<{ id: string; name: string }> } | null)?.venues ?? []);
  const { venue: chosen } = await searchParams;
  const venueId = venues.some((v) => v.id === chosen) ? chosen! : venues[0]?.id;
  const { data } = venueId ? await db.rpc("places_overview", { p_venue_id: venueId }) : { data: null };
  if (!data?.ok) {
    return <><h1>Places and systems</h1><p>This page is for a venue&apos;s administrators and the people it has appointed, and you are neither at any venue. If you need to see it, ask the venue&apos;s administrator.</p></>;
  }
  const o = data as Overview;
  const tz = o.venue.timezone;
  const k = () => randomUUID();
  const live = o.areas.filter((a) => !a.retired_at);
  const retired = o.areas.filter((a) => a.retired_at);
  const indent = (a: Area) => ({ paddingLeft: `${a.depth * 1.25}rem` });

  return (
    <>
      <p><Link href="/venue">Venue administration</Link> · <Link href="/venue/setup">Set-up</Link> · <Link href="/venue/authority">Authority</Link></p>
      <h1>Places and systems — {o.venue.name}</h1>
      <div className="notice">
        <p className="m-0">Areas and systems are where jobs, appointments, gate points and controls apply. Recording them, or who is responsible for a system, gives nobody authority to act. An area cannot be moved elsewhere in the tree, and codes cannot change: to restructure, add the new one and retire the old. Retiring is refused while anything still depends on it, and it never changes issued records.</p>
      </div>
      {venues.length > 1 ? (
        <form className="no-print"><label>Venue <select name="venue" defaultValue={o.venue.id}>{venues.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label> <button type="submit" className="secondary">Show</button></form>
      ) : null}
      {!o.can_manage ? <p className="muted">You can see these records. Only the venue&apos;s tenant administrators can change them.</p> : null}

      <h2>Areas</h2>
      <div className="table-wrap"><table className="stacked">
        <thead><tr><th scope="col">Area</th><th scope="col">Code</th><th scope="col">Kind</th><th scope="col">Systems serving it</th>{o.can_manage ? <th scope="col">Action</th> : null}</tr></thead>
        <tbody>{live.map((a) => (
          <tr key={a.id}>
            <td data-label="Area"><span style={indent(a)}>{a.depth > 0 ? <span aria-hidden="true" className="muted">└ </span> : null}<strong>{a.name}</strong></span>
              {a.is_root ? <span className="muted text-sm"> · the whole venue</span> : null}</td>
            <td data-label="Code">{a.code}</td>
            <td data-label="Kind">{a.kind ?? <span className="muted">—</span>}</td>
            <td data-label="Systems serving it">{a.systems.length ? a.systems.join(", ") : <span className="muted">None recorded</span>}</td>
            {o.can_manage ? (
              <td data-label="Action">
                <details><summary className="text-sm" aria-label={`Add an area below ${a.name}`}>Add below</summary>
                  {o.area_kinds.length === 0 ? <p className="text-sm">Add an area kind first (below the table).</p> : (
                    <ActionForm action={createArea} what="Adding the area" submitLabel="Add area">
                      <input type="hidden" name="key" value={k()} /><input type="hidden" name="parent_id" value={a.id} />
                      <label>Kind<select name="kind_id" required defaultValue="">
                        <option value="" disabled>Choose a kind</option>
                        {o.area_kinds.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select></label>
                      <label>Name<input name="name" required maxLength={200} /></label>
                      <label>Code<input name="code" required pattern="[A-Za-z0-9_\-]{1,40}" maxLength={40} aria-describedby={`code-${a.id}`} /></label>
                      <p id={`code-${a.id}`} className="muted text-sm m-0">{CODE_HINT}</p>
                    </ActionForm>
                  )}
                </details>
                {!a.is_root ? (
                  <details><summary className="text-sm" aria-label={`Retire ${a.name}`}>Retire</summary>
                    <ActionForm action={retireArea} what={`Retiring ${a.name}`} submitLabel="Retire this area" secondary>
                      <input type="hidden" name="key" value={k()} /><input type="hidden" name="area_id" value={a.id} />
                      <input type="hidden" name="row_version" value={a.row_version} />
                      <p className="muted text-sm m-0">Nothing new can then refer to it. If anything still depends on it, you will be told what.</p>
                    </ActionForm>
                  </details>
                ) : null}
              </td>
            ) : null}
          </tr>
        ))}</tbody>
      </table></div>
      {retired.length ? (
        <details><summary>Retired areas ({retired.length})</summary>
          <ul>{retired.map((a) => <li key={a.id}>{a.name} <span className="muted text-sm">({a.code}{a.kind ? `, ${a.kind}` : ""}) retired {venueTime(a.retired_at!, tz)}</span></li>)}</ul>
        </details>
      ) : null}

      <h3>Area kinds</h3>
      <p>{o.area_kinds.length ? o.area_kinds.map((x) => `${x.label} (${x.code})`).join(", ") : <span className="muted">None yet. Every area below the venue has a kind, such as hall, stand, plant room or roof.</span>}</p>
      {o.can_manage ? (
        <details className="panel" style={{ maxWidth: "none" }}><summary><strong>Add an area kind</strong></summary>
          <ActionForm action={createAreaKind} what="Adding the area kind" submitLabel="Add area kind">
            <input type="hidden" name="key" value={k()} /><input type="hidden" name="venue_id" value={o.venue.id} />
            <label>Name<input name="label" required maxLength={100} placeholder="For example: Hall" /></label>
            <label>Code<input name="code" required pattern="[A-Za-z0-9_\-]{1,40}" maxLength={40} aria-describedby="code-kind" /></label>
            <p id="code-kind" className="muted text-sm m-0">{CODE_HINT}</p>
          </ActionForm>
        </details>
      ) : null}

      <h2 id="systems">Building systems</h2>
      <p className="muted">Isolations, impairments and system appointments refer to these. Who owns, maintains or operates a system is recorded for routing decisions; it gives that organisation no authority.</p>
      {o.systems.filter((s) => !s.retired_at).length === 0 ? <p>None registered yet.</p> : null}
      {o.systems.filter((s) => !s.retired_at).map((s) => {
        const unlinked = live.filter((a) => !s.areas.some((x) => x.id === a.id));
        return (
          <section key={s.id} className="panel" style={{ maxWidth: "none" }} aria-labelledby={`sys-${s.id}`}>
            <h3 id={`sys-${s.id}`} className="m-0">{s.name} <span className="muted text-sm">({s.code}) · {s.type}</span></h3>
            {s.description ? <p className="m-0">{s.description}</p> : null}
            <p><strong>Serves:</strong> {s.areas.length ? s.areas.map((a) => a.name).join(", ") : <span className="muted">No areas recorded</span>}</p>
            <p className="m-0"><strong>Responsibility</strong></p>
            {s.ownership.length === 0 ? <p className="muted">None recorded.</p> : (
              <ul>{s.ownership.map((r) => (
                <li key={r.id}>
                  {RESPONSIBILITY[r.responsibility] ?? r.responsibility}: <strong>{r.organisation}</strong>
                  {r.engagement ? <span className="muted text-sm"> (engaged as {r.engagement.toLowerCase()})</span> : null}
                  <span className="text-sm"> — from {venueTime(r.valid_from, tz)}{r.valid_to ? ` until ${venueTime(r.valid_to, tz)}` : ", no end date"}
                    {r.ended ? " · ended" : !r.current ? " · not yet started" : ""}</span>
                  {r.evidence_ref ? <span className="muted text-sm"> · {r.evidence_ref}</span> : null}
                  {r.ends_from ? <div className="muted text-sm">Ended from {venueTime(r.ends_from, tz)}{r.ended_by ? ` by ${r.ended_by}` : ""}: {r.end_reason}</div> : null}
                  {o.can_manage && !r.ends_from && !r.ended ? (
                    <details><summary className="text-sm" aria-label={`End ${r.organisation}'s responsibility for ${s.name}`}>End this record</summary>
                      <ActionForm action={endOwnership} what="Ending the ownership record" submitLabel="End record" secondary>
                        <input type="hidden" name="key" value={k()} /><input type="hidden" name="ownership_id" value={r.id} />
                        <input type="hidden" name="row_version" value={r.row_version} /><input type="hidden" name="tz" value={tz} />
                        <label>Responsibility ends<input type="datetime-local" name="ends_from" required /></label>
                        <label>Reason<input name="reason" required maxLength={1000} placeholder="For example: maintenance contract ended" /></label>
                      </ActionForm>
                    </details>
                  ) : null}
                </li>
              ))}</ul>
            )}
            {o.can_manage ? (
              <>
                <details><summary className="text-sm">Record who owns, maintains or operates it</summary>
                  {!o.organisations?.length ? <p className="text-sm">The customer has no organisations recorded yet.</p> : (
                    <ActionForm action={recordOwnership} what="Recording the responsibility" submitLabel="Record">
                      <input type="hidden" name="key" value={k()} /><input type="hidden" name="system_id" value={s.id} />
                      <input type="hidden" name="tz" value={tz} />
                      <label>Responsibility<select name="responsibility" required defaultValue="">
                        <option value="" disabled>Choose</option>
                        {Object.entries(RESPONSIBILITY).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
                      <label>Organisation<select name="party" required defaultValue="">
                        <option value="" disabled>Choose an organisation</option>
                        {o.organisations.map((g) => (
                          <optgroup key={g.id} label={g.name}>
                            <option value={g.id}>{g.name}</option>
                            {g.engagements.map((e) => <option key={e.id} value={`${g.id}|${e.id}`}>{g.name}, under its engagement as {e.capacity.toLowerCase()}</option>)}
                          </optgroup>
                        ))}</select></label>
                      <label>From<input type="datetime-local" name="valid_from" required /></label>
                      <label>Until (leave empty if open-ended)<input type="datetime-local" name="valid_to" /></label>
                      <label>Evidence (reference, optional)<input name="evidence_ref" maxLength={300} placeholder="For example: Maintenance contract MC-7" /></label>
                    </ActionForm>
                  )}
                </details>
                {unlinked.length ? (
                  <details><summary className="text-sm">Record an area it serves</summary>
                    <ActionForm action={linkSystemArea} what="Linking the area" submitLabel="Link area">
                      <input type="hidden" name="key" value={k()} /><input type="hidden" name="system_id" value={s.id} />
                      <label>Area<select name="area_id" required defaultValue="">
                        <option value="" disabled>Choose an area</option>
                        {unlinked.map((a) => <option key={a.id} value={a.id}>{" ".repeat(a.depth * 2)}{a.name}</option>)}</select></label>
                      <p className="muted text-sm m-0">Links are kept as a record: they cannot be removed in the pilot.</p>
                    </ActionForm>
                  </details>
                ) : null}
                <details><summary className="text-sm" aria-label={`Retire ${s.name}`}>Retire this system</summary>
                  <ActionForm action={retireSystem} what={`Retiring ${s.name}`} submitLabel="Retire this system" secondary>
                    <input type="hidden" name="key" value={k()} /><input type="hidden" name="system_id" value={s.id} />
                    <input type="hidden" name="row_version" value={s.row_version} />
                    <p className="muted text-sm m-0">It can then no longer be isolated, impaired, linked or appointed over. If anything still depends on it, you will be told what.</p>
                  </ActionForm>
                </details>
              </>
            ) : null}
          </section>
        );
      })}
      {o.systems.some((s) => s.retired_at) ? (
        <details><summary>Retired systems ({o.systems.filter((s) => s.retired_at).length})</summary>
          <ul>{o.systems.filter((s) => s.retired_at).map((s) => <li key={s.id}>{s.name} <span className="muted text-sm">({s.code}, {s.type}) retired {venueTime(s.retired_at!, tz)}</span></li>)}</ul>
        </details>
      ) : null}

      {o.can_manage ? (
        <>
          <details className="panel" style={{ maxWidth: "none" }}><summary><strong>Register a system</strong></summary>
            {o.system_types.length === 0 ? <p>Add a system type first.</p> : (
              <ActionForm action={createSystem} what="Registering the system" submitLabel="Register system">
                <input type="hidden" name="key" value={k()} /><input type="hidden" name="venue_id" value={o.venue.id} />
                <label>Type<select name="type_id" required defaultValue="">
                  <option value="" disabled>Choose a type</option>
                  {o.system_types.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}</select></label>
                <label>Name<input name="name" required maxLength={200} placeholder="For example: Fire alarm panel 1" /></label>
                <label>Code<input name="code" required pattern="[A-Za-z0-9_\-]{1,40}" maxLength={40} aria-describedby="code-sys" /></label>
                <p id="code-sys" className="muted text-sm m-0">{CODE_HINT}</p>
                <label>Description (optional)<textarea name="description" maxLength={2000} rows={2} /></label>
              </ActionForm>
            )}
          </details>
          <h3>System types</h3>
          <p>{o.system_types.length ? o.system_types.map((t) => `${t.label} (${t.code})`).join(", ") : <span className="muted">None yet.</span>}</p>
          <details className="panel" style={{ maxWidth: "none" }}><summary><strong>Add a system type</strong></summary>
            <ActionForm action={createSystemType} what="Adding the system type" submitLabel="Add system type">
              <input type="hidden" name="key" value={k()} /><input type="hidden" name="venue_id" value={o.venue.id} />
              <label>Name<input name="label" required maxLength={100} placeholder="For example: Fire alarm" /></label>
              <label>Code<input name="code" required pattern="[A-Za-z0-9_\-]{1,40}" maxLength={40} aria-describedby="code-type" /></label>
              <p id="code-type" className="muted text-sm m-0">{CODE_HINT}</p>
            </ActionForm>
          </details>
        </>
      ) : null}
    </>
  );
}
