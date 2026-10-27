import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/ActionForm";
import { getSession } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { markRead, setPreference } from "./actions";

export const metadata = { title: "Inbox" };

const MODES: Array<[string, string]> = [
  ["in_app", "In Octra only"],
  ["email", "By email as they happen"],
  ["digest", "In one email a day"],
];

// A person's notices (P8-2 to P8-4). A notice says a decision was recorded or something is
// due; it is never the decision itself, and never a stop instruction.
export default async function Inbox() {
  const session = await getSession();
  if (!session) redirect("/sign-in?next=/inbox");
  const db = await supabaseServer();
  const [{ data: notices }, { data: prefs }, { data: venues }] = await Promise.all([
    db.from("notification").select("id, class, subject, body, link, read_at, created_at, venue_id").order("created_at", { ascending: false }).limit(200),
    db.from("notification_preference").select("routine_mode"),
    db.from("venue").select("id, timezone"),
  ]);
  const tz = new Map((venues ?? []).map((v) => [v.id, v.timezone]));
  const unread = (notices ?? []).filter((n) => !n.read_at);
  const mode = (prefs ?? [])[0]?.routine_mode ?? "in_app";
  const when = (iso: string, venue: string | null) =>
    new Date(iso).toLocaleString("en-GB", { timeZone: (venue && tz.get(venue)) || "Europe/London", day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });

  return (
    <>
      <h1>Inbox</h1>
      <p className="muted">Notices that something was recorded or is due. A notice is never the decision itself: open the record to act. Where work is stopped, the venue&apos;s direct route (control room, supervisor) still applies.</p>
      {unread.length ? (
        <ActionForm action={markRead} what="Marking these read" submitLabel="Mark all as read" secondary>
          {unread.map((n) => <input key={n.id} type="hidden" name="id" value={n.id} />)}
        </ActionForm>
      ) : null}
      {(notices ?? []).length === 0 ? <p>Nothing yet.</p> : (
        <ul style={{ listStyle: "none", padding: 0 }}>
          {(notices ?? []).map((n) => (
            <li key={n.id} className="panel" style={{ margin: ".5rem 0", padding: ".875rem 1rem", borderLeft: n.class === "critical" ? ".375rem solid var(--octra-risk)" : undefined }}>
              <p style={{ margin: 0 }}>
                {n.class === "critical" ? <span className="tag" style={{ marginLeft: 0, marginRight: ".5rem" }}>Critical</span> : null}
                <strong style={{ fontWeight: n.read_at ? 600 : 800 }}>{n.subject}</strong>
                <span className="muted"> · {when(n.created_at, n.venue_id)}{n.read_at ? "" : " · new"}</span>
              </p>
              <p style={{ whiteSpace: "pre-line" }}>{n.body}</p>
              {n.link ? <p style={{ margin: 0 }}><Link href={n.link}>Open</Link></p> : null}
            </li>
          ))}
        </ul>
      )}

      <h2>How you receive routine notices</h2>
      <p className="muted">Critical notices (work stopped, a control failed, an overdue fire watch or impairment, emergency work, an outage exception, a restriction affecting live work) are always in your inbox and always emailed. They cannot be switched off.</p>
      <ActionForm action={setPreference} what="Saving your choice" submitLabel="Save">
        <fieldset className="stack"><legend>Routine notices</legend>
          {MODES.map(([k, label]) => <label className="inline" key={k}><input type="radio" name="mode" value={k} defaultChecked={mode === k} required /> {label}</label>)}
        </fieldset>
      </ActionForm>
    </>
  );
}
