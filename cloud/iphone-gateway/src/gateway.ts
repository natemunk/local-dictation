import {
  STREAM_PATH,
  STREAM_PROTOCOL,
  STREAM_TICKET_PATH,
  StreamTicketError,
  createStreamTicketAuthority,
  type StreamTicketAuthority,
  type StreamTicketGrant,
  type StreamTicketInput,
} from "./streaming";

// Implementation module. Workers reject non-handler named exports from the entry
// module, so every constant, type, and factory lives here and src/index.ts only
// re-exports the fetch handler.
const TRANSCRIBE_PATH = "/v1/transcriptions";
const GATEWAY_HEALTH_PATH = "/v1/healthz";
const ORIGIN_HEALTH_PATH = "/healthz";
const HISTORY_MANIFEST_PATH = "/v1/history/manifest";
const HISTORY_PAGE_PATH = "/v1/history";
const HISTORY_OPERATIONS_PATH = "/v1/history/operations";
const APP_ROOT_PATH = "/app";
const APP_PREFIX = "/app/";
const APP_SHELL_PATH = "/app/index.html";
const APP_IMPORT_PATH = "/app/import";
export const CLOUD_MODEL = "@cf/openai/whisper-large-v3-turbo" as const;

export const MAX_AUDIO_BYTES = 12 * 1024 * 1024;
export const MAX_AUDIO_DURATION_SECONDS = 10 * 60;

export const MAX_HISTORY_OPERATIONS = 100;
export const MAX_HISTORY_OPERATIONS_BYTES = 2 * 1024 * 1024;
export const MAX_HISTORY_RESPONSE_BYTES = 4 * 1024 * 1024;

const MAX_TRANSCRIPT_CHARACTERS = 100_000;
const MAX_ORIGIN_JSON_BYTES = 128 * 1024;
const MAX_HEALTH_JSON_BYTES = 8 * 1024;
const MAC_HEALTH_TIMEOUT_MS = 750;
const MAC_TRANSCRIBE_MINIMUM_TIMEOUT_MS = 45_000;
const MAC_TRANSCRIBE_MAXIMUM_TIMEOUT_MS = 155_000;
const HISTORY_READ_TIMEOUT_MS = 10_000;
const HISTORY_OPERATIONS_TIMEOUT_MS = 20_000;
const MAX_HISTORY_CURSOR_CHARACTERS = 64;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CURSOR_PATTERN = /^[A-Za-z0-9_-]+$/;
const DIGITS_PATTERN = /^\d+$/;
const HASHED_ASSET_PATTERN = /\.[0-9a-f]{8,}\./;

const AUDIO_CONTENT_TYPES = new Set([
  "audio/m4a",
  "audio/mp4",
  "audio/wav",
  "audio/x-m4a",
  "audio/x-wav",
  "audio/wave",
]);

const HISTORY_OPERATION_TYPES = new Set(["import", "edit", "pin", "unpin", "delete"]);

const NO_STORE_HEADERS = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "Pragma": "no-cache",
  "X-Content-Type-Options": "nosniff",
} as const;

const ASSET_SECURITY_HEADERS = {
  "Content-Security-Policy":
    "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Permissions-Policy": "microphone=(self)",
} as const;

const IMMUTABLE_CACHE_CONTROL = "public, max-age=31536000, immutable";
const REVALIDATED_CACHE_CONTROL = "no-cache";

type TranscriptionRoute = "mac_local" | "cloud_fallback";
type CleanupBackend = "apple_foundation" | "deterministic" | "none";
type DictationMode = "clean" | "literal";
export type DictationClient = "shortcut" | "pwa";
export type HistoryState = "saved_on_mac" | "pending_device_sync" | "disabled";
type FallbackReason =
  | "mac_offline"
  | "mac_busy"
  | "mac_unready"
  | "mac_timeout"
  | "local_asr_failed"
  | "remote_preempted";

type MacFallbackReason =
  | "not_configured"
  | "health_timeout"
  | "health_unreachable"
  | "health_authentication_failed"
  | "health_rejected"
  | "health_busy"
  | "health_not_ready"
  | "origin_timeout"
  | "origin_unreachable"
  | "origin_busy"
  | "origin_preempted"
  | "origin_invalid_request"
  | "origin_authentication_failed"
  | "origin_rejected"
  | "origin_invalid_response";

type SafeLogLevel = "info" | "warn" | "error";

type SafeLogEvent = Readonly<Partial<{
  cleanup: CleanupBackend | "none";
  client: DictationClient;
  cloud_fallback_allowed: boolean;
  duration_bucket: string;
  event: string;
  failure_code: string;
  fallback_reason: FallbackReason | MacFallbackReason | "none";
  history_state: HistoryState;
  latency_ms: number;
  media_type: string;
  mode: DictationMode;
  request_id: string;
  route: string;
  size_bucket: string;
  status: number;
}>>;

const SAFE_LOG_EVENTS = {
  started: "transcription_started",
  inputValidated: "transcription_input_validated",
  macSucceeded: "mac_local_succeeded",
  macUnavailable: "mac_local_unavailable",
  cloudStarted: "cloud_fallback_started",
  cloudSucceeded: "cloud_fallback_succeeded",
  cloudFailed: "cloud_fallback_failed",
  completed: "request_completed",
  failed: "request_failed",
} as const;

type AudioInput = Readonly<{
  bytes: ArrayBuffer;
  allowsCloudFallback: boolean;
  client: DictationClient;
  contentType: string;
  durationSeconds: number;
  language: string;
  mode: DictationMode;
  requestId: string;
}>;

type Transcript = Readonly<{
  text: string;
  cleanup: CleanupBackend;
  fallbackReason: FallbackReason | null;
  historyState: HistoryState;
  latencyMs: number;
  route: TranscriptionRoute;
}>;

type MacAttempt =
  | Readonly<{ ok: true; transcript: Transcript }>
  | Readonly<{ ok: false; reason: MacFallbackReason }>;

export type HistoryRequestKind = "manifest" | "page" | "operations";

export type HistoryProxyRequest = Readonly<{
  kind: HistoryRequestKind;
  client: DictationClient;
  requestId: string;
  search: string;
  body: ArrayBuffer | null;
}>;

export type HistoryFailureReason =
  | "disabled"
  | "changed"
  | "invalid_request"
  | "payload_too_large"
  | "auth_failed"
  | "unavailable";

export type HistoryProxyResult =
  | Readonly<{ ok: true; status: number; body: string }>
  | Readonly<{ ok: false; reason: HistoryFailureReason; revision: number | null }>;

