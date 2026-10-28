"use client";

import { useEffect, useRef, useState } from "react";
import { ActionForm } from "@/components/ActionForm";
import { Blocked } from "@/components/Blocked";
import { EntryResultView } from "@/components/gate/entry-result";
import { keepGatePageOffline } from "@/lib/gate-device";
import { ping, recordGateAction, scanPass, type ScanOutcome } from "./actions";
import { ManifestPanel, OfflineDesk, useGateStore } from "./offline";

// The browser's built-in barcode reader (P7-11). Not in every browser: the pass number is the
// fallback, and a handheld scanner that types the code into the box works too.
interface Detector { detect(source: CanvasImageSource): Promise<Array<{ rawValue: string }>> }
declare global { interface Window { BarcodeDetector?: new (o: { formats: string[] }) => Detector } }

const STALE_MS = 5 * 60_000; // the database refuses to record against an older result (7a-1)

export function GateDesk({ gatePointId, gateName, tz }: { gatePointId: string; gateName: string; tz: string }) {
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [scan, setScan] = useState<ScanOutcome | null>(null);
  const [camera, setCamera] = useState<"off" | "on" | "unavailable">("off");
  const [direction, setDirection] = useState<"in" | "out">("in");
  const [now, setNow] = useState(() => Date.now());
  const [formKey, setFormKey] = useState(() => crypto.randomUUID());
  const [offline, setOffline] = useState(false);
  const [retrying, setRetrying] = useState(false);
  const store = useGateStore(gatePointId);
  const video = useRef<HTMLVideoElement>(null);
  const field = useRef<HTMLInputElement>(null);
  const stream = useRef<MediaStream | null>(null);

  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(t); }, []);
  useEffect(() => () => stopCamera(), []);
  useEffect(() => {
    const down = () => setOffline(true);
    window.addEventListener("offline", down);
    if (!navigator.onLine) setOffline(true);
    // The page may be the device's saved copy (7d-2): if Octra cannot be reached, start offline.
    ping().catch(() => setOffline(true));
    keepGatePageOffline().catch(() => { /* the page works without it */ });
    return () => window.removeEventListener("offline", down);
  }, []);

  useEffect(() => { if (offline) stopCamera(); }, [offline]);

  async function retry() {
    setRetrying(true);
    try { if (await ping()) setOffline(false); } catch { /* still offline */ } finally { setRetrying(false); }
  }

  function stopCamera() {
    stream.current?.getTracks().forEach((t) => t.stop());
    stream.current = null;
    setCamera((c) => (c === "on" ? "off" : c));
  }

  async function check(value: string) {
    if (busy) return;
    setBusy(true);
    setScan(null);
    setDirection("in");
    setFormKey(crypto.randomUUID());
    try {
      setScan(await scanPass(gatePointId, value, crypto.randomUUID()));
    } catch {
      // Octra cannot be reached: nothing was checked. Switch to the offline procedure.
      setOffline(true);
    } finally {
      setInput("");
      setBusy(false);
    }
  }

  async function startCamera() {
    if (!window.BarcodeDetector || !navigator.mediaDevices?.getUserMedia) { setCamera("unavailable"); return; }
    try {
      stream.current = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
    } catch {
      setCamera("unavailable");
      return;
    }
    setCamera("on");
    const detector = new window.BarcodeDetector({ formats: ["qr_code"] });
    const v = video.current!;
    v.srcObject = stream.current;
    await v.play();
    const tick = async () => {
      if (!stream.current) return;
      const found = await detector.detect(v).catch(() => []);
      if (found[0]?.rawValue) { stopCamera(); await check(found[0].rawValue); return; }
      setTimeout(tick, 250);
    };
    tick();
  }

  function next() {
    setScan(null);
    setFormKey(crypto.randomUUID());
    field.current?.focus();
  }

  const ok = scan?.ok === true ? scan : null;
  const r = ok?.result;
  const age = ok ? now - new Date(ok.evaluatedAt).getTime() : 0;
  const stale = age > STALE_MS;

  if (offline) {
    return <OfflineDesk tz={tz} store={store} onRetry={retry} retrying={retrying} />;
  }

  return (
    <div className="stack" style={{ maxWidth: "40rem" }}>
      <ManifestPanel gatePointId={gatePointId} tz={tz} store={store} />
      <form className="stack" onSubmit={(e) => { e.preventDefault(); check(input); }}>
        <label>Scan or type the pass number
          <input ref={field} value={input} onChange={(e) => setInput(e.target.value)} autoFocus autoComplete="off" spellCheck={false}
            inputMode="text" placeholder="e.g. C-000012" aria-describedby="scan-help" />
        </label>
        <p id="scan-help" className="muted">A typed number is recorded as a manual look-up: check identity carefully.</p>
        <div style={{ display: "flex", gap: ".75rem", flexWrap: "wrap" }}>
          <button type="submit" disabled={busy}>{busy ? "Checking…" : "Check"}</button>
          {camera === "on"
            ? <button type="button" className="secondary" onClick={stopCamera}>Stop camera</button>
            : <button type="button" className="secondary" onClick={startCamera} disabled={busy}>Scan with camera</button>}
        </div>
        {camera === "unavailable" ? <p className="notice">The camera reader is not available on this device. Type the pass number instead.</p> : null}
        <video ref={video} muted playsInline aria-label="Camera view for scanning" style={{ display: camera === "on" ? "block" : "none", width: "100%", borderRadius: ".5rem" }} />
      </form>

      {scan?.ok === false ? <Blocked what={`Checking at ${gateName}`} denial={scan} /> : null}

      {ok && r ? (
        <EntryResultView r={r} tz={tz} passLabel={ok.pass ? `${ok.pass.number} (${ok.pass.kind === "phone" ? "phone" : "card"})` : undefined}>
          {ok.holders.length ? (
            <p className="notice">An access authority can set aside some of these reasons: {ok.holders.join(", ")}. Octra has not told them; contact them directly.</p>
          ) : null}
          <p className="muted">Checked at {new Date(ok.evaluatedAt).toLocaleTimeString("en-GB", { timeZone: tz })}
            {stale ? "" : ` · act within ${Math.max(0, Math.ceil((STALE_MS - age) / 60_000))} min`}</p>
        </EntryResultView>
      ) : null}

      {ok && r && stale ? (
        <p className="notice notice-blocked">This result is more than five minutes old. Scan again for a current answer before letting anyone through.</p>
      ) : null}

      {ok && r && !stale ? (
        <ActionForm key={formKey} action={recordGateAction} what="Recording what happened" submitLabel="Record">
          <input type="hidden" name="key" value={formKey} />
          <input type="hidden" name="evaluation_id" value={ok.evaluationId} />
          <fieldset className="stack"><legend>Direction</legend>
            <label className="inline"><input type="radio" name="direction" value="in" checked={direction === "in"} onChange={() => setDirection("in")} /> Coming in</label>
            <label className="inline"><input type="radio" name="direction" value="out" checked={direction === "out"} onChange={() => setDirection("out")} /> Going out</label>
          </fieldset>
          <fieldset className="stack"><legend>Identity</legend>
            <label className="inline"><input type="radio" name="identity" value="photo_id" required /> I checked a photo ID against the person</label>
            <label className="inline"><input type="radio" name="identity" value="known_to_operator" /> I know this person</label>
            <label className="inline"><input type="radio" name="identity" value="not_checked" /> Not checked</label>
          </fieldset>
          <p className="muted">Record only how you checked. Never note the document&apos;s details.</p>
          <fieldset className="stack"><legend>What you did</legend>
            {direction === "out" || r.outcome !== "do_not_admit"
              ? <label className="inline"><input type="radio" name="action" value="admitted" required /> {direction === "in" ? "Let them in" : "Let them out"}</label> : null}
            <label className="inline"><input type="radio" name="action" value="refused" required /> Refused</label>
            <label className="inline"><input type="radio" name="action" value="referred" /> Referred to an access authority</label>
          </fieldset>
          {r.outcome === "admit_with_escort" && direction === "in" ? <label>Escort&apos;s name<input name="escort" defaultValue={r.visit?.conditions?.escort ?? ""} /></label> : null}
          <label>{r.outcome === "check" ? "Who you checked with and what they said" : "Note (optional)"}<textarea name="note" rows={2} /></label>
        </ActionForm>
      ) : null}

      {scan ? <button type="button" className="secondary" onClick={next}>Next person</button> : null}
    </div>
  );
}
