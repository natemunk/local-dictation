import { describe, expect, it } from "vitest";
import { createRecordingRecovery, canApplyUpdate } from "../../public/app/lib/recording-recovery.js";

describe("memory-only recording recovery", () => {
  it("keeps cancellation recoverable and refuses accidental replacement", async () => {
    const recovery = createRecordingRecovery(); const original = { requestId: "synthetic" };
    recovery.retain(original);
    const sending = recovery.submit((_recording: any, signal: AbortSignal) => new Promise((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(new DOMException("Cancelled", "AbortError")));
    }));
    expect(() => recovery.retain({ requestId: "replacement" })).toThrow();
    expect(recovery.discard()).toBe(false);
    recovery.cancel(); await expect(sending).rejects.toThrow("Cancelled");
    expect(recovery.pending).toBe(original); expect(recovery.busy).toBe(false);
    expect(recovery.discard()).toBe(true); expect(recovery.pending).toBeNull();
  });
  it("only offers updates when recording and drafts are safe", () => {
    const idle = { recording: false, recordingStarting: false, transcribing: false, hasRecording: false, editing: false, settingsOpen: false };
    expect(canApplyUpdate(idle)).toBe(true);
    for (const key of Object.keys(idle)) expect(canApplyUpdate({ ...idle, [key]: true })).toBe(false);
  });
});