export type GatewayRuntime = Readonly<{
  now: () => number;
  requestId: () => string;
  log: (level: SafeLogLevel, event: SafeLogEvent) => void;
  transcribeOnMac: (input: AudioInput) => Promise<MacAttempt>;
  transcribeInCloud: (input: AudioInput) => Promise<Transcript>;
  proxyHistory: (input: HistoryProxyRequest) => Promise<HistoryProxyResult>;
  issueStreamTicket: (input: StreamTicketInput) => Promise<StreamTicketGrant>;
  proxyStream: (request: Request) => Promise<StreamProxyResult>;
  fetchAsset: (request: Request) => Promise<Response>;
}>;

export type StreamProxyResult = Readonly<{
  requestId: string;
  response: Response;
}>;

export type MacOriginConfig = Readonly<{
  originUrl: string;
  accessClientId: string;
  accessClientSecret: string;
  healthTimeoutMs?: number;
  transcribeTimeoutMs?: number;
  historyReadTimeoutMs?: number;
  historyOperationsTimeoutMs?: number;
}>;

export type RequestFetcher = (request: Request) => Promise<Response>;

type WorkersAiInput = Readonly<{
  audio: string;
  task: "transcribe";
  language: string;
  vad_filter: true;
  condition_on_previous_text: true;
}>;

export type WorkersAiRunner = (
  model: typeof CLOUD_MODEL,
  input: WorkersAiInput,
) => Promise<unknown>;

class RequestError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "RequestError";
  }
}
function jsonResponse(body: unknown, status: number, requestId: string): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...NO_STORE_HEADERS,
      "X-Request-ID": requestId,
    },
  });
}

function errorResponse(
  error: RequestError,
  requestId: string,
  extra?: Readonly<Record<string, unknown>>,
): Response {
  return jsonResponse(
    {
      error: {
        code: error.code,
        message: error.message,
      },
      request_id: requestId,
      ...(extra ?? {}),
    },
    error.status,
    requestId,
  );
}

function contentType(request: Request): string {
  return request.headers.get("Content-Type")?.split(";", 1)[0]?.trim().toLowerCase() ?? "";
}

function parseContentLength(request: Request): number | undefined {
  const raw = request.headers.get("Content-Length");
  if (raw === null) return undefined;
  if (!DIGITS_PATTERN.test(raw)) {
    throw new RequestError(400, "INVALID_CONTENT_LENGTH", "Content-Length must be a positive integer.");
  }

  const length = Number(raw);
  if (!Number.isSafeInteger(length) || length <= 0) {
    throw new RequestError(400, "INVALID_CONTENT_LENGTH", "Content-Length must be a positive integer.");
  }
  if (length > MAX_AUDIO_BYTES) {
    throw new RequestError(413, "AUDIO_TOO_LARGE", "Audio must be 12 MiB or smaller.");
  }
  return length;
}

function parseDuration(request: Request): number {
  const raw = request.headers.get("X-Audio-Duration-Seconds");
  if (raw === null || raw.trim() === "") {
    throw new RequestError(
      400,
      "INVALID_AUDIO_DURATION",
      "X-Audio-Duration-Seconds is required.",
    );
  }

  const durationSeconds = Number(raw);
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    throw new RequestError(
      400,
      "INVALID_AUDIO_DURATION",
      "X-Audio-Duration-Seconds must be a positive number.",
    );
  }
  if (durationSeconds > MAX_AUDIO_DURATION_SECONDS) {
    throw new RequestError(413, "AUDIO_TOO_LONG", "Audio must be ten minutes or shorter.");
  }
  return durationSeconds;
}

function parseMode(request: Request): DictationMode {
  const mode = request.headers.get("X-Dictation-Mode")?.trim().toLowerCase();
  if (mode !== "clean" && mode !== "literal") {
    throw new RequestError(400, "INVALID_DICTATION_MODE", "X-Dictation-Mode must be clean or literal.");
  }
  return mode;
}

function parseDictationClient(request: Request): DictationClient {
  const raw = request.headers.get("X-Dictation-Client");
  if (raw === null) return "shortcut";

  const client = raw.trim().toLowerCase();
  if (client === "") return "shortcut";
  if (client !== "shortcut" && client !== "pwa") {
    throw new RequestError(
      400,
      "INVALID_DICTATION_CLIENT",
      "X-Dictation-Client must be shortcut or pwa.",
    );
  }
  return client;
}

function requirePwaClient(request: Request): DictationClient {
  const raw = request.headers.get("X-Dictation-Client")?.trim().toLowerCase();
  if (raw !== "pwa") {
    throw new RequestError(400, "INVALID_REQUEST", "History requests require X-Dictation-Client: pwa.");
  }
  return "pwa";
}

function parseCloudFallback(request: Request): boolean {
  const value = request.headers.get("X-Allow-Cloud-Fallback")?.trim().toLowerCase();
  if (value !== "true" && value !== "false") {
    throw new RequestError(
      400,
      "INVALID_CLOUD_FALLBACK",
      "X-Allow-Cloud-Fallback must be true or false.",
    );
  }
  return value === "true";
}

function parseRequestId(request: Request): string {
  const requestId = request.headers.get("X-Request-ID")?.trim();
  if (requestId === undefined || !UUID_PATTERN.test(requestId)) {
    throw new RequestError(400, "INVALID_REQUEST_ID", "X-Request-ID must be a UUID.");
  }
  return requestId.toLowerCase();
}

function parseLanguage(request: Request): string {
  const language = request.headers.get("X-Transcription-Language")?.trim() || "en";
  if (language.length > 35 || !/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/.test(language)) {
    throw new RequestError(
      400,
      "INVALID_LANGUAGE",
      "X-Transcription-Language must be a valid language tag.",
    );
  }
  return language;
}

function durationBucket(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "none";
  if (seconds <= 15) return "short";
  if (seconds <= 60) return "medium";
  if (seconds <= 180) return "long";
  return "very_long";
}

async function readStreamWithLimit(
  stream: ReadableStream<Uint8Array> | null,
  limit: number,
): Promise<ArrayBuffer> {
  if (stream === null) {
    throw new RequestError(400, "EMPTY_AUDIO", "The request body must contain audio.");
  }

  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value === undefined) continue;

      total += value.byteLength;
      if (total > limit) {
        await reader.cancel("body_too_large");
        throw new RequestError(413, "AUDIO_TOO_LARGE", "Audio must be 12 MiB or smaller.");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  if (total === 0) {
    throw new RequestError(400, "EMPTY_AUDIO", "The request body must contain audio.");
  }

  return joinChunks(chunks, total).buffer as ArrayBuffer;
}

function joinChunks(chunks: readonly Uint8Array[], total: number): Uint8Array {
  const output = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return output;
}

// Reads a bounded body without treating an empty body as an error. Returns undefined
// when the declared or streamed size exceeds the limit, so the caller can fail closed.
async function readBoundedBytes(
  stream: ReadableStream<Uint8Array> | null,
  limit: number,
): Promise<Uint8Array | undefined> {
  if (stream === null) return new Uint8Array(0);

  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let exceeded = false;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value === undefined) continue;

      total += value.byteLength;
      if (total > limit) {
        exceeded = true;
        await reader.cancel("body_too_large");
        break;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  return exceeded ? undefined : joinChunks(chunks, total);
}

