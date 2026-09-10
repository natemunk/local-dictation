import { describe, expect, it, vi } from "vitest";

import {
  CLOUD_MODEL,
  MAX_AUDIO_BYTES,
  MAX_HISTORY_OPERATIONS_BYTES,
  createHistoryProxy,
  createMacStreamProxy,
  createMacTranscriber,
  createWorkersAiTranscriber,
  defaultRuntime,
  handleRequest,
  type GatewayRuntime,
  type HistoryProxyRequest,
  type HistoryProxyResult,
  type RequestFetcher,
} from "../src/gateway";
import {
  STREAM_PROTOCOL,
  createStreamTicketAuthority,
} from "../src/streaming";

const AUDIO = new Uint8Array([0, 1, 2, 3]).buffer;
const REQUEST_ID = "00000000-0000-4000-8000-000000000123";
const SAFE_LOG_KEYS = new Set([
  "cleanup",
  "client",
  "cloud_fallback_allowed",
  "duration_bucket",
  "event",
  "failure_code",
  "fallback_reason",
  "history_state",
  "latency_ms",
  "media_type",
  "mode",
  "request_id",
  "route",
  "size_bucket",
  "status",
]);

function expectPrivacySafeLogs(
  logs: Array<{ level: string; event: Readonly<Record<string, string | number | boolean>> }>,
  forbidden: readonly string[] = [],
): void {
  expect(logs.length).toBeGreaterThan(0);
  for (const log of logs) {
    for (const key of Object.keys(log.event)) expect(SAFE_LOG_KEYS.has(key)).toBe(true);
  }
  const serialized = JSON.stringify(logs);
  for (const value of forbidden) expect(serialized).not.toContain(value);
}

type MacInput = Parameters<GatewayRuntime["transcribeOnMac"]>[0];

const MAC_ORIGIN = {
  originUrl: "https://mac.example.com",
  accessClientId: "client-id",
  accessClientSecret: "client-secret",
} as const;

function audioInput(overrides: Record<string, unknown> = {}): MacInput {
  return {
    bytes: AUDIO,
    allowsCloudFallback: true,
    client: "shortcut",
    contentType: "audio/mp4",
    durationSeconds: 1,
    language: "en",
    mode: "clean",
    requestId: "request-abc",
    ...overrides,
  } as MacInput;
}

function audioRequest(headers: Record<string, string> = {}, body: ArrayBuffer = AUDIO): Request {
  return new Request("https://dictation.example.com/v1/transcriptions", {
    method: "POST",
    headers: {
      "Content-Type": "audio/mp4",
      "X-Request-ID": REQUEST_ID,
      "X-Allow-Cloud-Fallback": "true",
      "X-Audio-Duration-Seconds": "1.2",
      "X-Dictation-Mode": "clean",
      ...headers,
    },
    body,
  });
}

function historyRequest(
  path: string,
  init: { method?: string; headers?: Record<string, string>; body?: BodyInit } = {},
): Request {
  const headers: Record<string, string> = {
    "X-Dictation-Client": "pwa",
    "X-Request-ID": REQUEST_ID,
    ...(init.headers ?? {}),
  };
  return new Request(`https://dictation.example.com${path}`, {
    method: init.method ?? "GET",
    headers,
    ...(init.body === undefined ? {} : { body: init.body }),
  });
}

