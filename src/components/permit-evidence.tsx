// The permit page's evidence section (Q213–Q216): corrections beside the frozen records, for
// anyone who can see the permit; the packs made and the form to make one, for the venue's
// evidence officers (and, read-only, its tenant administrators); the correction form for
// correction appointees. The database decides each of these.

import { randomUUID } from "node:crypto";
import { requestPack, recordCorrection } from "@/app/permits/evidence-actions";
import { ActionForm } from "@/components/ActionForm";
import { venueTime } from "@/lib/permits";
import { supabaseServer } from "@/lib/supabase/server";

interface Evidence {
  ok: true; venue_side: boolean; can_export: boolean; can_correct: boolean;
  corrections: Array<{ id: string; label: string | null; about: string; was: string; corrected: string; reason: string; evidence: string; by: string; at: string }>;
  correctable: Array<{ target_type: string; target_id: string; label: string; at: string }>;
  export_options: { files: Array<{ version_id: string; title: string; type: string; owner: string; owner_kind: string; included: boolean; omitted_reason: string | null }>;
                    permits: Array<{ id: string; class: string }> } | null;
  packs: Array<{ id: string; reference: string; made_at: string; made_by: string; capacity: string | null; purpose: string; recipient: string;
                 profile: string; omissions: Array<{ what: string; reason: string }>; build_state: string; content_sha256: string;
                 pack_sha256: string | null; pack_bytes: number | null; built_at: string | null; events: number }>;
}

const BUILD: Record<string, string> = { queued: "Being built", ready: "Ready", failed: "Could not be built: make a new one" };

