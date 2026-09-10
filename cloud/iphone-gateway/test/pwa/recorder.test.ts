import { afterEach, describe, expect, it, vi } from "vitest";
import {
  MAX_RECORDING_BYTES,
  MAX_RECORDING_MS,
  PREFERRED_MIME_TYPES,
  baseMimeType,
  createRecorder,
  isGatewayCompatible,
  isRecordingSupported,
  pickMimeType,
} from "../../public/app/lib/recorder.js";
import { isPCMStreamingSupported } from "../../public/app/lib/pcm-capture.js";

function fakeScope(supported: string[] | null, withMedia = true): any {
  const MediaRecorder: any = supported === null
    ? undefined
    : function MediaRecorderStub() { /* constructed only in a browser */ };
  if (supported !== null) {
    MediaRecorder.isTypeSupported = (type: string) => supported.includes(type);
  }
  return {
    MediaRecorder,
    navigator: withMedia ? { mediaDevices: { getUserMedia: async () => ({}) } } : {},
  };
}

afterEach(() => {
  vi.useRealTimers();
  delete (globalThis as any).MediaRecorder;
});

describe("limits", () => {
  it("mirrors the gateway contract", () => {
    expect(MAX_RECORDING_MS).toBe(10 * 60 * 1000);
    expect(MAX_RECORDING_BYTES).toBe(12 * 1024 * 1024);
  });
});

describe("isRecordingSupported", () => {
  it("requires both MediaRecorder and getUserMedia", () => {
    expect(isRecordingSupported(fakeScope(["audio/mp4"]))).toBe(true);
    expect(isRecordingSupported(fakeScope(null))).toBe(false);
    expect(isRecordingSupported(fakeScope(["audio/mp4"], false))).toBe(false);
  });
});

describe("isPCMStreamingSupported", () => {
  it("requires both an audio context and audio worklet node", () => {
    const AudioContext = function AudioContextStub() {};
    const AudioWorkletNode = function AudioWorkletNodeStub() {};
    expect(isPCMStreamingSupported({ AudioContext, AudioWorkletNode } as any)).toBe(true);
    expect(isPCMStreamingSupported({ AudioContext } as any)).toBe(false);
    expect(isPCMStreamingSupported({ AudioWorkletNode } as any)).toBe(false);
  });
});

describe("pickMimeType", () => {
  it("prefers audio/mp4 when the browser supports it", () => {
    expect(pickMimeType(fakeScope(["audio/webm", "audio/mp4"]))).toBe("audio/mp4");
    expect(PREFERRED_MIME_TYPES[0]).toBe("audio/mp4");
  });

  it("falls back to whatever the browser really supports", () => {
    expect(pickMimeType(fakeScope(["audio/webm;codecs=opus"]))).toBe("audio/webm;codecs=opus");
  });

  it("returns null when nothing is supported or the API is absent", () => {
    expect(pickMimeType(fakeScope([]))).toBe(null);
    expect(pickMimeType(fakeScope(null))).toBe(null);
    expect(pickMimeType({ MediaRecorder: function stub() {} } as any)).toBe(null);
  });
});

describe("baseMimeType", () => {
  it("drops codec parameters and normalises case", () => {
    expect(baseMimeType("audio/webm;codecs=opus")).toBe("audio/webm");
    expect(baseMimeType("Audio/MP4")).toBe("audio/mp4");
    expect(baseMimeType("")).toBe("");
    expect(baseMimeType(undefined as any)).toBe("");
  });
});

describe("isGatewayCompatible", () => {
  it.each(["audio/mp4", "audio/m4a", "audio/wav", "audio/x-m4a", "audio/mp4;codecs=mp4a.40.2"])(
    "accepts %s",
    (mimeType) => {
      expect(isGatewayCompatible(mimeType)).toBe(true);
    },
  );

  it.each(["audio/webm", "audio/webm;codecs=opus", "audio/ogg", ""])(
    "rejects %s so the UI can warn",
    (mimeType) => {
      expect(isGatewayCompatible(mimeType)).toBe(false);
    },
  );
});

