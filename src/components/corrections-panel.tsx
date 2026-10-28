// Corrections to live records (8c-5, §16.5): shown to anyone who can see the record. A person's or
// organisation's detail is corrected in place, with the correction kept beside it; an evidence
// file's recorded details are never changed (the reviewer relied on them as submitted), so its
// correction is kept beside the file only. Who may correct is settled by the database.

import { randomUUID } from "node:crypto";
import { correctRecord } from "@/app/organisation/correction-actions";
import { ActionForm } from "@/components/ActionForm";
import { venueTime } from "@/lib/permits";
import { supabaseServer } from "@/lib/supabase/server";

export interface CorrectionTarget { kind: "person" | "organisation" | "document_version"; id: string; label: string }
interface Result {
  ok: true; can_correct: boolean; fields: Array<{ field: string; label: string; applied: boolean }>;
  corrections: Array<{ id: string; label: string; was: string; corrected: string; reason: string; evidence: string; by: string; at: string; applied: boolean }>;
}

export async function CorrectionsPanel({ targets, venueId, tz }: { targets: CorrectionTarget[]; venueId: string | null; tz: string }) {
  const db = await supabaseServer();
  const results = await Promise.all(targets.map(async (t) =>
    ({ t, r: (await db.rpc("record_corrections", { p_kind: t.kind, p_id: t.id, p_venue_id: venueId })).data as Result | null })));
  const seen = results.filter((x) => x.r?.ok);
  const all = seen.flatMap((x) => x.r!.corrections.map((c) => ({ ...c, of: x.t.label })))
    .sort((a, b) => b.at.localeCompare(a.at));
  const options = seen.filter((x) => x.r!.can_correct).flatMap((x) => x.r!.fields.map((f) => ({
    value: `${x.t.kind}:${x.t.id}:${f.field}`, label: `${x.t.label}: ${f.label.toLowerCase()}${f.applied ? "" : " (recorded beside it, not changed)"}` })));
  if (all.length === 0 && options.length === 0) return null;
  return (
    <section aria-labelledby="h-corrections" className="mt-6">
      <h2 id="h-corrections">Corrections</h2>
      {all.length === 0 ? <p>None recorded.</p> : (
        <ul>{all.map((c) => (
          <li key={c.id}>
            {c.of}, {c.label.toLowerCase()}: recorded as &ldquo;{c.was}&rdquo;, correct value &ldquo;{c.corrected}&rdquo;
            {c.applied ? "" : " (kept beside the file; the file's record is unchanged)"}.
            <div className="text-sm muted">By {c.by} on {venueTime(c.at, tz)}. Reason: {c.reason} · Evidence: {c.evidence}</div>
          </li>
        ))}</ul>
      )}
      {options.length && venueId ? (
        <details className="panel">
          <summary>Record a correction</summary>
          <ActionForm action={correctRecord} what="Recording this correction" submitLabel="Record the correction">
            <input type="hidden" name="key" value={randomUUID()} />
            <input type="hidden" name="venue_id" value={venueId} />
            <label>What is wrong<select name="target" required>{options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</select></label>
            <label>The correct value<input name="corrected" required maxLength={300} placeholder="Dates as YYYY-MM-DD" /></label>
            <label>Reason<textarea name="reason" required maxLength={2000} rows={2} /></label>
            <label>What shows the correct value<input name="evidence" required maxLength={2000} placeholder="A document, a record or a witness" /></label>
            <p className="muted text-sm">What the record said is kept with the correction. You cannot correct your own details, or details you or your organisation entered.</p>
          </ActionForm>
        </details>
      ) : null}
    </section>
  );
}
