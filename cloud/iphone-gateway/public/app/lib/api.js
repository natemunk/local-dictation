// Gateway client. Every call is same-origin, `no-store`, and carries the PWA
// Access service token plus `X-Dictation-Client: pwa`.
//
// Credentials are read on demand and never logged, stringified into errors, or
// attached to anything that leaves this module.

import { recordDiagnostic } from "./diagnostics.js";
import { randomUuid } from "./uuid.js";

export const TRANSCRIPTIONS_PATH = "/v1/transcriptions";
export const MANIFEST_PATH = "/v1/history/manifest";
export const HISTORY_PATH = "/v1/history";
export const OPERATIONS_PATH = "/v1/history/operations";
export const HEALTH_PATH = "/v1/healthz";
export const STREAM_TICKET_PATH = "/v1/stream-tickets";

export const MAX_OPERATIONS_PER_REQUEST = 100;
export const HISTORY_PAGE_LIMIT = 100;

/** Error codes the UI branches on. */
export const ERROR_MISSING_CREDENTIALS = "MISSING_CREDENTIALS";
export const ERROR_NETWORK = "NETWORK_ERROR";
export const ERROR_ACCESS_DENIED = "ACCESS_DENIED";
export const ERROR_MAC_UNAVAILABLE = "MAC_UNAVAILABLE";
export const ERROR_HISTORY_DISABLED = "HISTORY_DISABLED";
export const ERROR_HISTORY_CHANGED = "HISTORY_CHANGED";
export const ERROR_INVALID_REQUEST = "INVALID_REQUEST";
export const ERROR_PAYLOAD_TOO_LARGE = "PAYLOAD_TOO_LARGE";
export const ERROR_ORIGIN_AUTH_FAILED = "ORIGIN_AUTH_FAILED";
export const ERROR_UNSUPPORTED_AUDIO = "UNSUPPORTED_AUDIO_TYPE";
export const ERROR_INVALID_AUDIO = "INVALID_AUDIO";
export const ERROR_AUDIO_TOO_LARGE = "AUDIO_TOO_LARGE";
export const ERROR_AUDIO_TOO_LONG = "AUDIO_TOO_LONG";
export const ERROR_CLOUD_FALLBACK_FAILED = "CLOUD_FALLBACK_FAILED";
export const ERROR_CLOUD_FALLBACK_INVALID_RESPONSE = "CLOUD_FALLBACK_INVALID_RESPONSE";
export const ERROR_TRANSCRIPTION_UNAVAILABLE = "TRANSCRIPTION_UNAVAILABLE";
export const ERROR_UNEXPECTED = "UNEXPECTED_RESPONSE";

/** Typed gateway/transport failure. Carries no credentials and no audio. */
export class ApiError extends Error {
  constructor(code, message, options = {}) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = options.status ?? 0;
    this.requestId = options.requestId ?? null;
    this.revision = options.revision ?? null;
  }
}

/** True for the failures that mean "the Mac cannot be reached right now". */
export function isOfflineError(error) {
  return error instanceof ApiError
    && (error.code === ERROR_NETWORK || error.code === ERROR_MAC_UNAVAILABLE);
}

function readRevision(body) {
  const candidates = [body?.revision, body?.error?.revision, body?.error?.details?.revision];
  for (const candidate of candidates) {
    if (typeof candidate === "number" && Number.isFinite(candidate)) return candidate;
  }
  return null;
}

