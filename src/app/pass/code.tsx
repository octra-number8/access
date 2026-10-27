"use client";

import { useEffect, useState } from "react";
import { Qr } from "@/components/Qr";
import { phoneCode, type PhoneCode } from "./actions";

// The changing code (P7-3): fetched fresh every 30 seconds. A code the phone could not
// refresh is hidden rather than shown stale; the gate would not accept it anyway.
export function PhonePassCode({ venueId }: { venueId: string }) {
  const [code, setCode] = useState<(PhoneCode & { at: number }) | null>(null);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    let stopped = false;
    const load = async () => {
      let wait = 5_000;
      try {
        const c = await phoneCode(venueId);
        if (stopped) return;
        setCode({ ...c, at: Date.now() });
        if (c.ok) wait = c.seconds_left * 1000 + 300;
      } catch {
        // No connection: keep the last code until it is too old, then hide it.
      }
      if (!stopped) timer = setTimeout(load, wait);
    };
    load();
    const tick = setInterval(() => setNow(Date.now()), 1000);
    return () => { stopped = true; clearTimeout(timer); clearInterval(tick); };
  }, [venueId]);

  if (!code) return <p>Loading your code…</p>;
  if (!code.ok) return <p className="notice notice-blocked">{code.reason}</p>;
  const left = Math.ceil((code.at + code.seconds_left * 1000 - now) / 1000);
  // The gate accepts the current and the previous code: 30 seconds beyond its own.
  if (left < -25) {
    return <p className="notice notice-blocked">No connection: your code cannot refresh. At the gate, give your pass number, {code.pass_number}, and show photo ID.</p>;
  }
  return (
    <div className="stack" style={{ justifyItems: "center", textAlign: "center" }}>
      <Qr value={code.payload} label={`Pass ${code.pass_number}`} size={260} />
      <p style={{ fontSize: "1.5rem", fontWeight: 800, color: "var(--octra-ink-900)", margin: 0 }}>{code.pass_number}</p>
      <p className="muted" aria-live="off">{left > 0 ? `Code changes in ${left} s` : "Refreshing…"}</p>
    </div>
  );
}
