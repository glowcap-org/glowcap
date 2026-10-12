// Self-unregistering service worker.
//
// This app ships no service worker. This file exists only to clean up stale
// SW registrations from other apps that ran on this dev origin
// (commonly http://127.0.0.1:5173). Without it, the browser keeps polling
// `/sw.js` for an "update" forever, and Vite's @deno/vite-plugin tries to
// resolve the URL as a Deno module and emits a long WASM-internal stack
// trace on every poll.
//
// On activation, this worker unregisters itself and instructs every client
// page to reload, which clears the registration cleanly. After one reload
// per browser, the polling stops.

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      await self.registration.unregister();
      const clients = await self.clients.matchAll({ type: "window" });
      for (const client of clients) {
        client.navigate(client.url);
      }
    })(),
  );
});
