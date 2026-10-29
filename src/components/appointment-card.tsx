import type { ReactNode } from "react";
import { type Appointment, type Delegation, plain } from "@/lib/authority";
import { venueTime } from "@/lib/permits";

// One appointment as words: what it allows, where, when, under whom, and its state. The state is
// a recorded decision only; it never says the person is competent (CLAUDE.md §1).
export function AppointmentCard({ a, tz, children }: { a: Appointment; tz: string; children?: ReactNode }) {
  return (
    <div className="panel" style={{ maxWidth: "none" }}>
      <h3 style={{ marginTop: 0 }}>{a.type}{a.is_root ? " (root appointment)" : ""} — {a.appointee}</h3>
      <dl className="facts">
        <dt>State</dt><dd><strong>{a.state_words}</strong>{a.next_step ? <div className="muted text-sm">{a.next_step}</div> : null}
          {a.revoked_reason ? <div className="muted text-sm">Reason: {a.revoked_reason}</div> : null}</dd>
        <dt>Venue</dt><dd>{a.venue}</dd>
        <dt>Where</dt><dd>{a.scope.join("; ")}</dd>
        <dt>Permit classes</dt><dd>{a.classes.length ? a.classes.join(", ") : "None"}</dd>
        <dt>When</dt><dd>From {venueTime(a.valid_from, tz)}{a.valid_to ? ` to ${venueTime(a.valid_to, tz)}` : ", no end date"}
          {a.review_due_on ? <span className="muted"> · review due {a.review_due_on}</span> : null}</dd>
        <dt>Limitations</dt><dd>{a.limitations ?? "None recorded"}</dd>
        <dt>Made by</dt><dd>{a.is_root
          ? <>{a.appointed_by} (duty holder), recorded by {a.recorded_by}{a.confirmed_by ? `, confirmed by ${a.confirmed_by}` : ""}
              {a.root_evidence_ref ? <div className="muted text-sm">Letter of appointment: {a.root_evidence_ref}</div> : null}</>
          : <>{a.appointed_by}{a.under ? `, under their ${a.under.type} appointment` : ""}</>}
          {a.competence_evidence.length ? <div className="muted text-sm">Competence evidence: {a.competence_evidence.join("; ")}</div> : null}</dd>
      </dl>
      <details><summary>What it allows ({a.actions.length})</summary>
        <ul>{a.actions.map((x) => <li key={x.code}>{plain(x.description)}</li>)}</ul>
      </details>
      {children}
    </div>
  );
}

export function DelegationRow({ d, tz, children }: { d: Delegation; tz: string; children?: ReactNode }) {
  return (
    <li>
      <strong>{d.delegator}</strong> to <strong>{d.delegate}</strong>: {d.actions.map(plain).join("; ")}
      <div className="muted text-sm">Where: {d.scope.join("; ")}{d.classes.length ? ` · Classes: ${d.classes.join(", ")}` : ""} · {venueTime(d.valid_from, tz)} to {venueTime(d.valid_to, tz)}
        {d.in_force ? "" : " · not in force (an appointment it depends on has ended)"} · Reason: {d.reason}</div>
      {children}
    </li>
  );
}