function declaredLengthExceeds(response: Response, limit: number): boolean {
  const declaredLength = response.headers.get("Content-Length");
  return declaredLength !== null && DIGITS_PATTERN.test(declaredLength) && Number(declaredLength) > limit;
}

async function parseBoundedJson(response: Response, limit: number): Promise<unknown> {
  if (declaredLengthExceeds(response, limit)) {
    throw new Error("response_too_large");
  }

  const bytes = await readStreamWithLimit(response.body, limit);
  return JSON.parse(new TextDecoder().decode(bytes));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function validatedHistoryState(value: unknown): HistoryState | undefined {
  if (value === undefined || value === null) return "disabled";
  if (value === "saved_on_mac" || value === "pending_device_sync" || value === "disabled") {
    return value;
  }
  return undefined;
}

function requestIdsMatch(responseId: unknown, requestId: string): boolean {
  if (typeof responseId !== "string") return false;
  if (responseId === requestId) return true;

  return (
    UUID_PATTERN.test(responseId) &&
    UUID_PATTERN.test(requestId) &&
    responseId.toLowerCase() === requestId.toLowerCase()
  );
}

function validatedMacTranscript(value: unknown, requestId: string): Transcript | undefined {
  if (
    !isRecord(value) ||
    !requestIdsMatch(value.request_id, requestId) ||
    typeof value.text !== "string" ||
    value.text.trim() === "" ||
    value.text.length > MAX_TRANSCRIPT_CHARACTERS ||
    value.route !== "mac_local" ||
    (value.cleanup !== "apple_foundation" && value.cleanup !== "deterministic" && value.cleanup !== "none") ||
    typeof value.latency_ms !== "number" ||
    !Number.isSafeInteger(value.latency_ms) ||
    value.latency_ms < 0 ||
    (value.fallback_reason !== null && value.fallback_reason !== undefined)
  ) {
    return undefined;
  }

  const historyState = validatedHistoryState(value.history_state);
  if (historyState === undefined) return undefined;

  return {
    text: value.text,
    route: value.route,
    cleanup: value.cleanup,
    latencyMs: value.latency_ms,
    fallbackReason: null,
    historyState,
  };
}

function validatedOrigin(originUrl: string): URL | undefined {
  try {
    const url = new URL(originUrl);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) return undefined;
    if (url.pathname !== "/" && url.pathname !== "") return undefined;
    return url;
  } catch {
    return undefined;
  }
}

function accessHeaders(config: MacOriginConfig): Headers {
  return new Headers({
    "Accept": "application/json",
    "Cache-Control": "no-store",
    "CF-Access-Client-Id": config.accessClientId,
    "CF-Access-Client-Secret": config.accessClientSecret,
  });
}

function isConfiguredOrigin(config: MacOriginConfig): URL | undefined {
  const origin = validatedOrigin(config.originUrl);
  if (origin === undefined) return undefined;
  if (config.accessClientId.trim() === "" || config.accessClientSecret.trim() === "") return undefined;
  return origin;
}

async function requestWithTimeout(
  request: Request,
  fetcher: RequestFetcher,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const timedRequest = new Request(request, { signal: controller.signal });

  try {
    return await fetcher(timedRequest);
  } finally {
    clearTimeout(timeout);
  }
}

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === "AbortError";
}

async function rejectedOriginReason(response: Response): Promise<MacFallbackReason> {
  if (response.status === 409) return "origin_busy";
  if (response.status === 504) return "origin_timeout";
  if (response.status === 401 || response.status === 403) return "origin_authentication_failed";
  if ([400, 413, 415, 422].includes(response.status)) return "origin_invalid_request";
  if (response.status === 503) {
    try {
      const body = await parseBoundedJson(response, MAX_HEALTH_JSON_BYTES);
      if (isRecord(body) && body.error === "remote_preempted") return "origin_preempted";
    } catch {
      // A rejected origin body is diagnostic only; the fixed fallback category is sufficient.
    }
  }
  return "origin_rejected";
}

export function createMacTranscriber(config: MacOriginConfig, fetcher: RequestFetcher) {
  const origin = isConfiguredOrigin(config);

  return async (input: AudioInput): Promise<MacAttempt> => {
    if (origin === undefined) return { ok: false, reason: "not_configured" };

    const healthUrl = new URL(ORIGIN_HEALTH_PATH, origin);
    const healthHeaders = accessHeaders(config);
    healthHeaders.set("X-Request-ID", input.requestId);
    let healthResponse: Response;
    try {
      healthResponse = await requestWithTimeout(
        new Request(healthUrl, {
          method: "GET",
          headers: healthHeaders,
        }),
        fetcher,
        config.healthTimeoutMs ?? MAC_HEALTH_TIMEOUT_MS,
      );
    } catch (error) {
      return { ok: false, reason: isAbortError(error) ? "health_timeout" : "health_unreachable" };
    }

    if (healthResponse.status === 401 || healthResponse.status === 403) {
      return { ok: false, reason: "health_authentication_failed" };
    }
    if (!healthResponse.ok) return { ok: false, reason: "health_rejected" };

    try {
      const health = await parseBoundedJson(healthResponse, MAX_HEALTH_JSON_BYTES);
      if (isRecord(health) && health.busy === true) {
        return { ok: false, reason: "health_busy" };
      }
      if (!isRecord(health) || health.ready !== true) {
        return { ok: false, reason: "health_not_ready" };
      }
    } catch {
      return { ok: false, reason: "health_not_ready" };
    }

    const headers = accessHeaders(config);
    headers.set("Content-Type", input.contentType);
    headers.set("X-Request-ID", input.requestId);
    headers.set("X-Dictation-Mode", input.mode);
    headers.set("X-Dictation-Client", input.client);
    headers.set("X-Allow-Cloud-Fallback", String(input.allowsCloudFallback));
    headers.set("X-Audio-Duration-Seconds", String(input.durationSeconds));

    let originResponse: Response;
    try {
      originResponse = await requestWithTimeout(
        new Request(new URL(TRANSCRIBE_PATH, origin), {
          method: "POST",
          headers,
          body: input.bytes,
        }),
        fetcher,
        config.transcribeTimeoutMs ?? macTranscriptionTimeoutMs(input.durationSeconds),
      );
    } catch (error) {
      return { ok: false, reason: isAbortError(error) ? "origin_timeout" : "origin_unreachable" };
    }

    if (!originResponse.ok) {
      return { ok: false, reason: await rejectedOriginReason(originResponse) };
    }

    try {
      const transcript = validatedMacTranscript(
        await parseBoundedJson(originResponse, MAX_ORIGIN_JSON_BYTES),
        input.requestId,
      );
      return transcript === undefined
        ? { ok: false, reason: "origin_invalid_response" }
        : { ok: true, transcript };
    } catch {
      return { ok: false, reason: "origin_invalid_response" };
    }
  };
}

