import { afterEach, describe, expect, it, vi } from "vitest";
import { createPCMCapture } from "../../public/app/lib/pcm-capture.js";

afterEach(() => vi.useRealTimers());

function fixture(options: { hangingModule?: boolean; hangingResume?: boolean; hangingClose?: boolean } = {}) {
  const events: string[] = [];
  const disconnect = vi.fn();
  const graph = { connect: vi.fn(), disconnect };
  const close = vi.fn(() => options.hangingClose ? new Promise(() => {}) : Promise.resolve());
  const source = vi.fn(() => graph);
  let resolveModule!: () => void;
  class Context {
    destination = {};
    audioWorklet = { addModule: vi.fn(() => options.hangingModule
      ? new Promise<void>(resolve => { resolveModule = resolve; }) : Promise.resolve()) };
    resume() { events.push("resume"); return options.hangingResume ? new Promise(() => {}) : Promise.resolve(); }
    close = close;
    createMediaStreamSource = source;
    createGain() { return { ...graph, gain: { value: 1 } }; }
  }
  class Node {
    connect = graph.connect;
    disconnect = graph.disconnect;
    port = { onmessage: null as ((event: unknown) => void) | null, postMessage: vi.fn(() => {}) };
  }
  const capture = createPCMCapture({ scope: { AudioContext: Context, AudioWorkletNode: Node,
    setTimeout, clearTimeout } as any });
  return { capture, events, close, source, disconnect, resolveModule: () => resolveModule() };
}

describe("optional PCM capture lifecycle", () => {
  it("resumes during creation so Safari user activation survives later awaits", async () => {
    const { capture, events, close } = fixture();
    expect(events).toEqual(["resume"]);
    await capture.attach({});
    capture.cancel();
    expect(close).toHaveBeenCalledOnce();
  });

  it.each(["module", "resume"])("bounds hung %s setup and does not wait for context.close", async phase => {
    vi.useFakeTimers();
    const { capture, close, source, resolveModule } = fixture({
      hangingModule: phase === "module", hangingResume: phase === "resume", hangingClose: true,
    });
    const result = expect(capture.attach({})).rejects.toThrow("pcm_setup_timeout");
    await vi.advanceTimersByTimeAsync(1_500);
    await result;
    expect(close).toHaveBeenCalledOnce();
    expect(source).not.toHaveBeenCalled();
    if (phase === "module") resolveModule();
    await Promise.resolve();
    expect(source).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("cancels pending attachment immediately without later building a graph", async () => {
    const { capture, source, resolveModule } = fixture({ hangingModule: true });
    const controller = new AbortController();
    const result = expect(capture.attach({}, { signal: controller.signal })).rejects.toThrow("pcm_cancelled");
    controller.abort();
    await result;
    resolveModule();
    await Promise.resolve();
    expect(source).not.toHaveBeenCalled();
  });

  it("bounds a missing flush response and disconnects before closing", async () => {
    vi.useFakeTimers();
    const { capture, disconnect, close } = fixture({ hangingClose: true });
    await capture.attach({});
    const stopping = capture.stop();
    await vi.advanceTimersByTimeAsync(500);
    await stopping;
    expect(disconnect).toHaveBeenCalledTimes(3);
    expect(close).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  });
});
