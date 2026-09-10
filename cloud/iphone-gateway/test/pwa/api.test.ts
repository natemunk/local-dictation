import { afterEach, describe, expect, it, vi } from "vitest";

import {
  ApiError,
  createApiClient,
} from "../../public/app/lib/api.js";

const REQUEST_ID = "00000000-0000-4000-8000-000000000123";
afterEach(() => vi.useRealTimers());

function client(fetchImpl: typeof fetch, diagnostics: Array<Record<string, unknown>>) {
  return createApiClient({
    fetchImpl,
    getCredentials: () => ({ clientId: "client-id", clientSecret: "client-secret" }),
    newRequestId: () => REQUEST_ID,
    recordDiagnostic: (event: Record<string, unknown>) => diagnostics.push(event),
  });
}

describe("PWA gateway diagnostics", () => {
  it.each(["headers", "body"])("bounds a stalled %s even if fetch ignores abort", async phase => {
    vi.useFakeTimers();
    const fetchImpl = vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) => {
      if (phase === "headers") return await new Promise<Response>(() => {});
      return { ok: true, status: 200, json: () => new Promise(() => {}) } as Response;
    });
    const api = createApiClient({ fetchImpl, requestTimeoutMs: 100,
      getCredentials: () => ({ clientId: "synthetic-id", clientSecret: "synthetic-key" }),
      recordDiagnostic: () => {},
    });
    const result = expect(api.healthz()).rejects.toMatchObject({ code: "REQUEST_TIMEOUT" });
    await vi.advanceTimersByTimeAsync(100);
    await result;
    expect(fetchImpl.mock.calls[0]?.[1]?.signal?.aborted).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("cancels an upload promptly without accepting its late result", async () => {
    const controller = new AbortController();
    let complete!: (value: Response) => void;
    const diagnostics: Array<Record<string, unknown>> = [];
    const api = client(vi.fn(() => new Promise<Response>(resolve => { complete = resolve; })), diagnostics);
    const result = expect(api.transcribe({ blob: new Blob(["synthetic"]), mimeType: "audio/mp4",
      durationSeconds: 1, mode: "literal", allowCloudFallback: false, requestId: REQUEST_ID,
      signal: controller.signal })).rejects.toMatchObject({ code: "REQUEST_CANCELLED" });
    controller.abort();
    await result;
    complete(Response.json({ request_id: REQUEST_ID, text: "synthetic result", route: "mac_local" }));
    await Promise.resolve();
    expect(diagnostics.at(-1)?.code).toBe("REQUEST_CANCELLED");
    expect(diagnostics.some(event => event.outcome === "succeeded")).toBe(false);
  });
  it("mints a stream ticket with the same protected PWA credentials", async () => {
    const diagnostics: Array<Record<string, unknown>> = [];
    const fetchImpl = vi.fn(async (_request: RequestInfo | URL, init?: RequestInit) => {
      const headers = init?.headers as Headers;
      expect(headers.get("CF-Access-Client-Id")).toBe("client-id");
      expect(headers.get("CF-Access-Client-Secret")).toBe("client-secret");
      expect(headers.get("X-Dictation-Client")).toBe("pwa");
      expect(headers.get("X-Dictation-Mode")).toBe("clean");
      return Response.json({
        request_id: REQUEST_ID,
        protocol: "local-dictation.v1",
        ticket: "short-lived-ticket",
        stream_path: "/stream",
        expires_at: 30_000,
      }, { status: 200, headers: { "X-Request-ID": REQUEST_ID } });
    });

    await client(fetchImpl as typeof fetch, diagnostics).createStreamTicket({
      requestId: REQUEST_ID,
      mode: "clean",
      allowCloudFallback: true,
    });

    expect(fetchImpl).toHaveBeenCalledWith("/v1/stream-tickets", expect.objectContaining({
      method: "POST",
      credentials: "omit",
      cache: "no-store",
    }));
    expect(JSON.stringify(diagnostics)).not.toContain("short-lived-ticket");
    expect(JSON.stringify(diagnostics)).not.toContain("client-secret");
  });

  it("records a request correlation lifecycle without body, transcript, or credentials", async () => {
    const diagnostics: Array<Record<string, unknown>> = [];
    const secretTranscript = "words that must not be logged";
    const fetchImpl = vi.fn(async (request: RequestInfo | URL, init?: RequestInit) => {
      expect(init?.headers).toBeInstanceOf(Headers);
      return Response.json({
        request_id: REQUEST_ID,
        text: secretTranscript,
        route: "mac_local",
      }, { status: 200, headers: { "X-Request-ID": REQUEST_ID } });
    });

    await client(fetchImpl as typeof fetch, diagnostics).transcribe({
      blob: new Blob(["audio bytes"], { type: "audio/mp4" }),
      mimeType: "audio/mp4",
      durationSeconds: 2,
      mode: "clean",
      allowCloudFallback: true,
      requestId: REQUEST_ID,
    });

    expect(diagnostics).toHaveLength(2);
    expect(diagnostics[0]).toMatchObject({
      operation: "transcription",
      phase: "gateway",
      outcome: "started",
      requestId: REQUEST_ID,
      code: "REQUEST_STARTED",
    });
    expect(diagnostics[1]).toMatchObject({
      operation: "transcription",
      phase: "response",
      outcome: "succeeded",
      requestId: REQUEST_ID,
      status: 200,
      code: "OK",
      route: "mac_local",
    });
    const serialized = JSON.stringify(diagnostics);
    expect(serialized).not.toContain(secretTranscript);
    expect(serialized).not.toContain("client-secret");
    expect(serialized).not.toContain("audio bytes");
  });

  it("records the stable gateway failure code and request id", async () => {
    const diagnostics: Array<Record<string, unknown>> = [];
    const fetchImpl = vi.fn(async () => Response.json({
      error: { code: "CLOUD_FALLBACK_FAILED", message: "Cloud fallback failed." },
      request_id: REQUEST_ID,
    }, { status: 503, headers: { "X-Request-ID": REQUEST_ID } }));

    const request = client(fetchImpl as typeof fetch, diagnostics).healthz();
    await expect(request).rejects.toMatchObject({
      code: "CLOUD_FALLBACK_FAILED",
      status: 503,
      requestId: REQUEST_ID,
    } satisfies Partial<ApiError>);
    expect(diagnostics.at(-1)).toMatchObject({
      operation: "health",
      phase: "gateway",
      outcome: "failed",
      requestId: REQUEST_ID,
      status: 503,
      code: "CLOUD_FALLBACK_FAILED",
    });
  });
});