function operationsRequest(body: unknown, headers: Record<string, string> = {}): Request {
  return historyRequest("/v1/history/operations", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function runtime(overrides: Partial<GatewayRuntime> = {}) {
  const logs: Array<{ level: string; event: Readonly<Record<string, string | number | boolean>> }> = [];
  const transcribeOnMac = vi.fn(async (_input: MacInput) => ({
    ok: true,
    transcript: {
      text: "local text",
      route: "mac_local",
      cleanup: "deterministic",
      latencyMs: 40,
      fallbackReason: null,
      historyState: "saved_on_mac",
    },
  }) as const);
  const transcribeInCloud = vi.fn(async () => ({
    text: "cloud text",
    route: "cloud_fallback",
    cleanup: "none",
    latencyMs: 0,
    fallbackReason: null,
    historyState: "pending_device_sync",
  }) as const);
  const historyRequests: HistoryProxyRequest[] = [];
  const proxyHistory = vi.fn(async (input: HistoryProxyRequest): Promise<HistoryProxyResult> => {
    historyRequests.push(input);
    return { ok: true, status: 200, body: '{"revision":42,"entries":[]}' };
  });
  const assetRequests: Request[] = [];
  const fetchAsset = vi.fn(async (request: Request): Promise<Response> => {
    assetRequests.push(request);
    const path = new URL(request.url).pathname;
    if (path === "/app/index.html") {
      return new Response("<!doctype html><title>shell</title>", {
        status: 200,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }
    if (path === "/app/app.0a1b2c3d.js" || path === "/app/sw.js") {
      return new Response("export {};", {
        status: 200,
        headers: { "Content-Type": "text/javascript; charset=utf-8" },
      });
    }
    return new Response("missing", { status: 404 });
  });

  const value: GatewayRuntime = {
    now: () => 1_050,
    requestId: () => REQUEST_ID,
    log: (level, event) => logs.push({ level, event }),
    transcribeOnMac,
    transcribeInCloud,
    proxyHistory,
    issueStreamTicket: vi.fn(async (input) => ({
      requestId: input.requestId,
      protocol: "local-dictation.v1",
      ticket: "ld-ticket.test.signature",
      streamPath: "/stream",
      expiresAt: 31_000,
    }) as const),
    proxyStream: vi.fn(async () => ({
      requestId: REQUEST_ID,
      response: new Response(null, { status: 503 }),
    })),
    fetchAsset,
    ...overrides,
  };
  return {
    value,
    logs,
    transcribeOnMac,
    transcribeInCloud,
    proxyHistory,
    historyRequests,
    fetchAsset,
    assetRequests,
  };
}

async function errorBody(response: Response): Promise<{ error: { code: string }; revision?: number }> {
  return (await response.json()) as { error: { code: string }; revision?: number };
}

describe("iPhone gateway", () => {
  it("issues a no-store short-lived stream ticket only for the PWA client", async () => {
    const testRuntime = runtime();
    const request = new Request("https://dictation.example.com/v1/stream-tickets", {
      method: "POST",
      headers: {
        "X-Dictation-Client": "pwa",
        "X-Request-ID": REQUEST_ID,
        "X-Dictation-Mode": "clean",
        "X-Allow-Cloud-Fallback": "true",
      },
    });
    const response = await handleRequest(request, testRuntime.value);

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect((await response.json()) as object).toEqual({
      request_id: REQUEST_ID,
      protocol: STREAM_PROTOCOL,
      ticket: "ld-ticket.test.signature",
      stream_path: "/stream",
      expires_at: 31_000,
    });

    const shortcut = new Request(request, {
      headers: {
        ...Object.fromEntries(request.headers),
        "X-Dictation-Client": "shortcut",
      },
    });
    expect((await handleRequest(shortcut, testRuntime.value)).status).toBe(400);
  });

  it("signs, verifies, expires, and rejects tampered stream tickets", async () => {
    let current = 1_000;
    const authority = createStreamTicketAuthority("a".repeat(64), () => current);
    const grant = await authority.issue({
      requestId: REQUEST_ID,
      mode: "literal",
      allowsCloudFallback: false,
    });
    await expect(authority.verifyProtocols(`${STREAM_PROTOCOL}, ${grant.ticket}`)).resolves.toMatchObject({
      id: REQUEST_ID,
      mode: "literal",
      fallback: false,
      client: "pwa",
    });

    const last = grant.ticket.at(-1) === "a" ? "b" : "a";
    await expect(
      authority.verifyProtocols(`${STREAM_PROTOCOL}, ${grant.ticket.slice(0, -1)}${last}`),
    ).rejects.toMatchObject({ code: "invalid" });

    current = grant.expiresAt;
    await expect(authority.verifyProtocols(`${STREAM_PROTOCOL}, ${grant.ticket}`))
      .rejects.toMatchObject({ code: "expired" });
  });

  it("proxies a valid same-origin WebSocket ticket with only origin credentials", async () => {
    const authority = createStreamTicketAuthority("b".repeat(64), () => 2_000);
    const grant = await authority.issue({
      requestId: REQUEST_ID,
      mode: "clean",
      allowsCloudFallback: true,
    });
    let forwarded: Request | null = null;
    const proxy = createMacStreamProxy(MAC_ORIGIN, authority, async (request) => {
      forwarded = request;
      return new Response("origin response", { status: 200 });
    });
    const result = await proxy(new Request("https://dictation.example.com/stream", {
      headers: {
        "Origin": "https://dictation.example.com",
        "Upgrade": "websocket",
        "Sec-WebSocket-Protocol": `${STREAM_PROTOCOL}, ${grant.ticket}`,
      },
    }));

    expect(result.requestId).toBe(REQUEST_ID);
    expect(result.response.status).toBe(200);
    expect(forwarded).not.toBeNull();
    expect(new URL(forwarded!.url).pathname).toBe("/v1/stream");
    expect(forwarded!.headers.get("Sec-WebSocket-Protocol")).toBe(STREAM_PROTOCOL);
    expect(forwarded!.headers.get("X-Request-ID")).toBe(REQUEST_ID);
    expect(forwarded!.headers.get("X-Dictation-Transport")).toBe("stream-v1");
    expect(forwarded!.headers.get("CF-Access-Client-Id")).toBe("client-id");
    expect(forwarded!.headers.get("CF-Access-Client-Secret")).toBe("client-secret");
    expect(forwarded!.headers.get("Sec-WebSocket-Protocol")).not.toContain("ld-ticket");
  });

  it("refuses public WebSocket attempts without a valid same-origin ticket", async () => {
    const authority = createStreamTicketAuthority("c".repeat(64), () => 3_000);
    const fetcher = vi.fn(async () => new Response(null, { status: 200 }));
    const proxy = createMacStreamProxy(MAC_ORIGIN, authority, fetcher);

    await expect(proxy(new Request("https://dictation.example.com/stream", {
      headers: {
        "Origin": "https://dictation.example.com",
        "Upgrade": "websocket",
        "Sec-WebSocket-Protocol": STREAM_PROTOCOL,
      },
    }))).rejects.toMatchObject({ status: 401, code: "STREAM_TICKET_REFUSED" });
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("returns a no-store gateway health response at /v1/healthz", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      new Request("https://dictation.example.com/v1/healthz"),
      testRuntime.value,
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("X-Request-ID")).toBe(REQUEST_ID);
    await expect(response.json()).resolves.toEqual({
      status: "ok",
      service: "local-dictation-iphone-gateway",
      storage: "none",
    });
  });

  it("no longer exposes the unprotected /healthz path", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      new Request("https://dictation.example.com/healthz"),
      testRuntime.value,
    );

    expect(response.status).toBe(404);
    expect(await errorBody(response)).toMatchObject({ error: { code: "NOT_FOUND" } });
    expect(testRuntime.fetchAsset).not.toHaveBeenCalled();
  });

  it("uses the Mac result without invoking Workers AI", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(audioRequest(), testRuntime.value);

    expect(response.status).toBe(200);
    expect(testRuntime.transcribeOnMac).toHaveBeenCalledOnce();
    expect(testRuntime.transcribeInCloud).not.toHaveBeenCalled();
    await expect(response.json()).resolves.toEqual({
      request_id: REQUEST_ID,
      text: "local text",
      route: "mac_local",
      cleanup: "deterministic",
      latency_ms: 40,
      fallback_reason: null,
      history_state: "saved_on_mac",
    });
    expect(testRuntime.logs.at(-1)?.event).toMatchObject({
      route: "mac_local",
      size_bucket: "tiny",
    });
  });

  it("passes an unsaved Mac history state through unchanged", async () => {
    const testRuntime = runtime({
      transcribeOnMac: vi.fn(async () => ({
        ok: true,
        transcript: {
          text: "local text",
          route: "mac_local",
          cleanup: "none",
          latencyMs: 12,
          fallbackReason: null,
          historyState: "pending_device_sync",
        },
      }) as const),
    });
    const response = await handleRequest(audioRequest(), testRuntime.value);

    expect(response.status).toBe(200);
    expect((await response.json()) as { history_state: string }).toMatchObject({
      history_state: "pending_device_sync",
      route: "mac_local",
    });
  });

  it("automatically falls back to cloud transcription when the Mac is unavailable", async () => {
    const testRuntime = runtime({
      transcribeOnMac: vi.fn(async () => ({ ok: false, reason: "health_unreachable" }) as const),
    });
    const response = await handleRequest(audioRequest(), testRuntime.value);

    expect(response.status).toBe(200);
    expect(testRuntime.transcribeInCloud).toHaveBeenCalledOnce();
    await expect(response.json()).resolves.toEqual({
      request_id: REQUEST_ID,
      text: "cloud text",
      route: "cloud_fallback",
      cleanup: "none",
      latency_ms: 0,
      fallback_reason: "mac_offline",
      history_state: "pending_device_sync",
    });
    expect(testRuntime.logs.at(-1)?.event).toMatchObject({
      route: "cloud_fallback",
      size_bucket: "tiny",
    });
  });

  it("always reports pending_device_sync for cloud fallback", async () => {
    const testRuntime = runtime({
      transcribeOnMac: vi.fn(async () => ({ ok: false, reason: "health_unreachable" }) as const),
      transcribeInCloud: vi.fn(async () => ({
        text: "cloud text",
        route: "cloud_fallback",
        cleanup: "none",
        latencyMs: 0,
        fallbackReason: null,
        historyState: "saved_on_mac",
      }) as const),
    });
    const response = await handleRequest(audioRequest(), testRuntime.value);

    expect((await response.json()) as { history_state: string }).toMatchObject({
      history_state: "pending_device_sync",
    });
  });

  it.each(["shortcut", "pwa"])("accepts the %s dictation client and forwards it", async (client) => {
    const testRuntime = runtime();
    const response = await handleRequest(
      audioRequest({ "X-Dictation-Client": client }),
      testRuntime.value,
    );

    expect(response.status).toBe(200);
    expect(testRuntime.transcribeOnMac.mock.calls[0]?.[0]).toMatchObject({ client });
  });

  it("defaults the dictation client to shortcut when the header is absent", async () => {
    const testRuntime = runtime();
    await handleRequest(audioRequest(), testRuntime.value);

    expect(testRuntime.transcribeOnMac.mock.calls[0]?.[0]).toMatchObject({ client: "shortcut" });
  });

  it("rejects an unknown dictation client", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      audioRequest({ "X-Dictation-Client": "watch" }),
      testRuntime.value,
    );

    expect(response.status).toBe(400);
    expect(await errorBody(response)).toMatchObject({
      error: { code: "INVALID_DICTATION_CLIENT" },
    });
    expect(testRuntime.transcribeOnMac).not.toHaveBeenCalled();
  });

  it("does not use Workers AI when cloud fallback is disabled", async () => {
    const testRuntime = runtime({
      transcribeOnMac: vi.fn(async () => ({ ok: false, reason: "health_busy" }) as const),
    });
    const response = await handleRequest(
      audioRequest({ "X-Allow-Cloud-Fallback": "false" }),
      testRuntime.value,
    );

    expect(response.status).toBe(503);
    expect(testRuntime.transcribeInCloud).not.toHaveBeenCalled();
    expect(await errorBody(response)).toMatchObject({ error: { code: "MAC_UNAVAILABLE" } });
  });

  it("never falls back when the Mac rejects malformed audio", async () => {
    const testRuntime = runtime({
      transcribeOnMac: vi.fn(async () => ({ ok: false, reason: "origin_invalid_request" }) as const),
    });
    const response = await handleRequest(audioRequest(), testRuntime.value);

    expect(response.status).toBe(422);
    expect(testRuntime.transcribeInCloud).not.toHaveBeenCalled();
    expect(await errorBody(response)).toMatchObject({ error: { code: "INVALID_AUDIO" } });
  });

  it("never falls back when Mac-origin Access authentication fails", async () => {
    const testRuntime = runtime({
      transcribeOnMac: vi.fn(async () => ({
        ok: false,
        reason: "health_authentication_failed",
      }) as const),
    });
    const response = await handleRequest(audioRequest(), testRuntime.value);

    expect(response.status).toBe(503);
    expect(testRuntime.transcribeInCloud).not.toHaveBeenCalled();
    expect(await errorBody(response)).toMatchObject({ error: { code: "ORIGIN_AUTH_FAILED" } });
  });

  it("returns a stable no-store error when cloud fallback fails", async () => {
    const testRuntime = runtime({
      transcribeOnMac: vi.fn(async () => ({ ok: false, reason: "health_timeout" }) as const),
      transcribeInCloud: vi.fn(async () => {
        throw new Error("provider details that must not escape");
      }),
    });
    const response = await handleRequest(audioRequest(), testRuntime.value);

    expect(response.status).toBe(503);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    const body = await response.text();
    expect(body).not.toContain("provider details");
    expect(JSON.parse(body)).toEqual({
      error: {
        code: "CLOUD_FALLBACK_FAILED",
        message: "Cloud fallback is temporarily unavailable. Please try again.",
      },
      request_id: REQUEST_ID,
    });
    expectPrivacySafeLogs(testRuntime.logs, ["provider details"]);
    expect(testRuntime.logs.map((log) => log.event.event)).toContain("cloud_fallback_failed");
    expect(testRuntime.logs.at(-1)?.event).toMatchObject({
      event: "request_failed",
      failure_code: "CLOUD_FALLBACK_FAILED",
      request_id: REQUEST_ID,
    });
  });

  it.each([
    ["text/plain", 415, "UNSUPPORTED_AUDIO_TYPE"],
    ["audio/mp4", 400, "EMPTY_AUDIO"],
  ])("rejects invalid audio (%s)", async (type, expectedStatus, expectedCode) => {
    const testRuntime = runtime();
    const response = await handleRequest(audioRequest({ "Content-Type": type }, new ArrayBuffer(0)), testRuntime.value);

    expect(response.status).toBe(expectedStatus);
    expect(await errorBody(response)).toMatchObject({ error: { code: expectedCode } });
    expect(testRuntime.transcribeOnMac).not.toHaveBeenCalled();
    expect(testRuntime.transcribeInCloud).not.toHaveBeenCalled();
  });

  it("rejects declared oversized audio before reading the body", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      audioRequest({ "Content-Length": String(MAX_AUDIO_BYTES + 1) }),
      testRuntime.value,
    );

    expect(response.status).toBe(413);
    expect(await errorBody(response)).toMatchObject({ error: { code: "AUDIO_TOO_LARGE" } });
  });

  it("stops an undeclared streaming body at the audio byte limit", async () => {
    const testRuntime = runtime();
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(MAX_AUDIO_BYTES));
        controller.enqueue(new Uint8Array([1]));
        controller.close();
      },
    });
    const response = await handleRequest(
      new Request("https://dictation.example.com/v1/transcriptions", {
        method: "POST",
        headers: {
          "Content-Type": "audio/mp4",
          "X-Request-ID": REQUEST_ID,
          "X-Allow-Cloud-Fallback": "true",
          "X-Audio-Duration-Seconds": "1",
          "X-Dictation-Mode": "clean",
        },
        body,
      }),
      testRuntime.value,
    );

    expect(response.status).toBe(413);
    expect(await errorBody(response)).toMatchObject({ error: { code: "AUDIO_TOO_LARGE" } });
    expect(testRuntime.transcribeOnMac).not.toHaveBeenCalled();
  });

  it("rejects malformed duration and language metadata", async () => {
    const testRuntime = runtime();
    const badDuration = await handleRequest(
      audioRequest({ "X-Audio-Duration-Seconds": "not-a-number" }),
      testRuntime.value,
    );
    const badLanguage = await handleRequest(
      audioRequest({ "X-Transcription-Language": "../../secret" }),
      testRuntime.value,
    );

    expect(badDuration.status).toBe(400);
    expect(badLanguage.status).toBe(400);
  });

  it("requires the routing headers used by the Mac endpoint", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      new Request("https://dictation.example.com/v1/transcriptions", {
        method: "POST",
        headers: { "Content-Type": "audio/mp4" },
        body: AUDIO,
      }),
      testRuntime.value,
    );

    expect(response.status).toBe(400);
    expect(testRuntime.transcribeOnMac).not.toHaveBeenCalled();
  });

  it("logs an allowlisted request lifecycle without transcript or audio content", async () => {
    const secretTranscript = "sensitive transcript must stay out of logs";
    const testRuntime = runtime({
      transcribeOnMac: vi.fn(async () => ({
        ok: true,
        transcript: {
          text: secretTranscript,
          route: "mac_local",
          cleanup: "none",
          latencyMs: 10,
          fallbackReason: null,
          historyState: "saved_on_mac",
        },
      }) as const),
    });
    await handleRequest(audioRequest(), testRuntime.value);

    expectPrivacySafeLogs(testRuntime.logs, [secretTranscript, "AAECAw=="]);
    expect(testRuntime.logs.map((log) => log.event.event)).toEqual([
      "transcription_started",
      "transcription_input_validated",
      "mac_local_succeeded",
      "request_completed",
    ]);
    expect(testRuntime.logs.at(-1)?.event).toMatchObject({
      request_id: REQUEST_ID,
      route: "mac_local",
      status: 200,
      size_bucket: "tiny",
      duration_bucket: "short",
      client: "shortcut",
      mode: "clean",
    });
  });
});

