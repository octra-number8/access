"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Blocked } from "@/components/Blocked";
import { ACTION_WORDS, IDENTITY_WORDS } from "@/lib/gate";
import { entriesKey, manifestKey } from "@/lib/gate-device";
import { venueTime } from "@/lib/permits";
import { downloadManifest, type FallbackEntry, type Manifest, type ManifestEntry, uploadFallback, type Uploaded } from "./actions";

// The gate's degraded mode (Q198–Q203, P7-8). The manifest is what the live record said at a
// moment, kept on this device for look-up only: it never admits anyone (invariant 11). Every
// entry during an outage is a manual fallback entry under the venue's outage procedure, kept
// here until it can be uploaded and checked against the live record.


function load<T>(key: string): T | null {
  try { const raw = localStorage.getItem(key); return raw ? (JSON.parse(raw) as T) : null; } catch { return null; }
}
function save(key: string, value: unknown) {
  try { if (value === null) localStorage.removeItem(key); else localStorage.setItem(key, JSON.stringify(value)); } catch { /* storage unavailable */ }
}

export function useGateStore(gatePointId: string) {
  const [manifest, setManifestState] = useState<Manifest | null>(null);
  const [entries, setEntriesState] = useState<FallbackEntry[]>([]);
  useEffect(() => {
    setManifestState(load<Manifest>(manifestKey(gatePointId)));
    setEntriesState(load<FallbackEntry[]>(entriesKey(gatePointId)) ?? []);
  }, [gatePointId]);
  return {
    manifest, entries,
    setManifest: (m: Manifest | null) => { save(manifestKey(gatePointId), m); setManifestState(m); },
    setEntries: (e: FallbackEntry[]) => { save(entriesKey(gatePointId), e.length ? e : null); setEntriesState(e); },
  };
}

const RECORDED_THEN: Record<ManifestEntry["outcome"], string> = {
  admit: "Nothing was recorded then against entry",
  admit_with_escort: "Nothing was recorded then against entry, with an escort",
  check: "Then, it needed a check",
  do_not_admit: "Then, it would have been refused",
};

const time = (iso: string, tz: string) => new Date(iso).toLocaleTimeString("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit" });
const ageMinutes = (m: Manifest, now: number) => Math.floor((now - new Date(m.made_at).getTime()) / 60_000);