function historyOriginPath(kind: HistoryRequestKind): string {
  switch (kind) {
    case "manifest":
      return HISTORY_MANIFEST_PATH;
    case "page":
      return HISTORY_PAGE_PATH;
    case "operations":
      return HISTORY_OPERATIONS_PATH;
  }
}

async function historyErrorPayload(response: Response): Promise<Record<string, unknown> | undefined> {
  try {
    if (declaredLengthExceeds(response, MAX_HEALTH_JSON_BYTES)) return undefined;
    const bytes = await readBoundedBytes(response.body, MAX_HEALTH_JSON_BYTES);
    if (bytes === undefined || bytes.byteLength === 0) return undefined;
    const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes));
    return isRecord(parsed) ? parsed : undefined;
  } catch {
    // A rejected origin body is diagnostic only; the fixed failure category is sufficient.
    return undefined;
  }
}

function historyRevision(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null;
}

async function classifyHistoryFailure(response: Response): Promise<HistoryProxyResult> {
  const payload = await historyErrorPayload(response);

  if (response.status === 403 && payload?.error === "history_disabled") {
    return { ok: false, reason: "disabled", revision: null };
  }
  if (response.status === 409 && payload?.error === "history_changed") {
    return { ok: false, reason: "changed", revision: historyRevision(payload.revision) };
  }
  if (response.status === 400) {
    return { ok: false, reason: "invalid_request", revision: null };
  }
  if (response.status === 413) {
    return { ok: false, reason: "payload_too_large", revision: null };
  }
  if (response.status === 401 || response.status === 403) {
    return { ok: false, reason: "auth_failed", revision: null };
  }
  return { ok: false, reason: "unavailable", revision: null };
}

export function createHistoryProxy(config: MacOriginConfig, fetcher: RequestFetcher) {
  const origin = isConfiguredOrigin(config);

  return async (input: HistoryProxyRequest): Promise<HistoryProxyResult> => {
    if (origin === undefined) return { ok: false, reason: "unavailable", revision: null };

    const isOperations = input.kind === "operations";
    const url = new URL(historyOriginPath(input.kind), origin);
    url.search = input.search;

    const headers = accessHeaders(config);
    headers.set("X-Request-ID", input.requestId);
    headers.set("X-Dictation-Client", input.client);
    if (isOperations) headers.set("Content-Type", "application/json; charset=utf-8");

    const timeoutMs = isOperations
      ? config.historyOperationsTimeoutMs ?? HISTORY_OPERATIONS_TIMEOUT_MS
      : config.historyReadTimeoutMs ?? HISTORY_READ_TIMEOUT_MS;

    let response: Response;
    try {
      response = await requestWithTimeout(
        isOperations
          ? new Request(url, { method: "POST", headers, body: input.body })
          : new Request(url, { method: "GET", headers }),
        fetcher,
        timeoutMs,
      );
    } catch {
      // Timeouts and transport failures are both a plain "the Mac did not answer".
      return { ok: false, reason: "unavailable", revision: null };
    }

    if (!response.ok) return classifyHistoryFailure(response);

    if (declaredLengthExceeds(response, MAX_HISTORY_RESPONSE_BYTES)) {
      return { ok: false, reason: "unavailable", revision: null };
    }

    const bytes = await readBoundedBytes(response.body, MAX_HISTORY_RESPONSE_BYTES);
    if (bytes === undefined) return { ok: false, reason: "unavailable", revision: null };

    const body = new TextDecoder().decode(bytes);
    try {
      if (!isRecord(JSON.parse(body))) {
        return { ok: false, reason: "unavailable", revision: null };
      }
    } catch {
      return { ok: false, reason: "unavailable", revision: null };
    }
    return { ok: true, status: response.status, body };
  };
}

/// Validates a short-lived browser ticket and forwards the WebSocket upgrade
/// to the Access-protected Mac origin. Cloudflare proxies the upgraded frames
/// directly; this Worker never inspects or stores audio or transcript frames.
export function createMacStreamProxy(
  config: MacOriginConfig,
  tickets: StreamTicketAuthority,
  fetcher: RequestFetcher,
) {
  const origin = isConfiguredOrigin(config);

  return async (request: Request): Promise<StreamProxyResult> => {
    if (origin === undefined) throw new RequestError(503, "MAC_UNAVAILABLE", "The Mac is unavailable.");

    const requestURL = new URL(request.url);
    if (request.headers.get("Origin") !== requestURL.origin) {
      throw new RequestError(403, "STREAM_ORIGIN_REFUSED", "The stream origin was refused.");
    }
    if (request.headers.get("Upgrade")?.trim().toLowerCase() !== "websocket") {
      throw new RequestError(426, "WEBSOCKET_REQUIRED", "A WebSocket upgrade is required.");
    }

    let claims;
    try {
      claims = await tickets.verifyProtocols(request.headers.get("Sec-WebSocket-Protocol"));
    } catch (error) {
      if (error instanceof StreamTicketError && error.code === "misconfigured") {
        throw new RequestError(503, "STREAM_UNAVAILABLE", "Live streaming is not configured.");
      }
      throw new RequestError(401, "STREAM_TICKET_REFUSED", "The live-stream ticket was refused.");
    }

    const headers = new Headers(request.headers);
    headers.delete("Authorization");
    headers.delete("Cookie");
    headers.delete("CF-Access-Client-Id");
    headers.delete("CF-Access-Client-Secret");
    headers.set("CF-Access-Client-Id", config.accessClientId);
    headers.set("CF-Access-Client-Secret", config.accessClientSecret);
    headers.set("Sec-WebSocket-Protocol", STREAM_PROTOCOL);
    headers.set("X-Request-ID", claims.id);
    headers.set("X-Dictation-Mode", claims.mode);
    headers.set("X-Dictation-Client", claims.client);
    headers.set("X-Allow-Cloud-Fallback", String(claims.fallback));
    headers.set("X-Dictation-Transport", "stream-v1");

    const target = new URL("/v1/stream", origin);
    const originRequest = new Request(target, request);
    const response = await fetcher(new Request(originRequest, { headers }));
    return { requestId: claims.id, response };
  };
}

function macTranscriptionTimeoutMs(durationSeconds: number): number {
  return Math.min(
    MAC_TRANSCRIBE_MAXIMUM_TIMEOUT_MS,
    Math.max(MAC_TRANSCRIBE_MINIMUM_TIMEOUT_MS, Math.ceil(durationSeconds * 1_250 + 15_000)),
  );
}

