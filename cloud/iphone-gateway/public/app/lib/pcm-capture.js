const FLUSH_TIMEOUT_MS = 500;

export function isPCMStreamingSupported(scope = globalThis) {
  const AudioContext = scope.AudioContext ?? scope.webkitAudioContext;
  return typeof AudioContext === "function"
    && typeof scope.AudioWorkletNode === "function";
}

/**
 * Tap an existing microphone stream without owning its tracks. The normal
 * MediaRecorder can therefore continue producing the complete backup file.
 */
export function createPCMCapture(options = {}) {
  const scope = options.scope ?? globalThis;
  if (!isPCMStreamingSupported(scope)) throw new Error("pcm_unsupported");

  const AudioContext = scope.AudioContext ?? scope.webkitAudioContext;
  const context = new AudioContext({ latencyHint: "interactive" });
  let source = null;
  let node = null;
  let sink = null;
  let stopped = false;
  let prepared = false;
  let flushResolve = null;

  async function prepare() {
    if (prepared || stopped) return;
    await context.audioWorklet.addModule("/app/lib/pcm-worklet.js");
    if (!stopped) prepared = true;
  }

  function releaseGraph() {
    source?.disconnect();
    node?.disconnect();
    sink?.disconnect();
    if (node !== null) node.port.onmessage = null;
    source = null;
    node = null;
    sink = null;
  }

  return {
    prepare,

    async attach(stream) {
      await prepare();
      if (stopped) return;
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
      await context.resume();
    },

    async stop() {
      if (stopped) return;
      stopped = true;
      if (node !== null) {
        await Promise.race([
          new Promise((resolve) => {
            flushResolve = resolve;
            node.port.postMessage({ type: "flush" });
          }),
          new Promise((resolve) => scope.setTimeout(resolve, FLUSH_TIMEOUT_MS)),
        ]);
      }
      flushResolve = null;
      releaseGraph();
      await context.close().catch(() => {});
    },

    async cancel() {
      if (stopped) return;
      stopped = true;
      flushResolve = null;
      releaseGraph();
      await context.close().catch(() => {});
    },
  };
}
