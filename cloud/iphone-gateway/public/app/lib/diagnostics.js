// Bounded, transcript-free diagnostics for troubleshooting the installed PWA.
// Only the closed field set below is persisted. Callers cannot add messages,
// response bodies, audio, credentials, headers, URLs, or transcript text.

const DB_NAME = "dictation-inbox-diagnostics";
const DB_VERSION = 1;
const STORE_EVENTS = "events";
const MAX_EVENTS = 100;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CODES = new Set([
  "OK",
  "REQUEST_STARTED",
  "MISSING_CREDENTIALS",
  "NETWORK_ERROR",
  "ACCESS_DENIED",
  "MAC_UNAVAILABLE",
  "HISTORY_DISABLED",
  "HISTORY_CHANGED",
  "INVALID_REQUEST",
  "INVALID_CONTENT_LENGTH",
  "INVALID_AUDIO_DURATION",
  "INVALID_DICTATION_MODE",
  "INVALID_DICTATION_CLIENT",
  "INVALID_CLOUD_FALLBACK",
  "INVALID_REQUEST_ID",
  "INVALID_LANGUAGE",
  "EMPTY_AUDIO",
  "PAYLOAD_TOO_LARGE",
  "ORIGIN_AUTH_FAILED",
  "UNSUPPORTED_AUDIO_TYPE",
  "UNSUPPORTED_CONTENT_ENCODING",
  "INVALID_AUDIO",
  "AUDIO_TOO_LARGE",
  "AUDIO_TOO_LONG",
  "CLOUD_FALLBACK_FAILED",
  "CLOUD_FALLBACK_INVALID_RESPONSE",
  "TRANSCRIPTION_UNAVAILABLE",
  "UNEXPECTED_RESPONSE",
  "LOCAL_HISTORY_SAVE_FAILED",
  "METHOD_NOT_ALLOWED",
  "APP_UNAVAILABLE",
  "NOT_FOUND",
]);
const OPERATIONS = new Set([
  "transcription",
  "health",
  "history_manifest",
  "history_page",
  "history_operations",
]);
const PHASES = new Set(["authentication", "gateway", "response", "local_history"]);
const OUTCOMES = new Set(["started", "succeeded", "failed"]);
const ROUTES = new Set(["none", "mac_local", "cloud_fallback"]);

function promisify(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("diagnostics_request_failed"));
  });
}

function transactionDone(transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve(undefined);
    transaction.onabort = () => reject(transaction.error ?? new Error("diagnostics_aborted"));
    transaction.onerror = () => reject(transaction.error ?? new Error("diagnostics_failed"));
  });
}

function openDiagnosticsDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(STORE_EVENTS)) {
        request.result.createObjectStore(STORE_EVENTS, { keyPath: "sequence", autoIncrement: true });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("diagnostics_open_failed"));
    request.onblocked = () => reject(new Error("diagnostics_blocked"));
  });
}

function safeEnum(value, allowed, fallback) {
  return typeof value === "string" && allowed.has(value) ? value : fallback;
}

function safeCode(value) {
  return typeof value === "string" && CODES.has(value) ? value : "UNEXPECTED_ERROR";
}

function safeRequestId(value) {
  return typeof value === "string" && UUID_PATTERN.test(value) ? value.toLowerCase() : "none";
}

function safeInteger(value, maximum) {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.max(0, Math.min(maximum, Math.round(value)))
    : 0;
}

function safeEvent(event, now) {
  return {
    at: now().toISOString(),
    operation: safeEnum(event.operation, OPERATIONS, "unknown"),
    phase: safeEnum(event.phase, PHASES, "unknown"),
    outcome: safeEnum(event.outcome, OUTCOMES, "unknown"),
    request_id: safeRequestId(event.requestId),
    status: safeInteger(event.status, 599),
    code: safeCode(event.code),
    route: safeEnum(event.route, ROUTES, "none"),
    latency_ms: safeInteger(event.latencyMs, 30 * 60 * 1000),
  };
}

/**
 * Persist one allowlisted diagnostic event. Failures are swallowed so logging
 * can never block recording, transcription, clipboard access, or history.
 */
export async function recordDiagnostic(event, now = () => new Date()) {
  const safe = safeEvent(event, now);
  let handle;
  try {
    handle = await openDiagnosticsDatabase();
    const transaction = handle.transaction(STORE_EVENTS, "readwrite");
    const store = transaction.objectStore(STORE_EVENTS);
    store.add(safe);
    const keys = await promisify(store.getAllKeys());
    const excess = Math.max(0, keys.length - MAX_EVENTS);
    for (const key of keys.slice(0, excess)) store.delete(key);
    await transactionDone(transaction);
  } catch {
    // Diagnostics are best effort and must never affect product behavior.
  } finally {
    handle?.close();
  }
  return safe;
}

export async function listDiagnostics() {
  let handle;
  try {
    handle = await openDiagnosticsDatabase();
    const transaction = handle.transaction(STORE_EVENTS, "readonly");
    const rows = await promisify(transaction.objectStore(STORE_EVENTS).getAll());
    await transactionDone(transaction);
    return rows.map(({ sequence: _sequence, ...event }) => event);
  } catch {
    return [];
  } finally {
    handle?.close();
  }
}

export async function clearDiagnostics() {
  let handle;
  try {
    handle = await openDiagnosticsDatabase();
    const transaction = handle.transaction(STORE_EVENTS, "readwrite");
    transaction.objectStore(STORE_EVENTS).clear();
    await transactionDone(transaction);
  } catch {
    // Clearing diagnostics is best effort and never blocks the rest of Settings.
  } finally {
    handle?.close();
  }
}

export async function formatDiagnostics() {
  const events = await listDiagnostics();
  return [
    "Local Dictation PWA diagnostics v1",
    "No audio, transcripts, credentials, headers, URLs, or raw errors are included.",
    ...events.map((event) => JSON.stringify(event)),
  ].join("\n");
}
