/* FACEOFF Lax Stats - self-removing service worker (kill switch)
   Any device still controlled by an older service worker will fetch this on its
   next visit, which clears all caches, unregisters the worker, and reloads the
   page so the current app loads fresh from the server. No caching is kept. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => {
  e.waitUntil((async () => {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
    } catch (_) {}
    try { await self.registration.unregister(); } catch (_) {}
    try {
      const clients = await self.clients.matchAll({ type: "window" });
      clients.forEach((c) => { try { c.navigate(c.url); } catch (_) {} });
    } catch (_) {}
  })());
});
// Pass all requests straight through to the network; cache nothing.
self.addEventListener("fetch", () => {});