export async function PermitEvidence({ permitId, tz }: { permitId: string; tz: string }) {
  const db = await supabaseServer();
  const { data } = await db.rpc("permit_evidence", { p_permit_id: permitId });
  if (!data?.ok) return null;
  const e = data as Evidence;
  const showPacks = e.export_options !== null;
  if (!e.corrections.length && !showPacks && !e.can_correct) return null;
  return (
    <section aria-labelledby="h-evidence" className="mt-6">
      <h2 id="h-evidence">Evidence</h2>

      {e.corrections.length ? (
        <>
          <h3>Corrections</h3>
          <p className="muted text-sm">Recorded beside the original, which is never changed (Q216).</p>
          <ul>{e.corrections.map((c) => (
            <li key={c.id}>
              Corrected on {venueTime(c.at, tz)} by {c.by}: <strong>{c.about}</strong>{c.label ? ` (${c.label.toLowerCase()})` : ""}.
              The record says &ldquo;{c.was}&rdquo;; the correct value is &ldquo;{c.corrected}&rdquo;.
              <div className="text-sm muted">Reason: {c.reason} · Evidence: {c.evidence}</div>
            </li>
          ))}</ul>
        </>
      ) : null}

      {e.can_correct && e.correctable.length ? (
        <details className="panel">
          <summary>Record a correction</summary>
          <ActionForm action={recordCorrection} what="Recording this correction" submitLabel="Record the correction">
            <input type="hidden" name="key" value={randomUUID()} />
            <label>Record<select name="target" required>
              {e.correctable.map((k) => <option key={k.target_id} value={`${k.target_type}:${k.target_id}`}>{k.label} ({venueTime(k.at, tz)})</option>)}
            </select></label>
            <label>What is wrong<input name="about" required maxLength={300} placeholder="For example: access equipment" /></label>
            <label>What the record says<textarea name="was" required maxLength={2000} rows={2} /></label>
            <label>The correct value<textarea name="corrected" required maxLength={2000} rows={2} /></label>
            <label>Reason<textarea name="reason" required maxLength={2000} rows={2} /></label>
            <label>What shows the correct value<input name="evidence" required maxLength={2000} placeholder="A document, a record or a witness" /></label>
            <p className="muted text-sm">The original stays exactly as it was. You cannot correct a record you made or a job you are connected with.</p>
          </ActionForm>
        </details>
      ) : null}

      {showPacks ? (
        <>
          <h3>Permit packs</h3>
          <p className="muted text-sm">Fixed sets of frozen evidence for someone outside Octra (Q213). A pack is never edited: a different one is a new pack.</p>
          {e.packs.length === 0 ? <p>No pack has been made of this job.</p> : (
            <div className="table-wrap"><table className="stacked">
              <thead><tr><th scope="col">Pack</th><th scope="col">Made</th><th scope="col">For</th><th scope="col">Left out</th><th scope="col">Hashes (SHA-256)</th></tr></thead>
              <tbody>{e.packs.map((p) => (
                <tr key={p.id}>
                  <td data-label="Pack">{p.reference}<div className="muted text-sm">{p.profile === "external" ? "External" : "Internal"} · {BUILD[p.build_state] ?? p.build_state}</div>
                    {p.build_state === "ready" && e.can_export ? <a href={`/api/packs/${p.id}`}>Download ({Math.ceil((p.pack_bytes ?? 0) / 1024)} KB)</a> : null}</td>
                  <td data-label="Made">{venueTime(p.made_at, tz)}<div className="muted text-sm">{p.made_by}{p.capacity ? `, as ${p.capacity}` : ""}</div></td>
                  <td data-label="For">{p.recipient}<div className="muted text-sm">{p.purpose}</div></td>
                  <td data-label="Left out">{p.omissions.length ? <ul className="m-0">{p.omissions.map((o, i) => <li key={i}>{o.what}: {o.reason}</li>)}</ul> : "Nothing"}</td>
                  <td data-label="Hashes"><div className="hash">Content {p.content_sha256}</div>{p.pack_sha256 ? <div className="hash">Pack {p.pack_sha256}</div> : null}</td>
                </tr>
              ))}</tbody>
            </table></div>
          )}

          {e.can_export && e.export_options ? (
            <details className="panel">
              <summary>Make a permit pack of this job</summary>
              <ActionForm action={requestPack} what="Making this pack" submitLabel="Make the pack">
                <input type="hidden" name="key" value={randomUUID()} />
                <input type="hidden" name="permit_id" value={permitId} />
                <label>What it is for<input name="purpose" required maxLength={500} placeholder="For example: public liability claim" /></label>
                <label>Who will receive it<input name="recipient" required maxLength={300} placeholder="For example: the venue's insurer" /></label>
                <fieldset>
                  <legend>Profile</legend>
                  <label className="inline"><input type="radio" name="profile" value="external" defaultChecked /> External (insurer, regulator, solicitor): contact and personal details removed, and people&apos;s own documents left out</label>
                  <label className="inline"><input type="radio" name="profile" value="internal" /> Internal (the venue&apos;s own investigation): keeps the contact details recorded for the job</label>
                </fieldset>
                <fieldset>
                  <legend>Leave anything else out (each needs a reason)</legend>
                  {e.export_options.permits.map((p) => (
                    <div key={p.id} className="choice-row">
                      <label className="inline"><input type="checkbox" name="omit" value={`answers:${p.id}`} /> Answers to the {p.class} questions</label>
                      <input name={`reason:answers:${p.id}`} aria-label={`Reason for leaving out the ${p.class} answers`} placeholder="Reason" maxLength={500} />
                    </div>
                  ))}
                  {e.export_options.files.map((f) => (
                    <div key={f.version_id} className="choice-row">
                      <label className="inline"><input type="checkbox" name="omit" value={`file:${f.version_id}`} disabled={!f.included} /> {f.title} ({f.type}, {f.owner})</label>
                      {f.included ? <input name={`reason:file:${f.version_id}`} aria-label={`Reason for leaving out ${f.title}`} placeholder="Reason" maxLength={500} />
                        : <span className="muted text-sm">{f.omitted_reason}</span>}
                    </div>
                  ))}
                </fieldset>
                <p className="muted text-sm">The pack is built from what was frozen at issue and closure, and the audit log. Who decided what, under which appointment and when, is never removed.</p>
              </ActionForm>
            </details>
          ) : null}
        </>
      ) : null}
    </section>
  );
}
