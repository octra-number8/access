// A record's history (Q217, P8-11): each decision recorded on it, from the audit log: who, in
// which capacity, what, when, any change of recorded state, and the reason given. Never raw
// values. The database decides who may see it and withholds a restriction's grounds from
// anyone outside the venue's side.

import { stateWords } from "@/lib/labels";
import { PERMIT_STATE, venueTime } from "@/lib/permits";
import { supabaseServer } from "@/lib/supabase/server";

interface Entry {
  at: string; action: string; what: string; who: string; capacity: string; reason: string | null; grounds_withheld: boolean;
  changes: Array<{ record: string; from: string | null; to: string }>; seq: number | null;
}


export async function HistoryPanel({ kind, id }: { kind: "permit" | "job" | "person" | "organisation" | "visit"; id: string }) {
  const db = await supabaseServer();
  const { data } = await db.rpc("record_history", { p_kind: kind, p_id: id });
  if (!data?.ok) return null;
  const entries = (data.entries as Entry[]).slice().reverse();
  const tz = data.timezone as string;
  return (
    <details className="panel mt-6">
      <summary>History: {entries.length === 1 ? "1 decision" : `${entries.length} decisions`} recorded</summary>
      <p className="muted text-sm">From the audit log, newest first; times in {tz}. A recorded state means a decision was recorded, nothing more.</p>
      {entries.length === 0 ? <p>Nothing recorded yet.</p> : (
        <ol className="history">
          {entries.map((e, i) => (
            <li key={`${e.seq ?? i}`}>
              <p className="m-0"><strong>{e.what}</strong> <span className="muted">— {venueTime(e.at, tz)}</span></p>
              <p className="m-0 text-sm">{e.who}, as {e.capacity}</p>
              {e.changes.map((c, j) => (
                <p key={j} className="m-0 text-sm">Recorded state of the {c.record.replace(/_/g, " ")}: {c.from ? stateWords(c.from, PERMIT_STATE) : "new"} → {stateWords(c.to, PERMIT_STATE)}</p>
              ))}
              {e.reason ? <p className="m-0 text-sm">Reason: {e.reason}</p> : null}
              {e.grounds_withheld ? <p className="m-0 text-sm muted">The grounds are held by the venue and not shown here.</p> : null}
            </li>
          ))}
        </ol>
      )}
    </details>
  );
}
