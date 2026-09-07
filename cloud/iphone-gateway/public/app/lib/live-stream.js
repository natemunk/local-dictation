import { recordDiagnostic } from "./diagnostics.js";

const MAX_BUFFERED_PCM_BYTES = 5 * 16_000 * 2;
const READY_DEADLINE_MS = 1_500;

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

/**
 * A best-effort live path. Any setup, socket, or finalization failure resolves
 * to null so the caller can submit its complete MediaRecorder file unchanged.
 */
export function createLiveStream(options) {
  const scope = options.scope ?? globalThis;
  const logDiagnostic = options.recordDiagnostic ?? recordDiagnostic;
  const WebSocketImpl = options.WebSocketImpl ?? scope.WebSocket;
  let socket = null;
  let state = "starting";
  let queued = [];
  let queuedBytes = 0;
  let finishResolve = null;
  let readyResolve = null;
  const readyPromise = new Promise((resolve) => { readyResolve = resolve; });
  const finalPromise = new Promise((resolve) => { finishResolve = resolve; });

  function diagnostic(phase, outcome, code) {
    void logDiagnostic({
      operation: "live_transcription",
      phase,
      outcome,
      requestId: options.requestId,
      code,
    });
  }

  function settle(value, code = "STREAM_ENDED") {
    if (state === "done") return;
    state = "done";
    queued = [];
    queuedBytes = 0;
    readyResolve?.(false);
    readyResolve = null;
    finishResolve?.(value);
    finishResolve = null;
    if (value === null) diagnostic("stream", "failed", code);
  }

  function closeSocket() {
    if (socket === null) return;
    try { socket.close(1000); } catch { /* already closed */ }
    socket = null;
  }

  function fail(code) {
    closeSocket();
    settle(null, code);
  }

  function sendQueued() {
    if (state !== "ready" || socket === null) return;
    for (const chunk of queued) socket.send(chunk);
    queued = [];
    queuedBytes = 0;
  }

  async function start() {
    if (!isLiveStreamingSupported({ WebSocket: WebSocketImpl })) {
      fail("STREAM_UNSUPPORTED");
      return false;
    }
    try {
      const grant = await options.api.createStreamTicket({
        requestId: options.requestId,
        mode: options.mode,
        allowCloudFallback: options.allowCloudFallback,
      });
      if (
        grant?.request_id !== options.requestId
        || typeof grant.protocol !== "string"
        || typeof grant.ticket !== "string"
        || typeof grant.stream_path !== "string"
      ) {
        fail("STREAM_TICKET_INVALID");
        return false;
      }

      const target = new URL(grant.stream_path, scope.location.href);
      target.protocol = target.protocol === "https:" ? "wss:" : "ws:";
      socket = new WebSocketImpl(target.href, [grant.protocol, grant.ticket]);
      socket.binaryType = "arraybuffer";
      socket.onopen = () => {
        if (socket?.protocol !== grant.protocol) {
          fail("STREAM_PROTOCOL_REFUSED");
          return;
        }
        diagnostic("socket", "succeeded", "CONNECTED");
      };
      socket.onmessage = (event) => {
        if (typeof event.data !== "string") return;
        let message;
        try { message = JSON.parse(event.data); } catch { return; }
        if (message?.type === "ready" && state === "starting") {
          state = "ready";
          readyResolve?.(true);
          readyResolve = null;
          sendQueued();
          return;
        }
        if (message?.type === "partial" && typeof message.text === "string") {
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
        if (message?.type === "error") fail("STREAM_REMOTE_FAILED");
      };
      socket.onerror = () => fail("STREAM_SOCKET_FAILED");
      socket.onclose = () => {
        socket = null;
        if (state !== "done") settle(null, "STREAM_CLOSED");
      };
      return true;
    } catch {
      fail("STREAM_SETUP_FAILED");
      return false;
    }
  }

  return {
    start,

    push(chunk) {
      if (!(chunk instanceof ArrayBuffer) || chunk.byteLength === 0 || state === "done") return false;
      if (state === "ready" && socket !== null) {
        socket.send(chunk);
        return true;
      }
      if (queuedBytes + chunk.byteLength > MAX_BUFFERED_PCM_BYTES) {
        fail("STREAM_BUFFER_LIMIT");
        return false;
      }
      queued.push(chunk);
      queuedBytes += chunk.byteLength;
      return true;
    },

    async finish(durationSeconds) {
      const timeout = (milliseconds) => new Promise((resolve) => scope.setTimeout(() => resolve(null), milliseconds));
      const ready = state === "ready"
        ? true
        : await Promise.race([readyPromise, timeout(READY_DEADLINE_MS)]);
      if (ready !== true || state !== "ready" || socket === null) {
        fail("STREAM_NOT_READY");
        return null;
      }
      socket.send(JSON.stringify({
        type: "finish",
        duration_seconds: Math.max(1, Math.round(durationSeconds)),
      }));
      const finalDeadline = Math.min(
        155_000,
        Math.max(45_000, Math.ceil(durationSeconds * 1_250 + 15_000)),
      );
      const result = await Promise.race([finalPromise, timeout(finalDeadline)]);
      if (result === null && state !== "done") fail("STREAM_FINAL_TIMEOUT");
      return result;
    },

    cancel() {
      if (state === "ready" && socket !== null) {
        try { socket.send(JSON.stringify({ type: "cancel" })); } catch { /* socket closed */ }
      }
      fail("STREAM_CANCELLED");
    },
  };
}