async function readJson(response) {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

async function toApiError(response) {
  const requestId = response.headers.get("X-Request-ID");
  const body = await readJson(response);
  const code = typeof body?.error?.code === "string"
    ? body.error.code
    : (response.status === 401 || response.status === 403
      ? ERROR_ACCESS_DENIED
      : ERROR_UNEXPECTED);
  const message = typeof body?.error?.message === "string"
    ? body.error.message
    : `The gateway returned ${response.status}.`;
  return new ApiError(code, message, {
    status: response.status,
    requestId: typeof body?.request_id === "string" ? body.request_id : requestId,
    revision: readRevision(body),
  });
}

/**
 * @param {{
 *   getCredentials: () => ({ clientId: string, clientSecret: string } | null),
 *   fetchImpl?: typeof fetch,
 *   baseUrl?: string,
 *   newRequestId?: () => string,
 *   recordDiagnostic?: (event: Record<string, unknown>) => unknown,
 * }} options
 */
export function createApiClient(options) {
  const doFetch = options.fetchImpl ?? globalThis.fetch.bind(globalThis);
  const baseUrl = options.baseUrl ?? "";
  const newRequestId = options.newRequestId ?? randomUuid;
  const logDiagnostic = options.recordDiagnostic ?? recordDiagnostic;

  function authHeaders(requestId, operation) {
    const credentials = options.getCredentials();
    if (
      credentials === null
      || typeof credentials.clientId !== "string"
      || typeof credentials.clientSecret !== "string"
      || credentials.clientId === ""
      || credentials.clientSecret === ""
    ) {
      void logDiagnostic({
        operation,
        phase: "authentication",
        outcome: "failed",
        requestId,
        code: ERROR_MISSING_CREDENTIALS,
      });
      throw new ApiError(
        ERROR_MISSING_CREDENTIALS,
        "Add your Access service token in Settings first.",
      );
    }
    return new Headers({
      "CF-Access-Client-Id": credentials.clientId,
      "CF-Access-Client-Secret": credentials.clientSecret,
      "X-Dictation-Client": "pwa",
      "X-Request-ID": requestId,
    });
  }

  async function send(path, init, requestId, operation) {
    const startedAt = Date.now();
    void logDiagnostic({
      operation,
      phase: "gateway",
      outcome: "started",
      requestId,
      code: "REQUEST_STARTED",
    });
    let response;
    try {
      response = await doFetch(`${baseUrl}${path}`, {
        ...init,
        cache: "no-store",
        credentials: "omit",
        redirect: "follow",
      });
    } catch {
      const error = new ApiError(
        ERROR_NETWORK,
        "No connection to the gateway.",
        { requestId },
      );
      void logDiagnostic({
        operation,
        phase: "gateway",
        outcome: "failed",
        requestId,
        code: error.code,
        latencyMs: Date.now() - startedAt,
      });
      throw error;
    }
    if (!response.ok) {
      const error = await toApiError(response);
      void logDiagnostic({
        operation,
        phase: "gateway",
        outcome: "failed",
        requestId: error.requestId ?? requestId,
        status: error.status,
        code: error.code,
        latencyMs: Date.now() - startedAt,
      });
      throw error;
    }
    const body = await readJson(response);
    if (body === null) {
      const error = new ApiError(ERROR_UNEXPECTED, "The gateway sent an unreadable response.", {
        status: response.status,
        requestId,
      });
      void logDiagnostic({
        operation,
        phase: "response",
        outcome: "failed",
        requestId,
        status: response.status,
        code: error.code,
        latencyMs: Date.now() - startedAt,
      });
      throw error;
    }
    void logDiagnostic({
      operation,
      phase: "response",
      outcome: "succeeded",
      requestId: typeof body.request_id === "string" ? body.request_id : requestId,
      status: response.status,
      code: "OK",
      route: typeof body.route === "string" ? body.route : "none",
      latencyMs: Date.now() - startedAt,
    });
    return body;
  }

  return {
    /** Mint a short-lived, single-purpose WebSocket credential. */
    async createStreamTicket({ requestId, mode, allowCloudFallback }) {
      const id = requestId ?? newRequestId();
      const operation = "stream_ticket";
      const headers = authHeaders(id, operation);
      headers.set("X-Dictation-Mode", mode);
      headers.set("X-Allow-Cloud-Fallback", String(Boolean(allowCloudFallback)));
      return send(STREAM_TICKET_PATH, { method: "POST", headers }, id, operation);
    },

    /**
     * Upload one recording. `requestId` doubles as the history entry id, so the
     * caller generates it before recording finishes.
     */
    async transcribe({ blob, mimeType, durationSeconds, mode, allowCloudFallback, requestId }) {
      const id = requestId ?? newRequestId();
      const operation = "transcription";
      const headers = authHeaders(id, operation);
      headers.set("Content-Type", mimeType);
      headers.set("X-Dictation-Mode", mode);
      headers.set("X-Allow-Cloud-Fallback", String(Boolean(allowCloudFallback)));
      headers.set("X-Audio-Duration-Seconds", String(Math.max(1, Math.round(durationSeconds))));
      return send(TRANSCRIPTIONS_PATH, { method: "POST", headers, body: blob }, id, operation);
    },

    async fetchManifest() {
      const requestId = newRequestId();
      const operation = "history_manifest";
      return send(
        MANIFEST_PATH,
        { method: "GET", headers: authHeaders(requestId, operation) },
        requestId,
        operation,
      );
    },

    async fetchHistoryPage({ revision, cursor = null, limit = HISTORY_PAGE_LIMIT }) {
      const requestId = newRequestId();
      const operation = "history_page";
      const query = new URLSearchParams({ revision: String(revision), limit: String(limit) });
      if (cursor !== null && cursor !== undefined) query.set("cursor", String(cursor));
      return send(
        `${HISTORY_PATH}?${query.toString()}`,
        { method: "GET", headers: authHeaders(requestId, operation) },
        requestId,
        operation,
      );
    },

    async postOperations(operations) {
      const requestId = newRequestId();
      const operation = "history_operations";
      const headers = authHeaders(requestId, operation);
      headers.set("Content-Type", "application/json");
      return send(
        OPERATIONS_PATH,
        { method: "POST", headers, body: JSON.stringify({ operations }) },
        requestId,
        operation,
      );
    },

    async healthz() {
      const requestId = newRequestId();
      const operation = "health";
      return send(
        HEALTH_PATH,
        { method: "GET", headers: authHeaders(requestId, operation) },
        requestId,
        operation,
      );
    },
  };
}