/** While online: keep a manifest for the next outage, and upload what was recorded in the last. */
export function ManifestPanel({ gatePointId, tz, store }: { gatePointId: string; tz: string; store: ReturnType<typeof useGateStore> }) {
  const [busy, setBusy] = useState(false);
  const [denial, setDenial] = useState<Extract<Uploaded, { ok: false }> | null>(null);
  const [uploaded, setUploaded] = useState<Extract<Uploaded, { ok: true }> | null>(null);
  const [uploadKey, setUploadKey] = useState(() => crypto.randomUUID());
  const [autoPaused, setAutoPaused] = useState(false);
  const busyRef = useRef(false);
  const { manifest, entries } = store;

  // `auto`: a scheduled refresh (7d-3). A refusal pauses it until someone refreshes by hand, so a
  // device never keeps asking for what it was refused; a lost connection just waits for the next try.
  async function download(auto = false) {
    if (busyRef.current) return;
    busyRef.current = true; setBusy(true); if (!auto) { setDenial(null); setAutoPaused(false); }
    try {
      const r = await downloadManifest(gatePointId, crypto.randomUUID());
      if (r.ok) { store.setManifest(r); setDenial(null); } else { setDenial(r); if (auto) setAutoPaused(true); }
    } catch {
      if (!auto) setDenial({ ok: false, code: "offline", reason: "Octra could not be reached.", missing: "A connection", resolvable_by: "Try again when connected" });
    } finally { busyRef.current = false; setBusy(false); }
  }

  // Automatic refresh at the interval in the outage procedure the manifest was made under; none
  // set means by hand only (no default, CLAUDE.md §9). Only while this page is open and online.
  const every = manifest?.refresh_minutes ?? null;
  const madeAt = manifest?.made_at ?? null;
  useEffect(() => {
    if (!every || !madeAt || autoPaused) return;
    const due = () => document.visibilityState === "visible" && navigator.onLine && Date.now() - new Date(madeAt).getTime() >= every * 60_000;
    const tick = () => { if (due()) void download(true); };
    tick();
    const t = setInterval(tick, 30_000);
    return () => clearInterval(t);
  }, [every, madeAt, autoPaused]); // eslint-disable-line react-hooks/exhaustive-deps

  async function upload() {
    setBusy(true); setDenial(null);
    try {
      const r = await uploadFallback(gatePointId, manifest?.manifest_id ?? null, entries, uploadKey);
      if (r.ok) { store.setEntries([]); setUploaded(r); setUploadKey(crypto.randomUUID()); } else setDenial(r);
    } catch {
      setDenial({ ok: false, code: "offline", reason: "Octra could not be reached; the entries are still on this device.", missing: "A connection",
        resolvable_by: "Try again when connected" });
    } finally { setBusy(false); }
  }

  return (
    <details className="panel no-print" open={entries.length > 0 || uploaded !== null}>
      <summary><strong>For an outage</strong>{" "}
        <span className="muted">{manifest ? `manifest from ${time(manifest.made_at, tz)}` : "no manifest on this device"}
          {manifest ? (every && !autoPaused ? ` · refreshed automatically every ${every} min` : " · refreshed by hand") : ""}
          {entries.length ? ` · ${entries.length} manual ${entries.length === 1 ? "entry" : "entries"} to upload` : ""}</span></summary>
      <div className="stack">
        {entries.length ? (
          <>
            <p className="notice notice-blocked">{entries.length} manual {entries.length === 1 ? "entry was" : "entries were"} recorded during an outage and must be uploaded, so each is checked against the live record.</p>
            <button type="button" onClick={upload} disabled={busy}>{busy ? "Working…" : "Upload manual entries"}</button>
          </>
        ) : null}
        {uploaded ? (
          <div className="notice notice-done">
            <p>{uploaded.added} uploaded{uploaded.already_uploaded ? `, ${uploaded.already_uploaded} already uploaded` : ""}.{" "}
              {uploaded.exceptions.length === 0 ? "Nothing needs reconciling." : `${uploaded.exceptions.length} ${uploaded.exceptions.length === 1 ? "needs" : "need"} reconciling by ${uploaded.exceptions.length === 1 ? "its owner" : "their owners"}:`}</p>
            {uploaded.exceptions.length ? <ul>{uploaded.exceptions.map((x, i) => <li key={i}>{x.words} <span className="muted">({x.owner})</span></li>)}</ul> : null}
            {uploaded.exceptions.length ? <p>Octra has not told anyone. Where work is stopped, its owner must also use the venue&apos;s direct route to the supervisor and control room (Q203). <a href="/gate/reconcile">Open reconciliation</a></p> : null}
          </div>
        ) : null}
        <p className="muted">A manifest lets you look people up during an outage. It is what Octra knew when it was made, never a current answer, and it expires after the venue&apos;s set time.</p>
        {autoPaused ? <p className="notice notice-blocked">Automatic refresh is paused because the last one was refused. Refresh by hand once the reason below is resolved.</p> : null}
        <button type="button" className="secondary" onClick={() => void download()} disabled={busy}>{manifest ? "Refresh the manifest" : "Download a manifest"}</button>
        {denial ? <Blocked what="This" denial={denial} /> : null}
      </div>
    </details>
  );
}