describe("history proxy endpoints", () => {
  it("forwards a manifest response verbatim with no-store headers", async () => {
    const body = '{"revision":42,"entry_count":120,"pinned_count":3}';
    const testRuntime = runtime({
      proxyHistory: vi.fn(async () => ({ ok: true, status: 200, body }) as const),
    });
    const response = await handleRequest(
      historyRequest("/v1/history/manifest"),
      testRuntime.value,
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("X-Request-ID")).toBe(REQUEST_ID);
    expect(response.headers.get("Content-Type")).toBe("application/json; charset=utf-8");
    await expect(response.text()).resolves.toBe(body);
    expect(testRuntime.transcribeInCloud).not.toHaveBeenCalled();
    expect(testRuntime.fetchAsset).not.toHaveBeenCalled();
  });

  it("normalizes and forwards the snapshot page query", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      historyRequest("/v1/history?revision=42&cursor=118&limit=25&unexpected=x"),
      testRuntime.value,
    );

    expect(response.status).toBe(200);
    expect(testRuntime.historyRequests[0]).toMatchObject({
      kind: "page",
      client: "pwa",
      requestId: REQUEST_ID,
      search: "?revision=42&limit=25&cursor=118",
      body: null,
    });
  });

  it("forwards an operations batch body to the Mac", async () => {
    const forwardedRequests: HistoryProxyRequest[] = [];
    const testRuntime = runtime({
      proxyHistory: vi.fn(async (input: HistoryProxyRequest): Promise<HistoryProxyResult> => {
        forwardedRequests.push(input);
        return { ok: true, status: 200, body: '{"revision":43,"results":[]}' };
      }),
    });
    const response = await handleRequest(
      operationsRequest({
        operations: [{ op_id: "op-1", type: "import", entry_id: "entry-1", text: "hello" }],
      }),
      testRuntime.value,
    );

    expect(response.status).toBe(200);
    await expect(response.text()).resolves.toBe('{"revision":43,"results":[]}');
    const forwarded = forwardedRequests[0];
    expect(forwarded?.kind).toBe("operations");
    expect(forwarded?.client).toBe("pwa");
    expect(forwarded?.requestId).toBe(REQUEST_ID);
    expect(forwarded?.body).not.toBeNull();
    expect(new TextDecoder().decode(forwarded?.body ?? new ArrayBuffer(0))).toContain("op-1");
  });

  it.each([
    ["/v1/history/manifest", "GET"],
    ["/v1/history?revision=1", "GET"],
    ["/v1/history/operations", "POST"],
  ])("requires the pwa dictation client on %s", async (path, method) => {
    for (const client of [undefined, "shortcut", "watch"]) {
      const testRuntime = runtime();
      const headers: Record<string, string> = { "X-Request-ID": REQUEST_ID };
      if (client !== undefined) headers["X-Dictation-Client"] = client;
      const request = new Request(`https://dictation.example.com${path}`, {
        method,
        headers,
        ...(method === "POST"
          ? { body: JSON.stringify({ operations: [{ op_id: "a", type: "pin", entry_id: "b" }] }) }
          : {}),
      });
      const response = await handleRequest(request, testRuntime.value);

      expect(response.status).toBe(400);
      expect(await errorBody(response)).toMatchObject({ error: { code: "INVALID_REQUEST" } });
      expect(testRuntime.proxyHistory).not.toHaveBeenCalled();
    }
  });

  it.each([
    ["/v1/history/manifest", "POST"],
    ["/v1/history?revision=1", "DELETE"],
    ["/v1/history/operations", "GET"],
  ])("rejects the wrong method on %s", async (path, method) => {
    const testRuntime = runtime();
    const response = await handleRequest(
      historyRequest(path, method === "POST" ? { method, body: "{}" } : { method }),
      testRuntime.value,
    );

    expect(response.status).toBe(405);
    expect(await errorBody(response)).toMatchObject({ error: { code: "METHOD_NOT_ALLOWED" } });
    expect(testRuntime.proxyHistory).not.toHaveBeenCalled();
  });

  it.each([
    "/v1/history",
    "/v1/history?revision=",
    "/v1/history?revision=-1",
    "/v1/history?revision=1.5",
    "/v1/history?revision=abc",
    "/v1/history?revision=99999999999999999999",
    "/v1/history?revision=1&limit=0",
    "/v1/history?revision=1&limit=101",
    "/v1/history?revision=1&limit=ten",
    "/v1/history?revision=1&cursor=has%20space",
    `/v1/history?revision=1&cursor=${"a".repeat(65)}`,
  ])("rejects an invalid snapshot query (%s)", async (path) => {
    const testRuntime = runtime();
    const response = await handleRequest(historyRequest(path), testRuntime.value);

    expect(response.status).toBe(400);
    expect(await errorBody(response)).toMatchObject({ error: { code: "INVALID_REQUEST" } });
    expect(testRuntime.proxyHistory).not.toHaveBeenCalled();
  });

  it.each([
    ["not json at all", 400],
    ['{"operations":{}}', 400],
    ['{"operations":[]}', 400],
    ['{"operations":["nope"]}', 400],
    ['{"operations":[{"type":"pin","entry_id":"e"}]}', 400],
    ['{"operations":[{"op_id":"o","type":"archive","entry_id":"e"}]}', 400],
    ['{"operations":[{"op_id":"o","type":"pin"}]}', 400],
    ['{"operations":[{"op_id":"o","type":"edit","entry_id":"e","text":5}]}', 400],
  ])("rejects a malformed operations body (%s)", async (body, expectedStatus) => {
    const testRuntime = runtime();
    const response = await handleRequest(operationsRequest(body), testRuntime.value);

    expect(response.status).toBe(expectedStatus);
    expect(await errorBody(response)).toMatchObject({ error: { code: "INVALID_REQUEST" } });
    expect(testRuntime.proxyHistory).not.toHaveBeenCalled();
  });

  it("rejects more than one hundred operations", async () => {
    const testRuntime = runtime();
    const operations = Array.from({ length: 101 }, (_unused, index) => ({
      op_id: `op-${index}`,
      type: "pin",
      entry_id: `entry-${index}`,
    }));
    const response = await handleRequest(operationsRequest({ operations }), testRuntime.value);

    expect(response.status).toBe(413);
    expect(await errorBody(response)).toMatchObject({ error: { code: "PAYLOAD_TOO_LARGE" } });
    expect(testRuntime.proxyHistory).not.toHaveBeenCalled();
  });

  it("rejects an operation whose text exceeds the character limit", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      operationsRequest({
        operations: [{ op_id: "op-1", type: "edit", entry_id: "entry-1", text: "x".repeat(100_001) }],
      }),
      testRuntime.value,
    );

    expect(response.status).toBe(413);
    expect(await errorBody(response)).toMatchObject({ error: { code: "PAYLOAD_TOO_LARGE" } });
    expect(testRuntime.proxyHistory).not.toHaveBeenCalled();
  });

  it("rejects an operations body larger than two mebibytes", async () => {
    const testRuntime = runtime();
    const oversized = `{"operations":[{"op_id":"o","type":"edit","entry_id":"e","text":"${"x".repeat(
      MAX_HISTORY_OPERATIONS_BYTES,
    )}"}]}`;
    const response = await handleRequest(operationsRequest(oversized), testRuntime.value);

    expect(response.status).toBe(413);
    expect(await errorBody(response)).toMatchObject({ error: { code: "PAYLOAD_TOO_LARGE" } });
    expect(testRuntime.proxyHistory).not.toHaveBeenCalled();
  });

  it.each([
    ["disabled", 403, "HISTORY_DISABLED"],
    ["invalid_request", 400, "INVALID_REQUEST"],
    ["payload_too_large", 413, "PAYLOAD_TOO_LARGE"],
    ["auth_failed", 503, "ORIGIN_AUTH_FAILED"],
    ["unavailable", 503, "MAC_UNAVAILABLE"],
  ])("maps the %s origin failure", async (reason, expectedStatus, expectedCode) => {
    const testRuntime = runtime({
      proxyHistory: vi.fn(async () => ({ ok: false, reason, revision: null }) as HistoryProxyResult),
    });
    const response = await handleRequest(historyRequest("/v1/history/manifest"), testRuntime.value);

    expect(response.status).toBe(expectedStatus);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    const body = await errorBody(response);
    expect(body).toMatchObject({ error: { code: expectedCode } });
    expect(body.revision).toBeUndefined();
  });

  it("includes the current revision when the Mac history changed", async () => {
    const testRuntime = runtime({
      proxyHistory: vi.fn(async () => ({ ok: false, reason: "changed", revision: 57 }) as const),
    });
    const response = await handleRequest(
      historyRequest("/v1/history?revision=42"),
      testRuntime.value,
    );

    expect(response.status).toBe(409);
    expect(await errorBody(response)).toMatchObject({
      error: { code: "HISTORY_CHANGED" },
      request_id: REQUEST_ID,
      revision: 57,
    });
  });

  it("omits the revision when the Mac did not report one", async () => {
    const testRuntime = runtime({
      proxyHistory: vi.fn(async () => ({ ok: false, reason: "changed", revision: null }) as const),
    });
    const response = await handleRequest(
      historyRequest("/v1/history?revision=42"),
      testRuntime.value,
    );

    expect(response.status).toBe(409);
    const body = await errorBody(response);
    expect(body).toMatchObject({ error: { code: "HISTORY_CHANGED" } });
    expect("revision" in body).toBe(false);
  });

  it("never invokes Workers AI or the asset store on history paths", async () => {
    const testRuntime = runtime();
    for (const path of ["/v1/history/manifest", "/v1/history?revision=1"]) {
      await handleRequest(historyRequest(path), testRuntime.value);
    }
    await handleRequest(
      operationsRequest({ operations: [{ op_id: "o", type: "pin", entry_id: "e" }] }),
      testRuntime.value,
    );

    expect(testRuntime.transcribeInCloud).not.toHaveBeenCalled();
    expect(testRuntime.transcribeOnMac).not.toHaveBeenCalled();
    expect(testRuntime.fetchAsset).not.toHaveBeenCalled();
    expect(testRuntime.proxyHistory).toHaveBeenCalledTimes(3);
  });

  it("never logs history bodies or cursors and correlates only by opaque request id", async () => {
    const secret = "private dictation entry text";
    const testRuntime = runtime();
    await handleRequest(
      operationsRequest({
        operations: [{ op_id: "op-1", type: "edit", entry_id: "entry-1", text: secret }],
      }),
      testRuntime.value,
    );
    await handleRequest(
      historyRequest("/v1/history?revision=42&cursor=secretcursor"),
      testRuntime.value,
    );

    const serialized = JSON.stringify(testRuntime.logs);
    expect(serialized).not.toContain(secret);
    expect(serialized).not.toContain("secretcursor");
    expect(serialized).toContain(REQUEST_ID);
    expectPrivacySafeLogs(testRuntime.logs, [secret, "secretcursor"]);
  });
});

