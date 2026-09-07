import { describe, expect, it, vi } from "vitest";
import { createLiveStream } from "../../public/app/lib/live-stream.js";

const REQUEST_ID = "00000000-0000-4000-8000-000000000123";

class FakeWebSocket {
  static instances: FakeWebSocket[] = [];
  binaryType = "";
  protocol = "local-dictation.v1";
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  sent: unknown[] = [];

  constructor(readonly url: string, readonly protocols: string[]) {
    FakeWebSocket.instances.push(this);
  }

  send(value: unknown) {
    this.sent.push(value);
  }

  close() {}

  open() { this.onopen?.(); }
  message(value: unknown) { this.onmessage?.({ data: JSON.stringify(value) }); }
  fail() { this.onerror?.(); }
}

function fixture(overrides: Record<string, unknown> = {}) {
  FakeWebSocket.instances = [];
  const diagnostics: Array<Record<string, unknown>> = [];
  const partials: string[] = [];
  const api = {
    createStreamTicket: vi.fn(async () => ({
      request_id: REQUEST_ID,
      protocol: "local-dictation.v1",
      ticket: "ld-ticket.payload.signature",
      stream_path: "/stream",
      expires_at: Date.now() + 30_000,
    })),
  };
  const stream = createLiveStream({
    api,
    requestId: REQUEST_ID,
    mode: "clean",
    allowCloudFallback: true,
    WebSocketImpl: FakeWebSocket,
    scope: {
      WebSocket: FakeWebSocket,
      location: { href: "https://dictation.example.com/app/" },
      setTimeout,
    },
    onPartial: (text: string) => partials.push(text),
    recordDiagnostic: (event: Record<string, unknown>) => diagnostics.push(event),
    ...overrides,
  });
  return { stream, api, diagnostics, partials };
}

describe("live transcription transport", () => {
  it("buffers PCM until ready and returns the authoritative final response", async () => {
    const { stream, diagnostics, partials } = fixture();
    const started = stream.start();
    await Promise.resolve();
    await Promise.resolve();
    const socket = FakeWebSocket.instances[0]!;
    expect(socket.url).toBe("wss://dictation.example.com/stream");
    expect(socket.protocols).toEqual([
      "local-dictation.v1",
      "ld-ticket.payload.signature",
    ]);

    const pcm = new Uint8Array([1, 2, 3, 4]).buffer;
    expect(stream.push(pcm)).toBe(true);
    socket.open();
    socket.message({ type: "ready", request_id: REQUEST_ID });
    await expect(started).resolves.toBe(true);
    expect(socket.sent[0]).toBe(pcm);

    socket.message({ type: "partial", request_id: REQUEST_ID, text: "live private words" });
    expect(partials).toEqual(["live private words"]);

    const final = stream.finish(2);
    expect(JSON.parse(socket.sent.at(-1) as string)).toEqual({
      type: "finish",
      duration_seconds: 2,
    });
    socket.message({
      type: "final",
      request_id: REQUEST_ID,
      text: "Finished words.",
      route: "mac_local",
      cleanup: "deterministic",
      latency_ms: 100,
      fallback_reason: null,
      history_state: "saved_on_mac",
    });
    await expect(final).resolves.toMatchObject({
      request_id: REQUEST_ID,
      text: "Finished words.",
      route: "mac_local",
    });
    expect(JSON.stringify(diagnostics)).not.toContain("live private words");
    expect(JSON.stringify(diagnostics)).not.toContain("Finished words");
    expect(JSON.stringify(diagnostics)).not.toContain("ld-ticket");
  });

  it("resolves to file fallback when ticket creation or the socket fails", async () => {
    const ticketFailure = fixture({
      api: { createStreamTicket: vi.fn(async () => { throw new Error("offline"); }) },
    });
    await expect(ticketFailure.stream.start()).resolves.toBe(false);
    await expect(ticketFailure.stream.finish(1)).resolves.toBeNull();

    const socketFailure = fixture();
    await socketFailure.stream.start();
    const socket = FakeWebSocket.instances[0]!;
    socket.fail();
    await expect(socketFailure.stream.finish(1)).resolves.toBeNull();
  });
});
