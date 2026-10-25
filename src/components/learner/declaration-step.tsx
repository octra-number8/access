"use client";
// Adapted from OCTRA Induct (src/components/participant/declaration-step.tsx), D-015.
// Typed name (P3-8). Drawn signatures are not offered until image storage is decided.

import { useState } from "react";

export function DeclarationStep({ items, signingAs, busy, problem, onComplete }: {
  items: Array<{ key: string; text: string }>; signingAs: string; busy: boolean; problem: string | null;
  onComplete: (confirmedKeys: string[], typedName: string) => void;
}) {
  const [ticked, setTicked] = useState<Record<string, boolean>>({});
  const [name, setName] = useState("");
  const [error, setError] = useState<string | null>(null);

  function submit(event: React.FormEvent) {
    event.preventDefault();
    if (items.some((i) => !ticked[i.key])) return setError("Tick every box to confirm.");
    if (name.trim().length < 2) return setError("Type your full name.");
    setError(null);
    onComplete(items.map((i) => i.key), name.trim());
  }

  return (
    <form onSubmit={submit} noValidate className="flex flex-col gap-4">
      <h2 className="text-2xl font-extrabold text-ink">Declaration</h2>
      <p className="rounded-md border border-line bg-surface px-4 py-3 text-body">Signing as <span className="font-semibold text-ink">{signingAs}</span></p>
      {items.map((item) => (
        <label key={item.key} className="flex min-h-12 items-start gap-3 text-base text-ink">
          <input type="checkbox" checked={!!ticked[item.key]} onChange={(e) => setTicked((t) => ({ ...t, [item.key]: e.target.checked }))}
                 className="mt-1 size-5 shrink-0" />
          {item.text}
        </label>
      ))}
      <label className="flex flex-col gap-1 text-base font-semibold text-ink">
        Type your full name
        <input value={name} onChange={(e) => setName(e.target.value)} autoComplete="name"
               className="min-h-12 rounded-md border border-border-strong bg-surface px-3 text-base font-normal text-body" />
      </label>
      {(error ?? problem) && <p role="alert" tabIndex={-1} className="rounded-md bg-warning-subtle px-4 py-3 text-sm text-ink">{error ?? problem}</p>}
      <button type="submit" disabled={busy}
              className="min-h-12 rounded-md bg-brand px-4 text-base font-semibold text-white hover:bg-brand-hover disabled:opacity-60">
        {busy ? "Saving…" : "Sign and finish"}
      </button>
    </form>
  );
}
