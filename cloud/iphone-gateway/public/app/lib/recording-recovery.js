// Completed audio stays in memory only, until delivery or explicit discard.
export function createRecordingRecovery() {
  let pending = null;
  let controller = null;
  return {
    get pending() { return pending; },
    get busy() { return controller !== null; },
    retain(recording) {
      if (pending !== null || controller !== null) throw new Error("recording_pending");
      pending = recording;
    },
    discard() {
      if (controller !== null) return false;
      pending = null;
      return true;
    },
    cancel() { controller?.abort(); },
    async submit(send) {
      if (pending === null || controller !== null) throw new Error("recording_unavailable");
      const current = pending;
      controller = new AbortController();
      const signal = controller.signal;
      try {
        const response = await send(current, signal);
        if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
        pending = null;
        return response;
      } finally {
        controller = null;
      }
    },
  };
}

export function canApplyUpdate({ recording, recordingStarting, transcribing, hasRecording, editing, settingsOpen }) {
  return !recording && !recordingStarting && !transcribing && !hasRecording && !editing && !settingsOpen;
}