describe("origin response deadlines", () => {
  function stalledResponse(status = 200) {
    const cancel = vi.fn();
    const response = new Response(new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new TextEncoder().encode('{"pending":')); },
      cancel,
    }), { status });
    return { response, cancel };
  }

  it("times out and cancels a health body after its headers arrive without sending audio", async () => {
    const stalled = stalledResponse();
    const fetcher: RequestFetcher = vi.fn(async () => stalled.response);
    const transcribe = createMacTranscriber({ ...MAC_ORIGIN, healthTimeoutMs: 5 }, fetcher);
    await expect(transcribe(audioInput())).resolves.toEqual({ ok: false, reason: "health_timeout" });
    expect(fetcher).toHaveBeenCalledOnce();
    expect(stalled.cancel).toHaveBeenCalledOnce();
  });

  it.each([200, 503])("times out and cancels a stalled transcription body with status %s", async (status) => {
    const stalled = stalledResponse(status);
    const fetcher: RequestFetcher = vi.fn(async (request) =>
      new URL(request.url).pathname === "/healthz"
        ? Response.json({ ready: true, busy: false })
        : stalled.response);
    const transcribe = createMacTranscriber({ ...MAC_ORIGIN, transcribeTimeoutMs: 5 }, fetcher);
    await expect(transcribe(audioInput())).resolves.toEqual({ ok: false, reason: "origin_timeout" });
    expect(stalled.cancel).toHaveBeenCalledOnce();
  });

  it.each([200, 403])("bounds history body consumption with status %s", async (status) => {
    const stalled = stalledResponse(status);
    const proxy = createHistoryProxy(
      { ...MAC_ORIGIN, historyReadTimeoutMs: 5 },
      async () => stalled.response,
    );
    await expect(proxy({ kind: "manifest", client: "pwa", requestId: REQUEST_ID, search: "", body: null }))
      .resolves.toEqual({ ok: false, reason: "unavailable", revision: null });
    expect(stalled.cancel).toHaveBeenCalledOnce();
  });

  it("bounds a fetcher which ignores abort and cancels its late response", async () => {
    let completeFetch: ((response: Response) => void) | undefined;
    const fetcher: RequestFetcher = () => new Promise((resolve) => { completeFetch = resolve; });
    const transcribe = createMacTranscriber({ ...MAC_ORIGIN, healthTimeoutMs: 5 }, fetcher);
    await expect(transcribe(audioInput())).resolves.toEqual({ ok: false, reason: "health_timeout" });
    const stalled = stalledResponse();
    completeFetch?.(stalled.response);
    await vi.waitFor(() => expect(stalled.cancel).toHaveBeenCalledOnce());
  });
});

