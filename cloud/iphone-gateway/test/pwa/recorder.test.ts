import { afterEach, describe, expect, it } from "vitest";
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

  it("releases the microphone when the pre-recording hook fails", async () => {
    let stopped = false;
    let constructed = false;
    class MediaRecorderStub {
      static isTypeSupported() { return true; }
      constructor() { constructed = true; }
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
    };
    const recorder = createRecorder({
      scope,
      onStreamReady: async () => { throw new Error("tap_failed"); },
    });

    await expect(recorder.start()).rejects.toThrow("tap_failed");
    expect(stopped).toBe(true);
    expect(constructed).toBe(false);
  });
});