function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  const chunkSize = 32_768;
  let binary = "";

  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

export function createWorkersAiTranscriber(run: WorkersAiRunner) {
  return async (input: AudioInput): Promise<Transcript> => {
    const result = await run(CLOUD_MODEL, {
      audio: arrayBufferToBase64(input.bytes),
      task: "transcribe",
      language: input.language,
      vad_filter: true,
      condition_on_previous_text: true,
    });

    if (
      !isRecord(result) ||
      typeof result.text !== "string" ||
      result.text.trim() === "" ||
      result.text.length > MAX_TRANSCRIPT_CHARACTERS
    ) {
      throw new RequestError(
        503,
        "CLOUD_FALLBACK_INVALID_RESPONSE",
        "Cloud fallback returned an unusable transcription.",
      );
    }
    return {
      text: result.text,
      route: "cloud_fallback",
      cleanup: "none",
      latencyMs: 0,
      fallbackReason: null,
      historyState: "pending_device_sync",
    };
  };
}

function publicFallbackReason(reason: MacFallbackReason): FallbackReason {
  switch (reason) {
    case "not_configured":
    case "health_unreachable":
    case "origin_unreachable":
      return "mac_offline";
    case "health_busy":
    case "origin_busy":
      return "mac_busy";
    case "health_timeout":
    case "origin_timeout":
      return "mac_timeout";
    case "health_rejected":
    case "health_not_ready":
      return "mac_unready";
    case "origin_preempted":
      return "remote_preempted";
    case "origin_rejected":
    case "origin_invalid_response":
      return "local_asr_failed";
    case "origin_invalid_request":
    case "health_authentication_failed":
    case "origin_authentication_failed":
      return "mac_unready";
  }
}

export function defaultRuntime(env: Env): GatewayRuntime {
  // A missing binding must degrade to "Mac not configured" (cloud fallback or
  // MAC_UNAVAILABLE), never to a 500 that also takes the public PWA shell down.
  const originConfig: MacOriginConfig = {
    originUrl: typeof env.MAC_ORIGIN_URL === "string" ? env.MAC_ORIGIN_URL : "",
    accessClientId: typeof env.MAC_ACCESS_CLIENT_ID === "string" ? env.MAC_ACCESS_CLIENT_ID : "",
    accessClientSecret: typeof env.MAC_ACCESS_CLIENT_SECRET === "string" ? env.MAC_ACCESS_CLIENT_SECRET : "",
  };
  const tickets = createStreamTicketAuthority(
    typeof env.STREAM_TICKET_SECRET === "string" ? env.STREAM_TICKET_SECRET : "",
  );

  return {
    now: () => Date.now(),
    requestId: () => crypto.randomUUID(),
    log: (level, event) => {
      const serialized = JSON.stringify(event);
      if (level === "error") console.error(serialized);
      else if (level === "warn") console.warn(serialized);
      else console.log(serialized);
    },
    transcribeOnMac: createMacTranscriber(originConfig, (request) => fetch(request)),
    transcribeInCloud: createWorkersAiTranscriber((model, input) => env.AI.run(model, input)),
    proxyHistory: createHistoryProxy(originConfig, (request) => fetch(request)),
    issueStreamTicket: (input) => tickets.issue(input),
    proxyStream: createMacStreamProxy(originConfig, tickets, (request) => fetch(request)),
    fetchAsset: (request) => env.ASSETS.fetch(request),
  };
}

function healthResponse(requestId: string): Response {
  return jsonResponse(
    {
      status: "ok",
      service: "local-dictation-iphone-gateway",
      storage: "none",
    },
    200,
    requestId,
  );
}

function logCompletion(
  runtime: GatewayRuntime,
  startedAt: number,
  event: SafeLogEvent,
  level: SafeLogLevel = "info",
  requestId?: string,
): void {
  runtime.log(level, {
    event: typeof event.event === "string" ? event.event : SAFE_LOG_EVENTS.completed,
    ...(requestId === undefined ? {} : { request_id: requestId }),
    latency_ms: Math.max(0, runtime.now() - startedAt),
    ...event,
  });
}

function logPhase(
  runtime: GatewayRuntime,
  level: SafeLogLevel,
  requestId: string,
  event: string,
  fields: SafeLogEvent = {},
): void {
  runtime.log(level, {
    event,
    request_id: requestId,
    ...fields,
  });
}

function sizeBucket(bytes: number): string {
  if (bytes <= 256 * 1024) return "tiny";
  if (bytes <= 1024 * 1024) return "small";
  if (bytes <= 4 * 1024 * 1024) return "medium";
  if (bytes <= MAX_AUDIO_BYTES) return "large";
  return "oversized";
}

function historyPageSearch(url: URL): string {
  const invalid = (): never => {
    throw new RequestError(400, "INVALID_REQUEST", "The history query parameters are invalid.");
  };

  const revisionRaw = url.searchParams.get("revision");
  if (revisionRaw === null || !DIGITS_PATTERN.test(revisionRaw)) invalid();
  const revision = Number(revisionRaw);
  if (!Number.isSafeInteger(revision) || revision < 0) invalid();

  const search = new URLSearchParams();
  search.set("revision", String(revision));

  const limitRaw = url.searchParams.get("limit");
  if (limitRaw !== null) {
    if (!DIGITS_PATTERN.test(limitRaw)) invalid();
    const limit = Number(limitRaw);
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_HISTORY_OPERATIONS) invalid();
    search.set("limit", String(limit));
  }

  const cursor = url.searchParams.get("cursor");
  if (cursor !== null) {
    if (cursor.length === 0 || cursor.length > MAX_HISTORY_CURSOR_CHARACTERS || !CURSOR_PATTERN.test(cursor)) {
      invalid();
    }
    search.set("cursor", cursor);
  }

  return `?${search.toString()}`;
}

function validateHistoryOperations(body: string): void {
  const invalid = (): never => {
    throw new RequestError(400, "INVALID_REQUEST", "The history operations body is malformed.");
  };

  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    invalid();
  }

  if (!isRecord(parsed)) invalid();
  const operations = (parsed as Record<string, unknown>).operations;
  if (!Array.isArray(operations)) invalid();

  const list = operations as readonly unknown[];
  if (list.length < 1) invalid();
  if (list.length > MAX_HISTORY_OPERATIONS) {
    throw new RequestError(
      413,
      "PAYLOAD_TOO_LARGE",
      "Send at most 100 history operations per request.",
    );
  }

  for (const operation of list) {
    if (!isRecord(operation)) invalid();
    const record = operation as Record<string, unknown>;
    if (typeof record.op_id !== "string" || record.op_id === "") invalid();
    if (typeof record.type !== "string" || !HISTORY_OPERATION_TYPES.has(record.type)) invalid();
    if (typeof record.entry_id !== "string" || record.entry_id === "") invalid();

    const text = record.text;
    if (text !== undefined && text !== null) {
      if (typeof text !== "string") invalid();
      if ((text as string).length > MAX_TRANSCRIPT_CHARACTERS) {
        throw new RequestError(
          413,
          "PAYLOAD_TOO_LARGE",
          "Each history operation text must be 100000 characters or fewer.",
        );
      }
    }
  }
}

