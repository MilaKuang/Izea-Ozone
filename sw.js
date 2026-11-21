const CACHE = "repack-ledger-v46";
// the card name reader is large and rarely changes, so it lives in its own cache that app updates keep
const OCR_CACHE = "repack-ocr-1";
const ASSETS = ["./", "./index.html", "./zxing.min.js", "./supabase.js", "./config.js", "./manifest.webmanifest", "./icon-180.png", "./icon-192.png", "./icon-512.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE && k !== OCR_CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  if (e.request.method !== "GET" || new URL(e.request.url).origin !== location.origin) return;
  // card name reader: cache first, so it works with no signal once it has loaded one time
  if (new URL(e.request.url).pathname.includes("/ocr/")) {
    e.respondWith(caches.open(OCR_CACHE).then(c => c.match(e.request.url).then(hit => hit || fetch(e.request.url).then(res => { if (res.ok) c.put(e.request.url, res.clone()); return res; }))));
    return;
  }
  // network first so updates arrive, cache fallback so it works offline
  e.respondWith(
    fetch(e.request.url, { cache: "no-cache", credentials: "same-origin" }).then(res => {
      if (!res.ok) throw new Error("bad status");
      const copy = res.clone();
      caches.open(CACHE).then(c => c.put(e.request, copy));
      return res;
    }).catch(() => caches.match(e.request).then(r => r || caches.match("./index.html")))
  );
});
