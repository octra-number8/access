import Link from "next/link";
import { redirect } from "next/navigation";
import { venueTime } from "@/lib/permits";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";

export const metadata = { title: "Venue set-up" };

type SetupState = "not_set_up" | "draft" | "proposed" | "scheduled" | "in_force" | "recorded";

interface SetupItem {
  key: string; section: string; name: string; needed_for: string; state: SetupState; state_words: string;
  detail: string | null; in_force_from: string | null; pending: string | null; resolved_by: string;
  holders: string[] | null; holder_action: string | null; href: string | null;
}

interface Setup { ok: true; venue: { id: string; name: string; timezone: string }; items: SetupItem[] }

// The states that leave something for someone to do, in the order the venue should see them.
const OPEN: SetupState[] = ["not_set_up", "draft", "proposed", "scheduled"];

function Who({ item }: { item: SetupItem }) {
  return (
    <>
      {item.resolved_by}
      {item.holders === null ? null : item.holders.length > 0
        ? <div className="muted text-sm">Appointed for this at this venue: {item.holders.join(", ")}</div>
        : <div className="muted text-sm">No one at this venue holds an appointment that allows this yet.</div>}
    </>
  );
}

// P4, D-025: what this venue still has to set up. Every state is computed by the database from
// the records; nothing here can be ticked, and nothing here says the set-up is adequate.
export default async function VenueSetup({ searchParams }: { searchParams: Promise<{ venue?: string }> }) {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/venue/setup");
  const db = await supabaseServer();
  const { data: scopes } = await db.rpc("report_scopes");
  const venues = ((scopes as { venues?: Array<{ id: string; name: string }> } | null)?.venues ?? []);
  const { venue: chosen } = await searchParams;
  const venueId = venues.some((v) => v.id === chosen) ? chosen! : venues[0]?.id;
  const { data } = venueId ? await db.rpc("venue_setup", { p_venue_id: venueId }) : { data: null };
  if (!data?.ok) {
    return <><h1>Venue set-up</h1><p>This page is for a venue&apos;s administrators and the people it has appointed, and you are neither at any venue. If you need to see it, ask the venue&apos;s administrator.</p></>;
  }
  const o = data as Setup;
  const tz = o.venue.timezone;
  const sections = [...new Set(o.items.map((i) => i.section))];
  const open = o.items.filter((i) => OPEN.includes(i.state));

  return (
    <>
      <p><Link href="/venue">Venue administration</Link></p>
      <h1>Venue set-up — {o.venue.name}</h1>
      <div className="notice">
        <p>Octra has no default for anything that varies by venue (CLAUDE.md §9), so each piece below must be set up before the work that needs it can go ahead. Each state is read from the venue&apos;s own records: it changes only when the record changes, and nothing here can be marked done by hand.</p>
        <p className="m-0">A state says what has been recorded or approved, nothing more. It does not mean the content is adequate, compliant or safe; that remains the judgement of the people who approve it.</p>
      </div>
      {venues.length > 1 ? (
        <form className="no-print"><label>Venue <select name="venue" defaultValue={o.venue.id}>{venues.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select></label> <button type="submit" className="secondary">Show</button></form>
      ) : null}

      <h2>Still to do</h2>
      {open.length === 0 ? <p>Every piece listed below has a record in force or recorded.</p> : (
        <ul>{open.map((i) => (
          <li key={i.key}><a href={`#${i.key}`}>{i.name}</a>: {i.state_words.toLowerCase()}</li>
        ))}</ul>
      )}

      {sections.map((s) => (
        <section key={s}>
          <h2>{s}</h2>
          <div className="table-wrap"><table className="stacked">
            <thead><tr><th scope="col">Item</th><th scope="col">State</th><th scope="col">Needed for</th><th scope="col">Who resolves it</th><th scope="col">Where</th></tr></thead>
            <tbody>{o.items.filter((i) => i.section === s).map((i) => (
              <tr key={i.key} id={i.key}>
                <td data-label="Item"><strong>{i.name}</strong></td>
                <td data-label="State">
                  <strong>{i.state_words}</strong>
                  {i.detail ? <div className="text-sm">{i.detail}</div> : null}
                  {i.in_force_from ? <div className="muted text-sm">{i.state === "scheduled" ? "From" : "Since"} {venueTime(i.in_force_from, tz)}</div> : null}
                  {i.pending ? <div className="muted text-sm">{i.pending}</div> : null}
                </td>
                <td data-label="Needed for">{i.needed_for}</td>
                <td data-label="Who resolves it"><Who item={i} /></td>
                <td data-label="Where">{i.href ? <Link href={i.href} aria-label={`Open ${i.name}`}>Open</Link> : <span className="muted">No screen yet</span>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        </section>
      ))}
    </>
  );
}
