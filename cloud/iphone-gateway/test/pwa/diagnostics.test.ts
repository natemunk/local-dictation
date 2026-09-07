import { beforeEach, describe, expect, it } from "vitest";

import {
  clearDiagnostics,
  formatDiagnostics,
  listDiagnostics,
  recordDiagnostic,
} from "../../public/app/lib/diagnostics.js";

const REQUEST_ID = "00000000-0000-4000-8000-000000000123";

describe("PWA privacy-safe diagnostics", () => {
  beforeEach(async () => {
    await clearDiagnostics();
  });

  it("persists only the closed allowlist and rejects content-bearing fields", async () => {
    const secretTranscript = "private words must never be stored";
    const secretToken = "service-token-secret";

    await recordDiagnostic({
      operation: "transcription",
      phase: "gateway",
      outcome: "failed",
      requestId: REQUEST_ID,
      status: 503,
      code: "MAC_UNAVAILABLE",
      route: "mac_local",
      latencyMs: 842,
      transcript: secretTranscript,
      message: secretTranscript,
      credential: secretToken,
      url: "https://private.example/path",
    }, () => new Date("2026-09-07T01:02:03.000Z"));

    const events = await listDiagnostics();
    expect(events).toEqual([{
      at: "2026-09-07T01:02:03.000Z",
      operation: "transcription",
      phase: "gateway",
      outcome: "failed",
      request_id: REQUEST_ID,
      status: 503,
      code: "MAC_UNAVAILABLE",
      route: "mac_local",
      latency_ms: 842,
    }]);
    const serialized = JSON.stringify(events);
    expect(serialized).not.toContain(secretTranscript);
    expect(serialized).not.toContain(secretToken);
    expect(serialized).not.toContain("private.example");
  });

  it("bounds retained diagnostics to the newest 100 events", async () => {
    for (let index = 0; index < 103; index += 1) {
      await recordDiagnostic({
        operation: "health",
        phase: "response",
        outcome: "succeeded",
        requestId: REQUEST_ID,
        status: 200,
        code: "OK",
        route: "none",
        latencyMs: index,
      });
    }

    const events = await listDiagnostics();
    expect(events).toHaveLength(100);
    expect(events[0]?.latency_ms).toBe(3);
    expect(events.at(-1)?.latency_ms).toBe(102);
  });

  it("exports an explicit privacy header plus JSON-lines events", async () => {
    await recordDiagnostic({
      operation: "health",
      phase: "response",
      outcome: "succeeded",
      requestId: REQUEST_ID,
      status: 200,
      code: "OK",
      route: "none",
      latencyMs: 25,
    });

    const report = await formatDiagnostics();
    expect(report).toContain("Local Dictation PWA diagnostics v1");
    expect(report).toContain(REQUEST_ID);
    expect(report).toContain("No audio, transcripts, credentials, headers, URLs, or raw errors");
  });
});