describe("history origin proxy", () => {
  function proxyInput(overrides: Partial<HistoryProxyRequest> = {}): HistoryProxyRequest {
    return {
      kind: "manifest",
      client: "pwa",
      requestId: REQUEST_ID,
      search: "",
      body: null,
      ...overrides,
    };
  }

  it("forwards access credentials, the request id, and the client to the Mac", async () => {
    const requests: Request[] = [];
    const fetcher: RequestFetcher = vi.fn(async (request) => {
      requests.push(request);
      return Response.json({ revision: 42, entries: [] });
    });
    const proxy = createHistoryProxy(MAC_ORIGIN, fetcher);

    const result = await proxy(proxyInput({ kind: "page", search: "?revision=42&limit=25" }));

    expect(result).toMatchObject({ ok: true, status: 200 });
    const forwarded = requests[0];
    expect(forwarded?.method).toBe("GET");
    expect(new URL(forwarded?.url ?? "https://x.invalid").pathname).toBe("/v1/history");
    expect(new URL(forwarded?.url ?? "https://x.invalid").search).toBe("?revision=42&limit=25");
    expect(forwarded?.headers.get("CF-Access-Client-Id")).toBe("client-id");
    expect(forwarded?.headers.get("CF-Access-Client-Secret")).toBe("client-secret");
    expect(forwarded?.headers.get("X-Request-ID")).toBe(REQUEST_ID);
    expect(forwarded?.headers.get("X-Dictation-Client")).toBe("pwa");
  });

  it("posts the operations body to the operations path", async () => {
    const requests: Request[] = [];
    const fetcher: RequestFetcher = vi.fn(async (request) => {
      requests.push(request.clone());
      return Response.json({ revision: 43, results: [] });
    });
    const proxy = createHistoryProxy(MAC_ORIGIN, fetcher);
    const body = new TextEncoder().encode('{"operations":[]}').buffer as ArrayBuffer;

    await proxy(proxyInput({ kind: "operations", body }));

    const forwarded = requests[0];
    expect(forwarded?.method).toBe("POST");
    expect(new URL(forwarded?.url ?? "https://x.invalid").pathname).toBe("/v1/history/operations");
    await expect(forwarded?.text()).resolves.toBe('{"operations":[]}');
  });

  it("classifies an origin timeout as unavailable", async () => {
    const fetcher: RequestFetcher = vi.fn(
      (request) =>
        new Promise<Response>((resolve, reject) => {
          const signal = request.signal as AbortSignal | null;
          if (signal?.aborted === true) {
            reject(new DOMException("aborted", "AbortError"));
            return;
          }
          signal?.addEventListener("abort", () => {
            reject(new DOMException("aborted", "AbortError"));
          });
          setTimeout(() => resolve(Response.json({ revision: 1 })), 2_000);
        }),
    );
    const proxy = createHistoryProxy({ ...MAC_ORIGIN, historyReadTimeoutMs: 5 }, fetcher);

    await expect(proxy(proxyInput())).resolves.toEqual({
      ok: false,
      reason: "unavailable",
      revision: null,
    });
  });

  it("classifies an unreachable origin as unavailable", async () => {
    const fetcher: RequestFetcher = vi.fn(async () => {
      throw new TypeError("connection refused to 10.0.0.1");
    });
    const proxy = createHistoryProxy(MAC_ORIGIN, fetcher);

    await expect(proxy(proxyInput())).resolves.toEqual({
      ok: false,
      reason: "unavailable",
      revision: null,
    });
  });

  it("reports an unconfigured origin as unavailable without a request", async () => {
    const fetcher: RequestFetcher = vi.fn();
    const proxy = createHistoryProxy({ ...MAC_ORIGIN, originUrl: "http://mac.example.com/x" }, fetcher);

    await expect(proxy(proxyInput())).resolves.toEqual({
      ok: false,
      reason: "unavailable",
      revision: null,
    });
    expect(fetcher).not.toHaveBeenCalled();
  });

  it.each([
    [403, { error: "history_disabled" }, { ok: false, reason: "disabled", revision: null }],
    [409, { error: "history_changed", revision: 57 }, { ok: false, reason: "changed", revision: 57 }],
    [409, { error: "history_changed" }, { ok: false, reason: "changed", revision: null }],
    [400, { error: "invalid_request" }, { ok: false, reason: "invalid_request", revision: null }],
    [413, { error: "payload_too_large" }, { ok: false, reason: "payload_too_large", revision: null }],
    [401, {}, { ok: false, reason: "auth_failed", revision: null }],
    [403, { error: "forbidden" }, { ok: false, reason: "auth_failed", revision: null }],
    [500, {}, { ok: false, reason: "unavailable", revision: null }],
  ])("maps origin status %s to a gateway failure", async (status, body, expected) => {
    const fetcher: RequestFetcher = vi.fn(async () => Response.json(body, { status }));
    const proxy = createHistoryProxy(MAC_ORIGIN, fetcher);

    await expect(proxy(proxyInput())).resolves.toEqual(expected);
  });

  it("rejects a successful body that is not a JSON object", async () => {
    const fetcher: RequestFetcher = vi.fn(async () => new Response("[1,2,3]", { status: 200 }));
    const proxy = createHistoryProxy(MAC_ORIGIN, fetcher);

    await expect(proxy(proxyInput())).resolves.toEqual({
      ok: false,
      reason: "unavailable",
      revision: null,
    });
  });

  it("rejects a successful body that declares more than four mebibytes", async () => {
    const fetcher: RequestFetcher = vi.fn(
      async () =>
        new Response("{}", {
          status: 200,
          headers: { "Content-Length": String(5 * 1024 * 1024) },
        }),
    );
    const proxy = createHistoryProxy(MAC_ORIGIN, fetcher);

    await expect(proxy(proxyInput())).resolves.toEqual({
      ok: false,
      reason: "unavailable",
      revision: null,
    });
  });
});