/** While offline: the banner, look-up in the manifest, and the manual fallback log. */
export function OfflineDesk({ tz, store, onRetry, retrying }: { tz: string; store: ReturnType<typeof useGateStore>; onRetry: () => void; retrying: boolean }) {
  const { manifest, entries } = store;
  const [now, setNow] = useState(() => Date.now());
  const [query, setQuery] = useState("");
  const [chosen, setChosen] = useState<ManifestEntry | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [formKey, setFormKey] = useState(0);
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 15_000); return () => clearInterval(t); }, []);

  const age = manifest ? ageMinutes(manifest, now) : null;
  const usable = manifest !== null && age !== null && age <= manifest.max_age_minutes;
  const matches = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!usable || q.length < 2) return [];
    return manifest!.entries.filter((e) => e.name.toLowerCase().includes(q) || e.pass_numbers.some((p) => p.toLowerCase() === q)).slice(0, 8);
  }, [query, manifest, usable]);

  function record(form: HTMLFormElement) {
    const f = new FormData(form);
    const v = (k: string) => String(f.get(k) ?? "").trim();
    // The upload accepts all entries or none, so refuse here what it would refuse.
    if (v("decision") === "admitted" && v("identity") === "not_checked") {
      setProblem("Nobody is let through without an identity check. Check identity, or record a refusal or referral.");
      return;
    }
    setProblem(null);
    const entry: FallbackEntry = {
      client_entry_id: crypto.randomUUID(), recorded_at: new Date().toISOString(), person_id: chosen?.person_id, pass_number: v("pass_number") || undefined,
      name_given: v("name_given"), organisation_given: v("organisation_given") || undefined, purpose: v("purpose"), contacted: v("contacted"),
      direction: v("direction") as "in" | "out", identity_method: v("identity"), decision: v("decision"), notes: v("notes") || undefined,
    };
    store.setEntries([...entries, entry]);
    setSaved(`${entry.name_given}: ${ACTION_WORDS[entry.decision]?.toLowerCase()}, recorded on this device at ${time(entry.recorded_at, tz)}.`);
    setChosen(null); setQuery(""); setFormKey((k) => k + 1);
  }

  return (
    <div className="stack" style={{ maxWidth: "40rem" }}>
      {/* Only the headline stays pinned, so it is always in view without hiding the page. */}
      <p role="status" style={{ position: "sticky", top: 0, zIndex: 10, margin: 0, padding: ".625rem 1rem", borderRadius: ".375rem",
        background: "var(--octra-risk)", color: "#fff", fontWeight: 800, fontSize: "1.15rem" }}>
        OFFLINE — status last updated {manifest ? venueTime(manifest.made_at, tz) : "never on this device"}
      </p>
      <div className="panel" style={{ margin: 0, borderLeft: ".5rem solid var(--octra-risk)" }}>
        <p style={{ marginTop: 0 }}>No live checks are possible: restrictions, suspensions, inductions, overrides and revoked passes since then are not known here. Nobody is admitted by Octra while offline.</p>
        {manifest ? <p><strong>{manifest.instruction}</strong></p> : <p><strong>Follow the venue&apos;s outage procedure.</strong></p>}
        {manifest?.steps.length ? <ol style={{ paddingLeft: "1.5rem", listStyle: "decimal" }}>{manifest.steps.map((s, i) => <li key={i}>{s}</li>)}</ol> : null}
        <p className="muted">{manifest ? (usable ? `Manifest ${age} min old; usable for look-up until ${time(new Date(new Date(manifest.made_at).getTime() + manifest.max_age_minutes * 60_000).toISOString(), tz)}.`
          : "Manifest too old: use the manual procedure only.") : "No manifest: use the manual procedure only."}</p>
        <button type="button" className="secondary" onClick={onRetry} disabled={retrying}>{retrying ? "Checking…" : "Try to reconnect"}</button>
      </div>

      {usable ? (
        <>
          <label className="stack">Look up in the manifest (name or pass number)
            <input value={query} onChange={(e) => { setQuery(e.target.value); setChosen(null); }} autoComplete="off" />
          </label>
          {matches.length && !chosen ? (
            <ul>{matches.map((m) => <li key={m.person_id}><button type="button" className="secondary" onClick={() => setChosen(m)}>{m.name}{m.organisation ? ` · ${m.organisation}` : ""}</button></li>)}</ul>
          ) : null}
        </>
      ) : null}

      {chosen && manifest ? (
        <section className="panel" style={{ margin: 0 }}>
          <p className="muted" style={{ margin: 0 }}>What the manifest said at {time(manifest.made_at, tz)}. Not a current answer.</p>
          <p style={{ fontSize: "1.25rem", fontWeight: 700, color: "var(--octra-ink-900)" }}>{chosen.name}{chosen.organisation ? ` · ${chosen.organisation}` : ""}</p>
          {/* Never "Admit" offline (§9): say what was recorded, not what to do now. */}
          <p>{RECORDED_THEN[chosen.outcome]}{chosen.audience ? `; here as ${chosen.audience}` : ""}{chosen.areas.length ? `; areas ${chosen.areas.join(", ")}` : ""}
            {chosen.escort === "always" ? "; escort required" : ""}.</p>
          {chosen.reasons.length ? <ul>{chosen.reasons.map((r, i) => <li key={i}>{r.words} <span className="muted">({r.owner})</span></li>)}</ul> : null}
          {chosen.notices.length ? <ul>{chosen.notices.map((n) => <li key={n}><strong>{n}</strong></li>)}</ul> : null}
          <p className="muted">Passes then: {chosen.pass_numbers.join(", ") || "none"}.</p>
        </section>
      ) : null}

      <h2>Record a manual entry</h2>
      <p className="muted">Every entry made while offline is recorded here, whatever was decided, under the venue&apos;s procedure. It stays on this device until it is uploaded.</p>
      <form key={`${formKey}:${chosen?.person_id ?? ""}`} className="stack" onSubmit={(e) => { e.preventDefault(); record(e.currentTarget); }}>
        <label>Name, as given<input name="name_given" required defaultValue={chosen?.name ?? ""} /></label>
        <label>Organisation<input name="organisation_given" defaultValue={chosen?.organisation ?? ""} /></label>
        <label>Pass number (if shown)<input name="pass_number" defaultValue={chosen?.pass_numbers[0] ?? ""} /></label>
        <label>Purpose<input name="purpose" required placeholder="e.g. Lamps job in Hall 1" /></label>
        <label>Who you contacted, and what they said<textarea name="contacted" required rows={2} placeholder="e.g. Supervisor by phone: expected, confirmed" /></label>
        <fieldset className="stack"><legend>Direction</legend>
          <label className="inline"><input type="radio" name="direction" value="in" required defaultChecked /> Coming in</label>
          <label className="inline"><input type="radio" name="direction" value="out" /> Going out</label>
        </fieldset>
        <fieldset className="stack"><legend>Identity</legend>
          {Object.entries(IDENTITY_WORDS).map(([k, w]) => <label className="inline" key={k}><input type="radio" name="identity" value={k} required /> {w}</label>)}
        </fieldset>
        <fieldset className="stack"><legend>What was decided, under the procedure</legend>
          {Object.entries(ACTION_WORDS).map(([k, w]) => <label className="inline" key={k}><input type="radio" name="decision" value={k} required /> {w}</label>)}
        </fieldset>
        <label>Notes (optional)<textarea name="notes" rows={2} /></label>
        <button type="submit">Record on this device</button>
      </form>
      {problem ? <p className="notice notice-blocked" role="alert">{problem}</p> : null}
      {saved ? <p className="notice notice-done" aria-live="polite">{saved}</p> : null}
      {entries.length ? (
        <>
          <h2>Waiting to upload ({entries.length})</h2>
          <ul>{entries.map((e) => <li key={e.client_entry_id}>{time(e.recorded_at, tz)} · {e.name_given} · {e.direction === "in" ? "in" : "out"} · {ACTION_WORDS[e.decision]}</li>)}</ul>
        </>
      ) : null}
    </div>
  );
}