async function readOperationsBody(request: Request): Promise<ArrayBuffer> {
  const declared = request.headers.get("Content-Length");
  if (declared !== null && DIGITS_PATTERN.test(declared) && Number(declared) > MAX_HISTORY_OPERATIONS_BYTES) {
    throw new RequestError(413, "PAYLOAD_TOO_LARGE", "The history operations body must be 2 MiB or smaller.");
  }

  const bytes = await readBoundedBytes(request.body, MAX_HISTORY_OPERATIONS_BYTES);
  if (bytes === undefined) {
    throw new RequestError(413, "PAYLOAD_TOO_LARGE", "The history operations body must be 2 MiB or smaller.");
  }
  if (bytes.byteLength === 0) {
    throw new RequestError(400, "INVALID_REQUEST", "The history operations body is malformed.");
  }
  return bytes.buffer as ArrayBuffer;
}

function historyFailure(result: Extract<HistoryProxyResult, { ok: false }>): RequestError {
  switch (result.reason) {
    case "disabled":
      return new RequestError(403, "HISTORY_DISABLED", "Unified history is disabled on the Mac.");
    case "changed":
      return new RequestError(409, "HISTORY_CHANGED", "The Mac history revision changed.");
    case "invalid_request":
      return new RequestError(400, "INVALID_REQUEST", "The Mac rejected the history request.");
    case "payload_too_large":
      return new RequestError(413, "PAYLOAD_TOO_LARGE", "The history request body is too large.");
    case "auth_failed":
      return new RequestError(503, "ORIGIN_AUTH_FAILED", "The protected Mac origin is misconfigured.");
    case "unavailable":
      return new RequestError(503, "MAC_UNAVAILABLE", "The Mac is unavailable. Please try again.");
  }
}

function historyLogRoute(kind: HistoryRequestKind): string {
  return `history_${kind}`;
}

async function handleHistory(
  request: Request,
  url: URL,
  kind: HistoryRequestKind,
  runtime: GatewayRuntime,
  requestId: string,
  startedAt: number,
): Promise<Response> {
  const route = historyLogRoute(kind);
  const expectedMethod = kind === "operations" ? "POST" : "GET";
  let sizeBucketValue = "none";

  if (request.method !== expectedMethod) {
    const error = new RequestError(
      405,
      "METHOD_NOT_ALLOWED",
      `Only ${expectedMethod} is allowed for this endpoint.`,
    );
    logCompletion(runtime, startedAt, {
      event: SAFE_LOG_EVENTS.failed,
      route,
      status: 405,
      size_bucket: "none",
      failure_code: error.code,
    }, "warn", requestId);
    return errorResponse(error, requestId);
  }

  try {
    const client = requirePwaClient(request);
    let search = "";
    let body: ArrayBuffer | null = null;

    if (kind === "page") {
      search = historyPageSearch(url);
    } else if (kind === "operations") {
      body = await readOperationsBody(request);
      sizeBucketValue = sizeBucket(body.byteLength);
      validateHistoryOperations(new TextDecoder().decode(body));
    }

    const result = await runtime.proxyHistory({ kind, client, requestId, search, body });

    if (!result.ok) {
      const error = historyFailure(result);
      logCompletion(
        runtime,
        startedAt,
        {
          event: SAFE_LOG_EVENTS.failed,
          route,
          status: error.status,
          size_bucket: sizeBucketValue,
          failure_code: error.code,
        },
        error.status >= 500 ? "error" : "warn",
        requestId,
      );
      return errorResponse(
        error,
        requestId,
        result.revision === null ? undefined : { revision: result.revision },
      );
    }

    logCompletion(runtime, startedAt, {
      route,
      status: result.status,
      size_bucket: sizeBucketValue,
    }, "info", requestId);
    return new Response(result.body, {
      status: result.status,
      headers: {
        ...NO_STORE_HEADERS,
        "X-Request-ID": requestId,
      },
    });
  } catch (error) {
    const publicError =
      error instanceof RequestError
        ? error
        : new RequestError(503, "MAC_UNAVAILABLE", "The Mac is unavailable. Please try again.");
    logCompletion(
      runtime,
      startedAt,
      {
        event: SAFE_LOG_EVENTS.failed,
        route,
        status: publicError.status,
        size_bucket: sizeBucketValue,
        failure_code: publicError.code,
      },
      publicError.status >= 500 ? "error" : "warn",
      requestId,
    );
    return errorResponse(publicError, requestId);
  }
}

function assetPathFor(pathname: string): string {
  if (
    pathname === APP_ROOT_PATH ||
    pathname === APP_PREFIX ||
    pathname === APP_IMPORT_PATH ||
    pathname === `${APP_IMPORT_PATH}/`
  ) {
    return APP_SHELL_PATH;
  }
  return pathname;
}

function assetCacheControl(assetPath: string): string {
  if (assetPath.endsWith(".html")) return REVALIDATED_CACHE_CONTROL;
  const name = assetPath.slice(assetPath.lastIndexOf("/") + 1);
  return HASHED_ASSET_PATTERN.test(name) ? IMMUTABLE_CACHE_CONTROL : REVALIDATED_CACHE_CONTROL;
}

async function handleAsset(
  request: Request,
  url: URL,
  runtime: GatewayRuntime,
  requestId: string,
  startedAt: number,
): Promise<Response> {
  const assetPath = assetPathFor(url.pathname);
  const assetRequest = new Request(new URL(assetPath, url.origin), {
    method: request.method,
    headers: new Headers({ "Accept": request.headers.get("Accept") ?? "*/*" }),
  });

  let assetResponse: Response;
  try {
    assetResponse = await runtime.fetchAsset(assetRequest);
  } catch {
    const error = new RequestError(503, "APP_UNAVAILABLE", "The app shell is temporarily unavailable.");
    logCompletion(runtime, startedAt, {
      event: SAFE_LOG_EVENTS.failed,
      route: "app",
      status: 503,
      size_bucket: "none",
      failure_code: error.code,
    }, "error", requestId);
    return errorResponse(error, requestId);
  }

  const headers = new Headers(assetResponse.headers);
  for (const [name, value] of Object.entries(ASSET_SECURITY_HEADERS)) {
    headers.set(name, value);
  }
  headers.set("Cache-Control", assetCacheControl(assetPath));
  headers.set("X-Request-ID", requestId);

  logCompletion(runtime, startedAt, {
    route: "app",
    status: assetResponse.status,
    size_bucket: "none",
  }, "info", requestId);

  return new Response(request.method === "HEAD" ? null : assetResponse.body, {
    status: assetResponse.status,
    statusText: assetResponse.statusText,
    headers,
  });
}

