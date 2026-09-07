// MediaRecorder wrapper.
//
// Privacy: the recorded chunks live in memory only. They are handed to the
// caller as a Blob, uploaded, and dropped. Nothing in this module writes to any
// persistent store.

/** Contract limits, mirrored from the gateway. */
export const MAX_RECORDING_MS = 10 * 60 * 1000;
export const MAX_RECORDING_BYTES = 12 * 1024 * 1024;

/** Preference order; the first supported type wins. */
export const PREFERRED_MIME_TYPES = Object.freeze([
  "audio/mp4",
  "audio/mp4;codecs=mp4a.40.2",
  "audio/aac",
  "audio/wav",
  "audio/webm;codecs=opus",
  "audio/webm",
]);

/** MIME types the gateway accepts; anything else is uploaded but will be refused. */
const GATEWAY_AUDIO_TYPES = new Set([
  "audio/m4a",
  "audio/mp4",
  "audio/wav",
  "audio/x-m4a",
  "audio/x-wav",
  "audio/wave",
]);

export function isRecordingSupported(scope = globalThis) {
  return typeof scope.MediaRecorder === "function"
    && scope.navigator !== undefined
    && scope.navigator.mediaDevices !== undefined
    && typeof scope.navigator.mediaDevices.getUserMedia === "function";
}

/** First MIME type this browser can actually produce, or null. */
export function pickMimeType(scope = globalThis) {
  const Recorder = scope.MediaRecorder;
  if (typeof Recorder !== "function") return null;
  if (typeof Recorder.isTypeSupported !== "function") return null;
  for (const candidate of PREFERRED_MIME_TYPES) {
    if (Recorder.isTypeSupported(candidate)) return candidate;
  }
  return null;
}

/** Bare type without codec parameters, as sent in `Content-Type`. */
export function baseMimeType(mimeType) {
  if (typeof mimeType !== "string" || mimeType === "") return "";
  return mimeType.split(";", 1)[0].trim().toLowerCase();
}

/** True when the gateway will accept this recording's container. */
export function isGatewayCompatible(mimeType) {
  return GATEWAY_AUDIO_TYPES.has(baseMimeType(mimeType));
}

/**
 * Create a recorder.
 *
 * @param {{
 *   onElapsed?: (ms: number) => void,
 *   onError?: (error: Error) => void,
 *   onAutoStop?: (reason: "duration" | "size") => void,
 *   onStreamReady?: (stream: MediaStream) => Promise<void> | void,
 *   scope?: typeof globalThis,
 * }} [handlers]
 */
export function createRecorder(handlers = {}) {
  const scope = handlers.scope ?? globalThis;
  let recorder = null;
  let stream = null;
  let chunks = [];
  let bytes = 0;
  let startedAt = 0;
  let timer = null;
  let stopReason = null;
  let settle = null;

  function releaseTracks() {
    if (stream !== null) {
      for (const track of stream.getTracks()) track.stop();
      stream = null;
    }
    if (timer !== null) {
      scope.clearInterval(timer);
      timer = null;
    }
  }

  function discard() {
    chunks = [];
    bytes = 0;
  }

  function fail(error) {
    releaseTracks();
    discard();
    recorder = null;
    if (settle !== null) {
      const reject = settle.reject;
      settle = null;
      reject(error);
    }
    handlers.onError?.(error);
  }

  return {
    get active() {
      return recorder !== null && recorder.state === "recording";
    },

    get elapsedMs() {
      return startedAt === 0 ? 0 : Date.now() - startedAt;
    },

    /** Ask for the microphone and start capturing. */
    async start() {
      if (!isRecordingSupported(scope)) {
        throw new Error("recording_unsupported");
      }
      const mimeType = pickMimeType(scope);
      try {
        stream = await scope.navigator.mediaDevices.getUserMedia({ audio: true });

        // A best-effort streaming tap may attach here. MediaRecorder starts
        // only after the hook resolves, so both transports begin with the
        // same first captured sample. The caller owns any hook failure and can
        // resolve normally to preserve file recording as the fallback.
        await handlers.onStreamReady?.(stream);

        const constructorOptions = mimeType === null ? {} : { mimeType };
        recorder = new scope.MediaRecorder(stream, constructorOptions);
        chunks = [];
        bytes = 0;
        stopReason = null;
        startedAt = Date.now();

        recorder.ondataavailable = (event) => {
          const chunk = event.data;
          if (chunk === undefined || chunk === null || chunk.size === 0) return;
          bytes += chunk.size;
          chunks.push(chunk);
          if (bytes > MAX_RECORDING_BYTES) {
            stopReason = "size";
            handlers.onAutoStop?.("size");
            this.stop();
          }
        };
        recorder.onerror = () => fail(new Error("recording_failed"));

        recorder.start(1000);
        timer = scope.setInterval(() => {
          const elapsed = Date.now() - startedAt;
          handlers.onElapsed?.(elapsed);
          if (elapsed >= MAX_RECORDING_MS) {
            stopReason = "duration";
            handlers.onAutoStop?.("duration");
            this.stop();
          }
        }, 250);

        return { mimeType: recorder.mimeType || mimeType || "" };
      } catch (error) {
        releaseTracks();
        discard();
        recorder = null;
        startedAt = 0;
        throw error;
      }
    },

    /**
     * Stop and resolve with the recording. The tracks are released before the
     * promise settles, whichever path is taken.
     */
    stop() {
      if (recorder === null) return Promise.resolve(null);
      if (settle !== null) return settle.promise;

      const active = recorder;
      const promise = new Promise((resolve, reject) => {
        settle = { resolve, reject, promise: null };
        active.onstop = () => {
          const durationMs = Date.now() - startedAt;
          const mimeType = active.mimeType || "audio/mp4";
          const blob = new scope.Blob(chunks, { type: mimeType });
          releaseTracks();
          discard();
          recorder = null;
          startedAt = 0;
          const finish = settle;
          settle = null;
          if (blob.size === 0) {
            reject(new Error("recording_empty"));
            return;
          }
          if (blob.size > MAX_RECORDING_BYTES) {
            reject(new Error("recording_too_large"));
            return;
          }
          finish.resolve({
            blob,
            mimeType,
            durationSeconds: Math.max(1, Math.round(durationMs / 1000)),
            autoStopReason: stopReason,
          });
        };
      });
      if (settle !== null) settle.promise = promise;

      try {
        if (active.state !== "inactive") active.stop();
      } catch (error) {
        fail(error instanceof Error ? error : new Error("recording_failed"));
      }
      return promise;
    },

    /** Abandon a recording without producing a Blob. */
    cancel() {
      const active = recorder;
      recorder = null;
      startedAt = 0;
      settle = null;
      try {
        if (active !== null && active.state !== "inactive") {
          active.onstop = null;
          active.stop();
        }
      } catch {
        // Already stopped.
      }
      releaseTracks();
      discard();
    },
  };
}
