import { recordDiagnostic } from "./diagnostics.js";

const MAX_BUFFERED_PCM_BYTES = 5 * 16_000 * 2;
const READY_DEADLINE_MS = 1_500;
const SETUP_DEADLINE_MS = 5_000;

export function isLiveStreamingSupported(scope = globalThis) {
  return typeof scope.WebSocket === "function";
}

function safeFinalResponse(value, requestId) {
  if (
    value?.type !== "final"
    || typeof value.request_id !== "string"
    || value.request_id.toLowerCase() !== requestId.toLowerCase()
    || typeof value.text !== "string"
    || value.text.trim() === ""
    || value.route !== "mac_local"
  ) return null;
  const { type: _type, ...response } = value;
  return response;
}

/** Optional transport. Its failure always leaves the complete file to the caller. */
export function createLiveStream(options) {
  const scope = options.scope ?? globalThis;
  const schedule = scope.setTimeout?.bind(scope) ?? globalThis.setTimeout.bind(globalThis);
  const unschedule = scope.clearTimeout?.bind(scope) ?? globalThis.clearTimeout.bind(globalThis);
  const logDiagnostic = options.recordDiagnostic ?? recordDiagnostic;
  const WebSocketImpl = options.WebSocketImpl ?? scope.WebSocket;
  const ticketController = new AbortController();
  let socket = null;
  let state = "starting";
  let started = false;
  let reportedSending = false;
  let reportedReceiving = false;
  let previewUnavailable = false;
  let receivedFrames = 0;
  let partialCount = 0;
  let queued = [];
  let queuedBytes = 0;
  let setupTimer = null;
  let finishResolve = null;
  let readyResolve = null;
  const readyPromise = new Promise((resolve) => { readyResolve = resolve; });
  const finalPromise = new Promise((resolve) => { finishResolve = resolve; });

  function diagnostic(phase, outcome, code) {
    void logDiagnostic({
      operation: "live_transcription", phase, outcome,
      requestId: options.requestId, code, receivedFrames, partialCount,
    });
  }

  function closeSocket() {
    const active = socket;
    socket = null;
    try { active?.close(1000); } catch { /* already closed */ }
  }

  function settle(value, code = "STREAM_ENDED") {
    if (state === "done") return;
    state = "done";
    if (setupTimer !== null) unschedule(setupTimer);
    setupTimer = null;
    ticketController.abort();
    queued = [];
    queuedBytes = 0;
    readyResolve?.(false);
    readyResolve = null;
    finishResolve?.(value);
    finishResolve = null;
    if (value === null) {
      diagnostic("stream", "failed", code);
      options.onStatus?.("fallback", code);
    }
  }

  function fail(code) {
    settle(null, code);
    closeSocket();
  }

  function reportSending() {
    if (reportedSending) return;
    reportedSending = true;
    if (!reportedReceiving && !previewUnavailable) options.onStatus?.("sending", "OK");
  }

  function reportReceiving() {
    if (reportedReceiving) return;
    reportedReceiving = true;
    diagnostic("stream", "succeeded", "STREAM_AUDIO_RECEIVED");
    if (!previewUnavailable) options.onStatus?.("receiving", "STREAM_AUDIO_RECEIVED");
  }

  function sendAudio(chunk) {
    if (state !== "ready" || socket === null) return false;
    // Bound the browser's own outgoing queue as well as our pre-ready buffer.
    if ((socket.bufferedAmount ?? 0) + chunk.byteLength > MAX_BUFFERED_PCM_BYTES) {
      fail("STREAM_BUFFER_LIMIT");
      return false;
    }
    try {
      socket.send(chunk);
      reportSending();
      return true;
    } catch {
      fail("STREAM_SOCKET_FAILED");
      return false;
    }
  }

  function sendQueued() {
    const pending = queued;
    queued = [];
    queuedBytes = 0;
    for (const chunk of pending) if (!sendAudio(chunk)) break;
  }

  async function start() {
    if (started || state === "done") return false;
    started = true;
    if (!isLiveStreamingSupported({ WebSocket: WebSocketImpl })) {
      fail("STREAM_UNSUPPORTED");
      return false;
    }
    setupTimer = schedule(() => fail("STREAM_SETUP_TIMEOUT"), SETUP_DEADLINE_MS);
    try {
      const grant = await Promise.race([
        options.api.createStreamTicket({
          requestId: options.requestId,
          mode: options.mode,
          allowCloudFallback: options.allowCloudFallback,
          signal: ticketController.signal,
        }),
        readyPromise,
      ]);
      if (state === "done") return false;
      if (
        grant?.request_id !== options.requestId
        || grant.protocol !== "local-dictation.v1"
        || typeof grant.ticket !== "string"
        || grant.stream_path !== "/stream"
      ) {
        fail("STREAM_TICKET_INVALID");
        return false;
      }
      const target = new URL(grant.stream_path, scope.location.href);
      target.protocol = target.protocol === "https:" ? "wss:" : "ws:";
      const active = new WebSocketImpl(target.href, [grant.protocol, grant.ticket]);
      socket = active;
      active.binaryType = "arraybuffer";
      active.onopen = () => {
        if (state === "done" || socket !== active) return;
        if (active.protocol !== grant.protocol) {
          fail("STREAM_PROTOCOL_REFUSED");
          return;
        }
        diagnostic("socket", "succeeded", "CONNECTED");
      };
      active.onmessage = (event) => {
        if (state === "done" || socket !== active || typeof event.data !== "string") return;
        let message;
        try { message = JSON.parse(event.data); } catch { return; }
        if (typeof message?.request_id !== "string"
          || message.request_id.toLowerCase() !== options.requestId.toLowerCase()) return;
        if (message.type === "ready" && state === "starting") {
          state = "ready";
          unschedule(setupTimer);
          setupTimer = null;
          readyResolve?.(true);
          readyResolve = null;
          sendQueued();
          return;
        }
        if (message.type === "audio_received" && Number.isSafeInteger(message.received_frames)
          && message.received_frames > 0 && message.received_frames <= 1_000_000) {
          receivedFrames = Math.max(receivedFrames, message.received_frames);
          reportReceiving();
          return;
        }
        if (message.type === "preview_unavailable") {
          previewUnavailable = true;
          diagnostic("stream", "failed", "STREAM_PREVIEW_UNAVAILABLE");
          options.onStatus?.("preview_unavailable", "STREAM_PREVIEW_UNAVAILABLE");
          return;
        }
        if (message.type === "partial" && typeof message.text === "string" && message.text.trim() !== "") {
          partialCount += 1;
          reportReceiving(); // Older Mac builds do not send audio acknowledgements.
          if (partialCount === 1) diagnostic("stream", "succeeded", "STREAM_PARTIAL_RECEIVED");
          options.onPartial?.(message.text);
          return;
        }
        const final = safeFinalResponse(message, options.requestId);
        if (final !== null) {
          diagnostic("final", "succeeded", "OK");
          settle(final);
          closeSocket();
          return;
        }
        if (message.type === "error") fail("STREAM_REMOTE_FAILED");
      };
      active.onerror = () => { if (socket === active) fail("STREAM_SOCKET_FAILED"); };
      active.onclose = () => { if (socket === active) fail("STREAM_CLOSED"); };
      return true;
    } catch (error) {
      if (state !== "done") fail(error?.name === "SecurityError" ? "STREAM_POLICY_BLOCKED" : "STREAM_SETUP_FAILED");
      return false;
    }
  }

  async function until(promise, milliseconds) {
    let timer;
    try {
      return await Promise.race([
        promise,
        new Promise((resolve) => { timer = schedule(() => resolve(null), milliseconds); }),
      ]);
    } finally {
      if (timer !== undefined) unschedule(timer);
    }
  }

  return {
    start,
    push(chunk) {
      if (!(chunk instanceof ArrayBuffer) || chunk.byteLength === 0 || state === "done") return false;
      if (state === "ready") return sendAudio(chunk);
      if (queuedBytes + chunk.byteLength > MAX_BUFFERED_PCM_BYTES) {
        fail("STREAM_BUFFER_LIMIT");
        return false;
      }
      queued.push(chunk);
      queuedBytes += chunk.byteLength;
      return true;
    },

    async finish(durationSeconds) {
      const ready = state === "ready" ? true : await until(readyPromise, READY_DEADLINE_MS);
      if (ready !== true || state !== "ready" || socket === null) {
        fail("STREAM_NOT_READY");
        return null;
      }
      try {
        socket.send(JSON.stringify({ type: "finish", duration_seconds: Math.max(1, Math.round(durationSeconds)) }));
      } catch {
        fail("STREAM_SOCKET_FAILED");
        return null;
      }
      const deadline = Math.min(155_000, Math.max(45_000, Math.ceil(durationSeconds * 1_250 + 15_000)));
      const result = await until(finalPromise, deadline);
      if (result === null && state !== "done") fail("STREAM_FINAL_TIMEOUT");
      return result;
    },

    cancel() {
      if (state === "ready" && socket !== null) {
        try { socket.send(JSON.stringify({ type: "cancel" })); } catch { /* socket closed */ }
      }
      fail("STREAM_CANCELLED");
    },

    captureFailed() { fail("STREAM_CAPTURE_FAILED"); },
  };
}
