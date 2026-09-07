// Service worker for the Dictation shell.
//
// It caches the shell (HTML, CSS, ES modules, manifest, icons) under a
// versioned cache name and nothing else. `/v1/*` never reaches this cache, and
// neither does any request that carries a query string or a fragment.

import {
  CACHE_NAME,
  SHELL_ASSETS,
  isStaleCacheName,
  routeRequest,
} from "./lib/sw-routing.js";

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    await cache.addAll(SHELL_ASSETS);
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter(isStaleCacheName).map((name) => caches.delete(name)));
    await self.clients.claim();
  })());
});

async function serveFromShellCache(cacheKey) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(cacheKey);
  if (cached !== undefined) return cached;

  try {
    const response = await fetch(cacheKey);
    if (response.ok) await cache.put(cacheKey, response.clone());
    return response;
  } catch {
    return new Response("Dictation is offline.", {
      status: 503,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }
}

self.addEventListener("fetch", (event) => {
  const decision = routeRequest(event.request, self.location.origin);
  if (decision.type === "passthrough") return;
  event.respondWith(serveFromShellCache(decision.cacheKey));
});
