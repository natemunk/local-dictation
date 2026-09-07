// Pure service-worker routing decisions. Imported by sw.js (registered as a
// module worker) and exercised directly by the unit tests.

export const CACHE_NAME = "dictation-inbox-shell-v3";

export const SHELL_URL = "/app/index.html";

/** Everything the service worker is allowed to precache and serve from cache. */
export const SHELL_ASSETS = Object.freeze([
  "/app/index.html",
  "/app/app.css",
  "/app/app.js",
  "/app/manifest.webmanifest",
  "/app/lib/api.js",
  "/app/lib/db.js",
  "/app/lib/diagnostics.js",
  "/app/lib/format.js",
  "/app/lib/fragment.js",
  "/app/lib/live-stream.js",
  "/app/lib/pcm-capture.js",
  "/app/lib/pcm-worklet.js",
  "/app/lib/recorder.js",
  "/app/lib/search.js",
  "/app/lib/sw-routing.js",
  "/app/lib/sync.js",
  "/app/lib/uuid.js",
  "/app/icon-192.png",
  "/app/icon-512.png",
  "/app/icon-maskable-512.png",
  "/app/apple-touch-icon.png",
]);

const SHELL_ASSET_SET = new Set(SHELL_ASSETS);

/** Navigation paths that all resolve to the same cached shell document. */
const SHELL_ROUTES = new Set(["/app", "/app/", "/app/import", "/app/import/"]);

/**
 * Decide what the fetch handler should do with a request.
 *
 * @param {{ method?: string, url: string }} request
 * @param {string} scopeOrigin origin the service worker is registered on
 * @returns {{ type: "passthrough" } | { type: "shell", cacheKey: string }
 *   | { type: "asset", cacheKey: string }}
 */
export function routeRequest(request, scopeOrigin) {
  const passthrough = { type: "passthrough" };

  const method = (request?.method ?? "GET").toUpperCase();
  if (method !== "GET") return passthrough;

  let url;
  try {
    url = new URL(request.url, scopeOrigin);
  } catch {
    return passthrough;
  }

  if (url.origin !== new URL(scopeOrigin).origin) return passthrough;

  // The API surface is never touched by the service worker.
  if (url.pathname === "/v1" || url.pathname.startsWith("/v1/")) return passthrough;

  if (SHELL_ROUTES.has(url.pathname)) {
    // Import links carry their payload in the fragment; the fragment never
    // reaches the cache because the shell document is the only cache key.
    return { type: "shell", cacheKey: SHELL_URL };
  }

  // A fragment on a non-navigation request must never become a cache key.
  if (url.hash !== "") return passthrough;

  if (url.search !== "") return passthrough;

  if (SHELL_ASSET_SET.has(url.pathname)) {
    return { type: "asset", cacheKey: url.pathname };
  }

  return passthrough;
}

/** True when a cache name belongs to an older revision of the shell cache. */
export function isStaleCacheName(name) {
  return typeof name === "string"
    && name.startsWith("dictation-inbox-shell-")
    && name !== CACHE_NAME;
}
