// What a gate device keeps between visits (7d, 7d-2): the manifest and manual entries in the page's
// storage, and the gate page's offline copy held by the service worker (public/gate-sw.js).
// Browser-only.

export const manifestKey = (gate: string) => `octra.manifest.${gate}`;
export const entriesKey = (gate: string) => `octra.fallback.${gate}`;
const GATE_CACHES = ["octra-gate-page-v1", "octra-gate-files-v1"];

/** Registers the gate's service worker and asks it to save this page and the files it used.
 *  Production builds only: in development the files change on every edit. */
export async function keepGatePageOffline(): Promise<void> {
  if (process.env.NODE_ENV !== "production" || !("serviceWorker" in navigator)) return;
  const reg = await navigator.serviceWorker.register("/gate-sw.js", { scope: "/gate" });
  // Not navigator.serviceWorker.ready: a page reached by an in-app link from outside /gate (from
  // sign-in, say) never matches the scope, so it would wait for ever.
  const worker = reg.active ?? reg.waiting ?? reg.installing;
  if (!worker) return;
  if (worker.state !== "activated") {
    await new Promise<void>((resolve) => worker.addEventListener("statechange", () => { if (worker.state === "activated") resolve(); }));
  }
  const files = performance.getEntriesByType("resource").map((e) => e.name)
    .filter((u) => { const p = new URL(u).pathname; return p.startsWith("/_next/static/") || p.startsWith("/brand/"); });
  worker.postMessage({ type: "save", page: location.href, files });
}

/** On sign-out: the gate page's offline copy and every manifest go, as both are for the person
 *  signed in. Manual entries not yet uploaded stay: they are the venue's record of an outage and
 *  must still be uploaded and checked (Q202). */
export async function clearGateDevice(): Promise<void> {
  try {
    for (const k of Object.keys(localStorage)) if (k.startsWith("octra.manifest.")) localStorage.removeItem(k);
  } catch { /* storage unavailable */ }
  try {
    if ("caches" in window) await Promise.all(GATE_CACHES.map((c) => caches.delete(c)));
  } catch { /* nothing saved */ }
}