async function handleTranscription(
  request: Request,
  runtime: GatewayRuntime,
  requestId: string,
  startedAt: number,
): Promise<Response> {
  logPhase(runtime, "info", requestId, SAFE_LOG_EVENTS.started, {
    route: "transcription",
    size_bucket: sizeBucket(Number(request.headers.get("Content-Length")) || 0),
  });

  if (request.method !== "POST") {
    const error = new RequestError(405, "METHOD_NOT_ALLOWED", "Only POST is allowed for this endpoint.");
    logCompletion(
      runtime,
      startedAt,
      {
        event: SAFE_LOG_EVENTS.failed,
        route: "transcription",
        status: 405,
        size_bucket: "none",
        failure_code: error.code,
      },
      "warn",
      requestId,
    );
    return errorResponse(error, requestId);
  }

  try {
    const suppliedRequestId = parseRequestId(request);
    const requestContentType = contentType(request);
    if (!AUDIO_CONTENT_TYPES.has(requestContentType)) {
      throw new RequestError(415, "UNSUPPORTED_AUDIO_TYPE", "Send a supported audio file as the request body.");
    }
    const contentEncoding = request.headers.get("Content-Encoding")?.trim().toLowerCase();
    if (contentEncoding !== undefined && contentEncoding !== "identity") {
      throw new RequestError(415, "UNSUPPORTED_CONTENT_ENCODING", "Send uncompressed HTTP request bytes.");
    }

    parseContentLength(request);
    const durationSeconds = parseDuration(request);
    const mode = parseMode(request);
    const client = parseDictationClient(request);
    const allowsCloudFallback = parseCloudFallback(request);
    const language = parseLanguage(request);
    const bytes = await readStreamWithLimit(request.body, MAX_AUDIO_BYTES);
    const input: AudioInput = {
      bytes,
      allowsCloudFallback,
      client,
      contentType: requestContentType,
      durationSeconds,
      language,
      mode,
      requestId: suppliedRequestId,
    };

    const diagnosticContext: SafeLogEvent = {
      client,
      mode,
      media_type: requestContentType,
      duration_bucket: durationBucket(durationSeconds),
      size_bucket: sizeBucket(bytes.byteLength),
      cloud_fallback_allowed: allowsCloudFallback,
    };
    logPhase(
      runtime,
      "info",
      suppliedRequestId,
      SAFE_LOG_EVENTS.inputValidated,
      diagnosticContext,
    );

    const mac = await runtime.transcribeOnMac(input);
    let transcript: Transcript;
    let route: TranscriptionRoute;

    if (mac.ok) {
      transcript = mac.transcript;
      route = "mac_local";
      logPhase(runtime, "info", suppliedRequestId, SAFE_LOG_EVENTS.macSucceeded, {
        ...diagnosticContext,
        route,
        cleanup: transcript.cleanup,
        history_state: transcript.historyState,
      });
    } else {
      logPhase(runtime, "warn", suppliedRequestId, SAFE_LOG_EVENTS.macUnavailable, {
        ...diagnosticContext,
        route: "mac_local",
        fallback_reason: mac.reason,
      });
      if (mac.reason === "origin_invalid_request") {
        throw new RequestError(422, "INVALID_AUDIO", "The Mac rejected the audio as malformed.");
      }
      if (
        mac.reason === "health_authentication_failed" ||
        mac.reason === "origin_authentication_failed"
      ) {
        throw new RequestError(503, "ORIGIN_AUTH_FAILED", "The protected Mac origin is misconfigured.");
      }
      if (!allowsCloudFallback) {
        throw new RequestError(
          503,
          "MAC_UNAVAILABLE",
          "The Mac is unavailable and cloud fallback is disabled.",
        );
      }
      logPhase(runtime, "info", suppliedRequestId, SAFE_LOG_EVENTS.cloudStarted, {
        ...diagnosticContext,
        route: "cloud_fallback",
        fallback_reason: mac.reason,
      });
      try {
        transcript = await runtime.transcribeInCloud(input);
      } catch (error) {
        const failureCode = error instanceof RequestError
          ? error.code
          : "CLOUD_FALLBACK_FAILED";
        logPhase(runtime, "error", suppliedRequestId, SAFE_LOG_EVENTS.cloudFailed, {
          ...diagnosticContext,
          route: "cloud_fallback",
          fallback_reason: mac.reason,
          failure_code: failureCode,
        });
        throw error instanceof RequestError
          ? error
          : new RequestError(
              503,
              "CLOUD_FALLBACK_FAILED",
              "Cloud fallback is temporarily unavailable. Please try again.",
            );
      }
      route = "cloud_fallback";
      transcript = {
        ...transcript,
        route,
        cleanup: "none",
        latencyMs: Math.max(0, runtime.now() - startedAt),
        fallbackReason: publicFallbackReason(mac.reason),
        historyState: "pending_device_sync",
      };
      logPhase(runtime, "info", suppliedRequestId, SAFE_LOG_EVENTS.cloudSucceeded, {
        ...diagnosticContext,
        route,
        fallback_reason: transcript.fallbackReason ?? "none",
        cleanup: transcript.cleanup,
        history_state: transcript.historyState,
      });
    }

    logCompletion(runtime, startedAt, {
      event: SAFE_LOG_EVENTS.completed,
      status: 200,
      route,
      size_bucket: sizeBucket(bytes.byteLength),
      duration_bucket: durationBucket(durationSeconds),
      client,
      mode,
      cleanup: transcript.cleanup,
      history_state: transcript.historyState,
      fallback_reason: transcript.fallbackReason ?? "none",
    }, "info", suppliedRequestId);

    return jsonResponse(
      {
        request_id: suppliedRequestId,
        text: transcript.text,
        route: transcript.route,
        cleanup: transcript.cleanup,
        latency_ms: transcript.latencyMs,
        fallback_reason: transcript.fallbackReason,
        history_state: transcript.historyState,
      },
      200,
      suppliedRequestId,
    );
  } catch (error) {
    const publicError =
      error instanceof RequestError
        ? error
        : new RequestError(
            503,
            "TRANSCRIPTION_UNAVAILABLE",
            "Transcription is temporarily unavailable. Please try again.",
          );
    logCompletion(
      runtime,
      startedAt,
      {
        event: SAFE_LOG_EVENTS.failed,
        route: "transcription",
        status: publicError.status,
        size_bucket: sizeBucket(Number(request.headers.get("Content-Length")) || 0),
        failure_code: publicError.code,
      },
      publicError.status >= 500 ? "error" : "warn",
      requestId,
    );
    return errorResponse(publicError, requestId);
  }
}

