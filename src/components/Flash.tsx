"use client";

import { usePathname } from "next/navigation";
import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";

// A success message outlives its form. After an action succeeds the page is re-rendered from the
// database, and a form whose reason to exist has gone (a record now ended, a row now retired) is
// removed with its message. ActionForm hands the message here when that happens; it stays at the
// foot of the screen, on the page it came from, until dismissed or the person moves on.

interface Kept { id: number; message: string; detail?: string; path: string }
type Keep = (message: string, detail: string | undefined, path: string) => void;

const FlashContext = createContext<Keep | null>(null);

export function useKeepMessage(): Keep | null {
  return useContext(FlashContext);
}

export function FlashProvider({ children }: { children: ReactNode }) {
  const path = usePathname();
  const [kept, setKept] = useState<Kept[]>([]);
  const keep = useCallback<Keep>((message, detail, from) => {
    setKept((k) => [...k.filter((x) => x.path === from), { id: Date.now() + Math.random(), message, detail, path: from }].slice(-3));
  }, []);
  // Messages belong to the page they came from: leaving it drops them.
  useEffect(() => { setKept((k) => k.filter((x) => x.path === path)); }, [path]);
  const shown = kept.filter((k) => k.path === path);
  return (
    <FlashContext.Provider value={keep}>
      {children}
      {/* Room at the end of the page, so the bar never hides the last thing on it. */}
      {shown.length ? <div aria-hidden="true" style={{ height: `${shown.length * 4}rem` }} /> : null}
      {/* Always present, so screen readers announce what is added to it. */}
      <div className="flash no-print" aria-live="polite">
        {shown.map((k) => (
          <p key={k.id} className="notice notice-done">
            {k.message}
            {k.detail ? <span className="muted"> {k.detail}</span> : null}
            <button type="button" className="secondary" onClick={() => setKept((x) => x.filter((y) => y.id !== k.id))}>
              Dismiss<span className="sr-only">: {k.message}</span>
            </button>
          </p>
        ))}
      </div>
    </FlashContext.Provider>
  );
}