describe("PWA static assets", () => {
  const CSP =
    "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' wss://dictation.example.com/stream; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

  it.each(["/app", "/app/", "/app/import"])("serves the shell for %s", async (path) => {
    const testRuntime = runtime();
    const response = await handleRequest(
      new Request(`https://dictation.example.com${path}`),
      testRuntime.value,
    );

    expect(response.status).toBe(200);
    expect(new URL(testRuntime.assetRequests[0]?.url ?? "https://x.invalid").pathname).toBe(
      "/app/index.html",
    );
    expect(response.headers.get("Content-Security-Policy")).toBe(CSP);
    expect(response.headers.get("Referrer-Policy")).toBe("no-referrer");
    expect(response.headers.get("X-Frame-Options")).toBe("DENY");
    expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(response.headers.get("Permissions-Policy")).toBe("microphone=(self)");
    expect(response.headers.get("Cache-Control")).toBe("no-cache");
    await expect(response.text()).resolves.toContain("shell");
  });

  it("caches content-hashed assets immutably and everything else revalidated", async () => {
    const testRuntime = runtime();
    const hashed = await handleRequest(
      new Request("https://dictation.example.com/app/app.0a1b2c3d.js"),
      testRuntime.value,
    );
    const unhashed = await handleRequest(
      new Request("https://dictation.example.com/app/sw.js"),
      testRuntime.value,
    );

    expect(hashed.headers.get("Cache-Control")).toBe("public, max-age=31536000, immutable");
    expect(hashed.headers.get("Content-Security-Policy")).toBe(CSP);
    expect(unhashed.headers.get("Cache-Control")).toBe("no-cache");
  });

  it("forwards the asset store 404 for an unknown app file", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      new Request("https://dictation.example.com/app/missing.js"),
      testRuntime.value,
    );

    expect(response.status).toBe(404);
    expect(response.headers.get("Referrer-Policy")).toBe("no-referrer");
  });

  it("redirects the site root to the app", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      new Request("https://dictation.example.com/"),
      testRuntime.value,
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toBe("/app/");
    expect(testRuntime.fetchAsset).not.toHaveBeenCalled();
  });

  it("rejects a non-GET request to the app", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      new Request("https://dictation.example.com/app/", { method: "POST", body: "x" }),
      testRuntime.value,
    );

    expect(response.status).toBe(405);
    expect(await errorBody(response)).toMatchObject({ error: { code: "METHOD_NOT_ALLOWED" } });
    expect(testRuntime.fetchAsset).not.toHaveBeenCalled();
  });

  it.each([
    "/v1/transcriptions",
    "/v1/healthz",
    "/v1/history",
    "/v1/history/manifest",
    "/v1/history/operations",
    "/v1/anything-else",
    "/v1",
  ])("never serves assets for %s", async (path) => {
    const testRuntime = runtime();
    await handleRequest(new Request(`https://dictation.example.com${path}`), testRuntime.value);

    expect(testRuntime.fetchAsset).not.toHaveBeenCalled();
  });

  it("returns the JSON envelope for unknown non-app paths", async () => {
    const testRuntime = runtime();
    const response = await handleRequest(
      new Request("https://dictation.example.com/robots.txt"),
      testRuntime.value,
    );

    expect(response.status).toBe(404);
    expect(await errorBody(response)).toMatchObject({ error: { code: "NOT_FOUND" } });
    expect(testRuntime.fetchAsset).not.toHaveBeenCalled();
  });
});