async function handleStreamTicket(
  request: Request,
  runtime: GatewayRuntime,
  requestId: string,
  startedAt: number,
): Promise<Response> {
  try {
    if (request.method !== "POST") {
      throw new RequestError(405, "METHOD_NOT_ALLOWED", "Only POST is allowed for this endpoint.");
    }
    requirePwaClient(request);
    const suppliedRequestId = parseRequestId(request);
    const mode = parseMode(request);
    const allowsCloudFallback = parseCloudFallback(request);
    const grant = await runtime.issueStreamTicket({
      requestId: suppliedRequestId,
      mode,
      allowsCloudFallback,
    });
    logCompletion(runtime, startedAt, {
      event: "stream_ticket_issued",
      route: "stream_ticket",
      status: 200,
      client: "pwa",
      mode,
      cloud_fallback_allowed: allowsCloudFallback,
      size_bucket: "none",
    }, "info", suppliedRequestId);
    return jsonResponse({
      request_id: grant.requestId,
      protocol: grant.protocol,
      ticket: grant.ticket,
      stream_path: grant.streamPath,
      expires_at: grant.expiresAt,
    }, 200, suppliedRequestId);
  } catch (error) {
    const publicError = error instanceof RequestError
      ? error
      : new RequestError(503, "STREAM_UNAVAILABLE", "Live streaming is temporarily unavailable.");
    logCompletion(runtime, startedAt, {
      event: SAFE_LOG_EVENTS.failed,
      route: "stream_ticket",
      status: publicError.status,
      size_bucket: "none",
      failure_code: publicError.code,
    }, publicError.status >= 500 ? "error" : "warn", requestId);
    return errorResponse(publicError, requestId);
  }
}

async function handleStream(
  request: Request,
  runtime: GatewayRuntime,
  requestId: string,
  startedAt: number,
): Promise<Response> {
  try {
    if (request.method !== "GET") {
      throw new RequestError(405, "METHOD_NOT_ALLOWED", "Only GET is allowed for this endpoint.");
    }
    const result = await runtime.proxyStream(request);
    logCompletion(runtime, startedAt, {
      event: "stream_upgrade_forwarded",
      route: "stream",
      status: result.response.status,
      client: "pwa",
      size_bucket: "none",
    }, "info", result.requestId);
    return result.response;
  } catch (error) {
    const publicError = error instanceof RequestError
      ? error
      : new RequestError(503, "STREAM_UNAVAILABLE", "Live streaming is temporarily unavailable.");
    logCompletion(runtime, startedAt, {
      event: SAFE_LOG_EVENTS.failed,
      route: "stream",
      status: publicError.status,
      size_bucket: "none",
      failure_code: publicError.code,
    }, publicError.status >= 500 ? "error" : "warn", requestId);
    return errorResponse(publicError, requestId);
  }
}

export async function handleRequest(request: Request, runtime: GatewayRuntime): Promise<Response> {
  const startedAt = runtime.now();
  const requestIdHeader = request.headers.get("X-Request-ID")?.trim();
  const requestId = requestIdHeader !== undefined && UUID_PATTERN.test(requestIdHeader)
    ? requestIdHeader.toLowerCase()
    : runtime.requestId();
  const url = new URL(request.url);

  if (url.pathname === STREAM_PATH) {
    return handleStream(request, runtime, requestId, startedAt);
  }

  if (url.pathname === STREAM_TICKET_PATH) {
    return handleStreamTicket(request, runtime, requestId, startedAt);
  }

  if (url.pathname === GATEWAY_HEALTH_PATH) {
    if (request.method !== "GET") {
      const error = new RequestError(405, "METHOD_NOT_ALLOWED", "Only GET is allowed for this endpoint.");
      logCompletion(runtime, startedAt, {
        event: SAFE_LOG_EVENTS.failed,
        route: "health",
        status: 405,
        size_bucket: "none",
        failure_code: error.code,
      }, "warn", requestId);
      return errorResponse(error, requestId);
    }
    logCompletion(runtime, startedAt, {
      route: "health",
      status: 200,
      size_bucket: "none",
    }, "info", requestId);
    return healthResponse(requestId);
  }

  if (url.pathname === TRANSCRIBE_PATH) {
    return handleTranscription(request, runtime, requestId, startedAt);
  }

  if (url.pathname === HISTORY_MANIFEST_PATH) {
    return handleHistory(request, url, "manifest", runtime, requestId, startedAt);
  }
  if (url.pathname === HISTORY_PAGE_PATH) {
    return handleHistory(request, url, "page", runtime, requestId, startedAt);
  }
  if (url.pathname === HISTORY_OPERATIONS_PATH) {
    return handleHistory(request, url, "operations", runtime, requestId, startedAt);
  }

  // Static assets are never reachable under /v1; every /v1 path is handled above.
  if (!url.pathname.startsWith("/v1/") && url.pathname !== "/v1") {
    if (url.pathname === "/") {
      if (request.method !== "GET" && request.method !== "HEAD") {
        const error = new RequestError(405, "METHOD_NOT_ALLOWED", "Only GET is allowed for this endpoint.");
        logCompletion(runtime, startedAt, {
          event: SAFE_LOG_EVENTS.failed,
          route: "root",
          status: 405,
          size_bucket: "none",
          failure_code: error.code,
        }, "warn", requestId);
        return errorResponse(error, requestId);
      }
      logCompletion(runtime, startedAt, {
        route: "root",
        status: 302,
        size_bucket: "none",
      }, "info", requestId);
      return new Response(null, {
        status: 302,
        headers: {
          "Location": APP_PREFIX,
          "Cache-Control": REVALIDATED_CACHE_CONTROL,
          "Referrer-Policy": "no-referrer",
          "X-Request-ID": requestId,
        },
      });
    }

    if (url.pathname === APP_ROOT_PATH || url.pathname.startsWith(APP_PREFIX)) {
      if (request.method !== "GET" && request.method !== "HEAD") {
        const error = new RequestError(405, "METHOD_NOT_ALLOWED", "Only GET is allowed for this endpoint.");
        logCompletion(runtime, startedAt, {
          event: SAFE_LOG_EVENTS.failed,
          route: "app",
          status: 405,
          size_bucket: "none",
          failure_code: error.code,
        }, "warn", requestId);
        return errorResponse(error, requestId);
      }
      return handleAsset(request, url, runtime, requestId, startedAt);
    }
  }

  const error = new RequestError(404, "NOT_FOUND", "Endpoint not found.");
  logCompletion(runtime, startedAt, {
    event: SAFE_LOG_EVENTS.failed,
    route: "unknown",
    status: 404,
    size_bucket: "none",
    failure_code: error.code,
  }, "warn", requestId);
  return errorResponse(error, requestId);
}