describe("createRecorder", () => {
  it("attaches a borrowed stream hook before MediaRecorder starts", async () => {
    const events: string[] = [];
    const track = { stop: () => events.push("track-stopped") };
    const microphoneStream = { getTracks: () => [track] };

    class MediaRecorderStub {
      static isTypeSupported(type: string) { return type === "audio/mp4"; }
      state = "inactive";
      mimeType = "audio/mp4";
      ondataavailable: ((event: { data: Blob }) => void) | null = null;
      onerror: (() => void) | null = null;
      onstop: (() => void) | null = null;

      start() {
        events.push("media-started");
        this.state = "recording";
      }

      stop() {
        this.state = "inactive";
        this.onstop?.();
      }
    }

    const scope: any = {
      MediaRecorder: MediaRecorderStub,
      Blob,
      navigator: {
        mediaDevices: {
          getUserMedia: async () => {
            events.push("microphone-ready");
            return microphoneStream;
          },
        },
      },
      setInterval: () => 1,
      clearInterval: () => {},
    };
    const recorder = createRecorder({
      scope,
      onStreamReady: async (stream: unknown) => {
        expect(stream).toBe(microphoneStream);
        events.push("stream-attached");
      },
    });

    await recorder.start();
    expect(events).toEqual(["microphone-ready", "stream-attached", "media-started"]);
    recorder.cancel();
    expect(events.at(-1)).toBe("track-stopped");
  });

  it("preserves file recording when the optional streaming hook fails", async () => {
    let stopped = false;
    let constructed = false;
    class MediaRecorderStub {
      static isTypeSupported() { return true; }
      constructor() { constructed = true; }
      state = "inactive";
      start() { this.state = "recording"; }
      stop() { this.state = "inactive"; }
    }
    const scope: any = {
      MediaRecorder: MediaRecorderStub,
      navigator: {
        mediaDevices: {
          getUserMedia: async () => ({
            getTracks: () => [{ stop: () => { stopped = true; } }],
          }),
        },
      },
      setInterval: () => 1,
      clearInterval: () => {},
    };
    const recorder = createRecorder({
      scope,
      onStreamReady: async () => { throw new Error("tap_failed"); },
    });

    await expect(recorder.start()).resolves.toBeDefined();
    expect(stopped).toBe(false);
    expect(constructed).toBe(true);
    recorder.cancel();
    expect(stopped).toBe(true);
  });

  it("starts the backup after a bounded hanging hook and aborts the optional tap", async () => {
    vi.useFakeTimers();
    let signal: AbortSignal | undefined;
    const track = { stop: vi.fn() };
    class Recorder {
      static isTypeSupported() { return true; }
      state = "inactive";
      mimeType = "audio/mp4";
      start() { this.state = "recording"; }
      stop() { this.state = "inactive"; }
    }
    const onStreamError = vi.fn();
    const recorder = createRecorder({ scope: {
      MediaRecorder: Recorder, navigator: { mediaDevices: {
        getUserMedia: async () => ({ getTracks: () => [track] }),
      } }, setInterval, clearInterval, setTimeout, clearTimeout,
    } as any, onStreamError, onStreamReady: (_stream, inputSignal) => {
      signal = inputSignal;
      return new Promise(() => {});
    } });
    const starting = recorder.start();
    await vi.advanceTimersByTimeAsync(2_000);
    await starting;
    expect(signal?.aborted).toBe(true);
    expect(onStreamError).toHaveBeenCalledOnce();
    expect(recorder.active).toBe(true);
    expect(track.stop).not.toHaveBeenCalled();
    recorder.cancel();
    expect(track.stop).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("releases late microphone permission after cancellation without starting capture", async () => {
    let grant!: (stream: unknown) => void;
    const track = { stop: vi.fn() };
    const Recorder = vi.fn();
    const recorder = createRecorder({ scope: { MediaRecorder: Recorder,
      navigator: { mediaDevices: { getUserMedia: () => new Promise(resolve => { grant = resolve; }) } },
    } as any });
    const starting = expect(recorder.start()).rejects.toThrow("recording_cancelled");
    recorder.cancel();
    grant({ getTracks: () => [track] });
    await starting;
    expect(track.stop).toHaveBeenCalledOnce();
    expect(Recorder).not.toHaveBeenCalled();
  });
});
