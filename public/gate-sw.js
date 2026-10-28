// The gate page's offline copy (7d-2, D-024). Registered by the gate page with scope /gate, so it
// sees only the gate's own requests. It keeps two things and nothing else:
//   - the gate page itself (/gate?point=…), as last loaded online: venue and gate names only. The
//     manifest and the manual entries live in the page's own storage, as before (7d).
//   - the app's versioned static files (/_next/static, /brand) the page needs to run.
// The page is fetched from the network first; the saved copy is used only when the network fails,
// and the page then starts in offline mode (invariant 11: nothing cached is a current answer).
// Every other request goes to the network untouched. Signing out deletes both caches.
const PAGES = "octra-gate-page-v1";
const FILES = "octra-gate-files-v1";

const isFile = (url) => url.origin === self.location.origin && (url.pathname.startsWith("/_next/static/") || url.pathname.startsWith("/brand/"));
const isGatePage = (url) => url.origin === self.location.origin && url.pathname === "/gate";
const pageKey = (url) => `/gate?point=${new URL(url).searchParams.get("point") ?? ""}`;

const OFFLINE_HTML = `<!doctype html><html lang="en-GB"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Gate · Octra Access</title><style>body{font-family:system-ui,sans-serif;margin:0;padding:16px;background:#fff;color:#111}
.b{background:#8a1c1c;color:#fff;font-weight:800;padding:10px 16px;border-radius:6px;font-size:1.15rem}</style></head><body>
<p class="b" role="status">OFFLINE — this gate page was not saved on this device</p>
<p>Octra cannot be reached, and this device has no saved copy of this gate's page. No live checks are possible.</p>
<p><strong>Follow the venue's outage procedure and record every entry in the paper log.</strong></p>
<p><a href="">Try again</a></p></body></html>`;

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k.startsWith("octra-gate-") && k !== PAGES && k !== FILES) await caches.delete(k);
  await self.clients.claim();
})()));

// Fetches a gate page and keeps it only if it really is the gate page (not a sign-in redirect).
async function savePage(url) {
  const r = await fetch(url, { credentials: "same-origin", cache: "no-store" });
  if (r.ok && !r.redirected && isGatePage(new URL(r.url))) await (await caches.open(PAGES)).put(pageKey(url), r.clone());
  return r;
}

async function saveFiles(urls) {
  const c = await caches.open(FILES);
  await Promise.all(urls.map(async (u) => {
    const url = new URL(u, self.location.origin);
    if (!isFile(url) || await c.match(url.href)) return;
    try { const r = await fetch(url.href); if (r.ok) await c.put(url.href, r); } catch { /* next time */ }
  }));
}

// From the page once it has loaded: save it (it may have been reached without a full load) and
// the files it used.
self.addEventListener("message", (e) => {
  const d = e.data ?? {};
  if (d.type !== "save" || typeof d.page !== "string" || !Array.isArray(d.files)) return;
  const page = new URL(d.page, self.location.origin);
  e.waitUntil(Promise.all([isGatePage(page) ? savePage(page.href).catch(() => null) : null, saveFiles(d.files)]));
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET") return;
  if (e.request.mode === "navigate" && isGatePage(url)) {
    e.respondWith(savePage(url.href).catch(async () =>
      (await (await caches.open(PAGES)).match(pageKey(url.href)))
        ?? new Response(OFFLINE_HTML, { status: 503, headers: { "content-type": "text/html; charset=utf-8" } })));
    return;
  }
  if (isFile(url)) {
    // Versioned by name, so a saved copy is always the right one.
    e.respondWith((async () => {
      const c = await caches.open(FILES);
      const hit = await c.match(url.href);
      if (hit) return hit;
      const r = await fetch(e.request);
      if (r.ok) await c.put(url.href, r.clone());
      return r;
    })());
  }
});
