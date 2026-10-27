import { type EntryResult, inductionLine, outcomeHeadline, type Outcome } from "@/lib/gate";
import { venueTime } from "@/lib/permits";

// Colour only repeats the words (CLAUDE.md §2).
const EDGE: Record<Outcome, string> = {
  admit: "var(--octra-ready)", admit_with_escort: "var(--octra-ready)", check: "var(--octra-warning)", do_not_admit: "var(--octra-risk)",
};

/** An entry result in words: what the gate shows (§7), never more. */
export function EntryResultView({ r, tz, passLabel, children }: { r: EntryResult; tz: string; passLabel?: string; children?: React.ReactNode }) {
  const open = r.reasons.filter((x) => !x.overridden_by);
  return (
    <section aria-live="assertive" aria-labelledby="outcome" className="panel" style={{ borderLeft: `.5rem solid ${EDGE[r.outcome]}`, margin: 0 }}>
      <p id="outcome" style={{ fontSize: "2.25rem", lineHeight: 1.1, fontWeight: 800, color: "var(--octra-ink-900)", margin: 0 }}>{outcomeHeadline(r)}</p>
      <p style={{ fontSize: "1.25rem", fontWeight: 700, color: "var(--octra-ink-900)" }}>
        {r.person?.name ?? "Unknown pass"}{r.organisation ? <span className="muted" style={{ fontWeight: 400 }}> · {r.organisation}</span> : null}
      </p>
      <p className="muted">{r.entry_only ?? "This is permission to be here, not permission to work."}</p>

      {open.length ? (
        <>
          <h2 style={{ marginTop: "1rem" }}>Why</h2>
          <ul>{open.map((x) => <li key={x.code + x.words}>{x.words} <span className="muted">Who can resolve it: {x.owner}.</span></li>)}</ul>
        </>
      ) : null}

      <dl className="facts">
        {r.audience ? <><dt>Here as</dt><dd>{r.audience}</dd></> : null}
        {r.areas?.length ? <><dt>May enter</dt><dd>{r.areas.join(", ")}</dd></> : null}
        {r.outcome === "admit_with_escort" || r.escort === "always"
          ? <><dt>Escort</dt><dd>Required{r.visit?.conditions?.escort ? `: ${r.visit.conditions.escort}` : ""}</dd></> : null}
        {r.inductions?.length ? <><dt>Inductions</dt><dd>{r.inductions.map((i) => inductionLine(i, tz)).join("; ")}</dd></> : null}
        {r.visit ? <><dt>Visit</dt><dd>{r.visit.reference}: {r.visit.purpose}
          {r.visit.conditions?.no_photography ? "; no photography" : ""}{r.visit.conditions?.confidentiality ? "; confidential" : ""}
          {r.visit.conditions?.other ? `; ${r.visit.conditions.other}` : ""}</dd></> : null}
        {passLabel ? <><dt>Pass</dt><dd>{passLabel}</dd></> : null}
      </dl>

      {r.overrides.length ? (
        <ul>{r.overrides.map((o) => <li key={o.id}>Set aside by {o.by} until {venueTime(o.until, tz)}: {o.purpose}{o.escort ? `; escort ${o.escort}` : ""}</li>)}</ul>
      ) : null}
      {r.notices.length ? <ul>{r.notices.map((n) => <li key={n}><strong>{n}</strong></li>)}</ul> : null}
      {children}
    </section>
  );
}
