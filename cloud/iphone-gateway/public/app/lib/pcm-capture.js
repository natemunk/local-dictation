const FLUSH_TIMEOUT_MS = 500;
const ATTACH_TIMEOUT_MS = 1_500;

export function isPCMStreamingSupported(scope = globalThis) {
  const AudioContext = scope.AudioContext ?? scope.webkitAudioContext;
  return typeof AudioContext === "function"
    && typeof scope.AudioWorkletNode === "function";
}

/** Borrow microphone tracks; a failed optional tap must not stop the file recorder. */
export function createPCMCapture(options = {}) {
  const scope = options.scope ?? globalThis;
  if (!isPCMStreamingSupported(scope)) throw new Error("pcm_unsupported");
  const schedule = scope.setTimeout?.bind(scope) ?? globalThis.setTimeout.bind(globalThis);
  const unschedule = scope.clearTimeout?.bind(scope) ?? globalThis.clearTimeout.bind(globalThis);
  const AudioContext = scope.AudioContext ?? scope.webkitAudioContext;
  const context = new AudioContext({ latencyHint: "interactive" });
  // Resume in the initiating user gesture, before microphone permission or
  // worklet download awaits can consume Safari's transient activation.
  let resumed;
  try { resumed = Promise.resolve(context.resume()); } catch (error) { resumed = Promise.reject(error); }
  void resumed.catch(() => {});
  let source = null;
  let node = null;
  let sink = null;
  let stopped = false;
  let stopError = new Error("pcm_cancelled");
  let preparation = null;
  let flushResolve = null;
  let cancelledResolve;
  const cancelled = new Promise((resolve) => { cancelledResolve = resolve; });

  async function bounded(work, milliseconds, code) {
    let timer;
    try {
      return await Promise.race([
        work,
        cancelled.then(() => { throw stopError; }),
        new Promise((_, reject) => { timer = schedule(() => reject(new Error(code)), milliseconds); }),
      ]);
    } finally {
      if (timer !== undefined) unschedule(timer);
    }
  }

  function releaseGraph() {
    for (const item of [source, node, sink]) {
      try { item?.disconnect(); } catch { /* already disconnected */ }
    }
    if (node !== null) node.port.onmessage = null;
    source = null;
    node = null;
    sink = null;
  }

  function closeContext() {
    // Disconnection is immediate; an unresponsive browser close cannot hold up
    // Stop or the completed-file upload.
    try { void Promise.resolve(context.close()).catch(() => {}); } catch { /* already closed */ }
  }

  function cancel(error = new Error("pcm_cancelled")) {
    if (stopped) return;
    stopped = true;
    stopError = error;
    cancelledResolve();
    flushResolve?.();
    flushResolve = null;
    releaseGraph();
    closeContext();
  }

  async function prepare() {
    if (stopped) throw new Error("pcm_cancelled");
    preparation ??= context.audioWorklet.addModule("/app/lib/pcm-worklet.js");
    try {
      await bounded(preparation, ATTACH_TIMEOUT_MS, "pcm_setup_timeout");
    } catch (error) {
      cancel(error);
      throw error;
    }
  }

  return {
    prepare,
    async attach(stream, { signal } = {}) {
      const abort = () => cancel();
      signal?.addEventListener("abort", abort, { once: true });
      if (signal?.aborted) cancel();
      try {
        await bounded(Promise.all([prepare(), resumed]), ATTACH_TIMEOUT_MS, "pcm_setup_timeout");
        if (stopped) throw new Error("pcm_cancelled");
        source = context.createMediaStreamSource(stream);
        node = new scope.AudioWorkletNode(context, "local-dictation-pcm");
        sink = context.createGain();
        sink.gain.value = 0;
        node.port.onmessage = (event) => {
          if (event.data?.type === "pcm" && event.data.buffer instanceof ArrayBuffer) {
            options.onChunk?.(event.data.buffer);
          } else if (event.data?.type === "flushed" && flushResolve !== null) {
            const resolve = flushResolve;
            flushResolve = null;
            resolve();
          }
        };
        source.connect(node);
        node.connect(sink);
        sink.connect(context.destination);
      } catch (error) {
        cancel(error);
        throw error;
      } finally {
        signal?.removeEventListener("abort", abort);
      }
    },

    async stop() {
      if (stopped) return;
      try {
        if (node !== null) {
          await bounded(new Promise((resolve) => {
            flushResolve = resolve;
            node.port.postMessage({ type: "flush" });
          }), FLUSH_TIMEOUT_MS, "pcm_flush_timeout");
        }
      } catch { /* The complete MediaRecorder file remains authoritative. */ }
      cancel();
    },
    cancel,
  };
}
