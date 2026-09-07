import { describe, expect, it } from "vitest";
import {
  CACHE_NAME,
  SHELL_ASSETS,
  SHELL_URL,
  isStaleCacheName,
  routeRequest,
} from "../../public/app/lib/sw-routing.js";

const ORIGIN = "https://dictate.example.com";

function route(url: string, method = "GET") {
  return routeRequest({ method, url: new URL(url, ORIGIN).toString() }, ORIGIN);
}

describe("routeRequest", () => {
  it("never intercepts the API surface", () => {
    for (const path of [
      "/v1/transcriptions",
      "/v1/history",
      "/v1/history/manifest",
      "/v1/history/operations",
      "/v1/healthz",
      "/v1",
    ]) {
      expect(route(path)).toEqual({ type: "passthrough" });
    }
  });

  it("never intercepts a non-GET request", () => {
    for (const method of ["POST", "PUT", "DELETE", "HEAD", "PATCH"]) {
      expect(route("/app/app.css", method)).toEqual({ type: "passthrough" });
      expect(route("/app/", method)).toEqual({ type: "passthrough" });
    }
  });

  it("never intercepts another origin", () => {
    expect(routeRequest({ method: "GET", url: "https://elsewhere.example/app/app.css" }, ORIGIN))
      .toEqual({ type: "passthrough" });
  });

  it("serves the shell for both navigation routes", () => {
    for (const path of ["/app", "/app/", "/app/import", "/app/import/"]) {
      expect(route(path)).toEqual({ type: "shell", cacheKey: SHELL_URL });
    }
  });

  it("serves the shell, never a fragment-keyed entry, for an import link", () => {
    const decision = route("/app/import#v=1&id=abc&text=secret");
    expect(decision).toEqual({ type: "shell", cacheKey: SHELL_URL });
    expect(JSON.stringify(decision)).not.toContain("secret");
  });

  it("serves every precached shell asset cache-first", () => {
    for (const asset of SHELL_ASSETS) {
      expect(route(asset)).toEqual({ type: "asset", cacheKey: asset });
    }
  });

  it("passes through anything under /app/ that is not a shell asset", () => {
    for (const path of ["/app/sw.js", "/app/unknown.js", "/app/lib/nope.js", "/other"]) {
      expect(route(path)).toEqual({ type: "passthrough" });
    }
  });

  it("never caches a request that carries a query string or a fragment", () => {
    expect(route("/app/app.css?v=2")).toEqual({ type: "passthrough" });
    expect(route("/app/app.css#anchor")).toEqual({ type: "passthrough" });
  });

  it("passes through an unparseable url instead of throwing", () => {
    expect(routeRequest({ method: "GET", url: "::::" }, ORIGIN)).toEqual({ type: "passthrough" });
  });

  it("defaults a missing method to GET", () => {
    expect(routeRequest({ url: `${ORIGIN}/app/app.css` }, ORIGIN))
      .toEqual({ type: "asset", cacheKey: "/app/app.css" });
  });
});

describe("cache naming", () => {
  it("is versioned", () => {
    expect(CACHE_NAME).toMatch(/^dictation-inbox-shell-v\d+$/);
  });

  it("treats only other shell caches as stale", () => {
    expect(isStaleCacheName("dictation-inbox-shell-v0")).toBe(true);
    expect(isStaleCacheName(CACHE_NAME)).toBe(false);
    expect(isStaleCacheName("some-other-cache")).toBe(false);
    expect(isStaleCacheName(undefined as any)).toBe(false);
  });
});

describe("shell asset list", () => {
  it("contains the document, the styles, every module and the icons", () => {
    expect(SHELL_ASSETS).toContain("/app/index.html");
    expect(SHELL_ASSETS).toContain("/app/app.css");
    expect(SHELL_ASSETS).toContain("/app/app.js");
    expect(SHELL_ASSETS).toContain("/app/manifest.webmanifest");
    expect(SHELL_ASSETS.filter((asset: string) => asset.startsWith("/app/lib/")).length)
      .toBeGreaterThanOrEqual(8);
    expect(SHELL_ASSETS.some((asset: string) => asset.endsWith(".png"))).toBe(true);
  });

  it("never lists an API path", () => {
    expect(SHELL_ASSETS.some((asset: string) => asset.startsWith("/v1"))).toBe(false);
  });
});