describe("Workers AI transcription", () => {
  it("uses whisper-large-v3-turbo with base64 audio and privacy-safe options", async () => {
    const run = vi.fn(async () => ({ text: "cloud transcript", word_count: 2 }));
    const transcribe = createWorkersAiTranscriber(run);

    await expect(transcribe(audioInput())).resolves.toEqual({
      text: "cloud transcript",
      route: "cloud_fallback",
      cleanup: "none",
      latencyMs: 0,
      fallbackReason: null,
      historyState: "pending_device_sync",
    });
    expect(run).toHaveBeenCalledWith(CLOUD_MODEL, {
      audio: "AAECAw==",
      task: "transcribe",
      language: "en",
      vad_filter: true,
      condition_on_previous_text: true,
    });
  });
});

describe("Mac origin routing", () => {
  it("checks readiness before forwarding exact audio and access credentials", async () => {
    const requests: Request[] = [];
    const fetcher: RequestFetcher = vi.fn(async (request) => {
      requests.push(request.clone());
      if (new URL(request.url).pathname === "/healthz") {
        return Response.json({ ready: true, busy: false });
      }
      return Response.json({
        request_id: "request-abc",
        text: "from Mac",
        route: "mac_local",
        cleanup: "apple_foundation",
        latency_ms: 123,
        fallback_reason: null,
        history_state: "saved_on_mac",
      });
    });
    const transcribe = createMacTranscriber(
      {
        ...MAC_ORIGIN,
        healthTimeoutMs: 1_000,
        transcribeTimeoutMs: 1_000,
      },
      fetcher,
    );

    const result = await transcribe(audioInput({ durationSeconds: 0.9, client: "pwa" }));

    expect(result).toEqual({
      ok: true,
      transcript: {
        text: "from Mac",
        route: "mac_local",
        cleanup: "apple_foundation",
        latencyMs: 123,
        fallbackReason: null,
        historyState: "saved_on_mac",
      },
    });
    expect(requests.map((request) => `${request.method} ${new URL(request.url).pathname}`)).toEqual([
      "GET /healthz",
      "POST /v1/transcriptions",
    ]);
    const forwarded = requests[1];
    expect(forwarded?.headers.get("CF-Access-Client-Id")).toBe("client-id");
    expect(forwarded?.headers.get("CF-Access-Client-Secret")).toBe("client-secret");
    expect(forwarded?.headers.get("X-Request-ID")).toBe("request-abc");
    expect(forwarded?.headers.get("X-Audio-Duration-Seconds")).toBe("0.9");
    expect(forwarded?.headers.get("X-Dictation-Mode")).toBe("clean");
    expect(forwarded?.headers.get("X-Dictation-Client")).toBe("pwa");
    expect(forwarded?.headers.get("X-Allow-Cloud-Fallback")).toBe("true");
    expect(forwarded).toBeDefined();
    if (forwarded === undefined) throw new Error("missing forwarded request");
    expect(new Uint8Array(await forwarded.arrayBuffer())).toEqual(new Uint8Array(AUDIO));
  });

  it("accepts Swift's uppercase UUID response for a lowercase PWA request ID", async () => {
    const requestId = "abcdef12-3456-4abc-8def-1234567890ab";
    const fetcher: RequestFetcher = vi.fn(async (request) => {
      if (new URL(request.url).pathname === "/healthz") {
        return Response.json({ ready: true, busy: false });
      }
      return Response.json({
        request_id: requestId.toUpperCase(),
        text: "from Mac",
        route: "mac_local",
        cleanup: "deterministic",
        latency_ms: 123,
        fallback_reason: null,
        history_state: "saved_on_mac",
      });
    });
    const transcribe = createMacTranscriber(MAC_ORIGIN, fetcher);

    await expect(transcribe(audioInput({ requestId }))).resolves.toMatchObject({
      ok: true,
      transcript: {
        text: "from Mac",
        route: "mac_local",
        historyState: "saved_on_mac",
      },
    });
  });

  it("rejects a different origin UUID", async () => {
    const requestId = "abcdef12-3456-4abc-8def-1234567890ab";
    const fetcher: RequestFetcher = vi.fn(async (request) => {
      if (new URL(request.url).pathname === "/healthz") {
        return Response.json({ ready: true, busy: false });
      }
      return Response.json({
        request_id: "abcdef12-3456-4abc-8def-1234567890ac",
        text: "from Mac",
        route: "mac_local",
        cleanup: "deterministic",
        latency_ms: 123,
        fallback_reason: null,
        history_state: "saved_on_mac",
      });
    });
    const transcribe = createMacTranscriber(MAC_ORIGIN, fetcher);

    await expect(transcribe(audioInput({ requestId }))).resolves.toEqual({
      ok: false,
      reason: "origin_invalid_response",
    });
  });

  it("treats a missing history_state as disabled", async () => {
    const fetcher: RequestFetcher = vi.fn(async (request) => {
      if (new URL(request.url).pathname === "/healthz") {
        return Response.json({ ready: true, busy: false });
      }
      return Response.json({
        request_id: "request-abc",
        text: "from Mac",
        route: "mac_local",
        cleanup: "none",
        latency_ms: 12,
        fallback_reason: null,
      });
    });
    const transcribe = createMacTranscriber(MAC_ORIGIN, fetcher);

    await expect(transcribe(audioInput())).resolves.toMatchObject({
      ok: true,
      transcript: { historyState: "disabled" },
    });
  });

  it("treats an unknown history_state as an invalid origin response", async () => {
    const fetcher: RequestFetcher = vi.fn(async (request) => {
      if (new URL(request.url).pathname === "/healthz") {
        return Response.json({ ready: true, busy: false });
      }
      return Response.json({
        request_id: "request-abc",
        text: "from Mac",
        route: "mac_local",
        cleanup: "none",
        latency_ms: 12,
        fallback_reason: null,
        history_state: "queued_somewhere",
      });
    });
    const transcribe = createMacTranscriber(MAC_ORIGIN, fetcher);

    await expect(transcribe(audioInput())).resolves.toEqual({
      ok: false,
      reason: "origin_invalid_response",
    });
  });

  it("does not send audio when the Mac reports it is busy", async () => {
    const fetcher: RequestFetcher = vi.fn(async () => Response.json({ ready: true, busy: true }));
    const transcribe = createMacTranscriber(MAC_ORIGIN, fetcher);

    await expect(transcribe(audioInput())).resolves.toEqual({ ok: false, reason: "health_busy" });
    expect(fetcher).toHaveBeenCalledOnce();
  });

  it("classifies a rejected health credential without sending audio", async () => {
    const fetcher: RequestFetcher = vi.fn(async () => new Response(null, { status: 403 }));
    const transcribe = createMacTranscriber(
      { ...MAC_ORIGIN, accessClientId: "expired-client-id" },
      fetcher,
    );

    await expect(transcribe(audioInput())).resolves.toEqual({
      ok: false,
      reason: "health_authentication_failed",
    });
    expect(fetcher).toHaveBeenCalledOnce();
  });

  it("classifies malformed origin audio as ineligible for cloud fallback", async () => {
    const fetcher: RequestFetcher = vi.fn(async (request) => {
      if (new URL(request.url).pathname === "/healthz") {
        return Response.json({ ready: true, busy: false });
      }
      return Response.json({ error: "unsupported_media" }, { status: 415 });
    });
    const transcribe = createMacTranscriber(MAC_ORIGIN, fetcher);

    await expect(transcribe(audioInput())).resolves.toEqual({
      ok: false,
      reason: "origin_invalid_request",
    });
  });

  it("refuses an insecure or path-bearing origin configuration", async () => {
    const fetcher: RequestFetcher = vi.fn();
    const transcribe = createMacTranscriber(
      { ...MAC_ORIGIN, originUrl: "http://mac.example.com/internal" },
      fetcher,
    );

    await expect(transcribe(audioInput())).resolves.toEqual({ ok: false, reason: "not_configured" });
    expect(fetcher).not.toHaveBeenCalled();
  });
});

describe("default runtime", () => {
  it("degrades to not-configured when origin secrets are missing instead of throwing", async () => {
    const env = {
      MAC_ORIGIN_URL: "https://dictate-origin.example.com",
      AI: { run: async () => ({ text: "unused" }) },
      ASSETS: { fetch: async () => new Response("asset") },
    } as unknown as Env;
    const runtime = defaultRuntime(env);
    const attempt = await runtime.transcribeOnMac({
      bytes: new Uint8Array([1]).buffer,
      allowsCloudFallback: true,
      contentType: "audio/mp4",
      durationSeconds: 1,
      language: "en",
      mode: "clean",
      requestId: REQUEST_ID,
      client: "shortcut",
    });
    expect(attempt).toEqual({ ok: false, reason: "not_configured" });
    const history = await runtime.proxyHistory({
      kind: "manifest",
      client: "pwa",
      requestId: REQUEST_ID,
      search: "",
      body: null,
    });
    expect(history).toEqual({ ok: false, reason: "unavailable", revision: null });
  });
});
