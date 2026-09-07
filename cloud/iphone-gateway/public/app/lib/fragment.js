// Parser for the `/app/import` fragment produced by the Shortcut bridge.
// Never throws: every malformed input becomes a typed failure result.

import { normalizeUuid } from "./uuid.js";

/** Longest transcript the Shortcut inlines; longer ones use clipboard mode. */
export const MAX_FRAGMENT_TEXT_CHARACTERS = 16_000;

/** Defensive ceiling on the raw fragment before any decoding work happens. */
const MAX_FRAGMENT_LENGTH = 200_000;

const MODES = new Set(["clean", "literal"]);
const ROUTES = new Set(["mac_local", "cloud_fallback"]);
const CLIENT_SOURCE_KINDS = {
  shortcut: "iphone_shortcut",
  pwa: "iphone_pwa",
};

const ISO_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;

function failure(reason) {
  return { ok: false, reason };
}

/**
 * Decode a fragment into a flat parameter map without URLSearchParams, whose
 * `+`-as-space rule would corrupt timezone offsets and transcript text.
 */
function decodeFragment(hash) {
  const trimmed = hash.startsWith("#") ? hash.slice(1) : hash;
  const params = new Map();
  for (const pair of trimmed.split("&")) {
    if (pair === "") continue;
    const separator = pair.indexOf("=");
    if (separator <= 0) return null;
    try {
      const key = decodeURIComponent(pair.slice(0, separator));
      const value = decodeURIComponent(pair.slice(separator + 1));
      if (!params.has(key)) params.set(key, value);
    } catch {
      return null;
    }
  }
  return params;
}

function normalizeTimestamp(value) {
  if (typeof value !== "string" || !ISO_PATTERN.test(value)) return null;
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) return null;
  return new Date(ms).toISOString();
}

/**
 * Parse and validate an `/app/import` fragment.
 *
 * @param {string} hash raw `location.hash` (with or without the leading `#`)
 * @returns {{ ok: true, kind: "text", meta: object, text: string }
 *   | { ok: true, kind: "clipboard", meta: object }
 *   | { ok: false, reason: string }}
 */
export function parseImportFragment(hash) {
  if (typeof hash !== "string") return failure("malformed");
  if (hash === "" || hash === "#") return failure("empty");
  if (hash.length > MAX_FRAGMENT_LENGTH) return failure("text_too_long");

  const params = decodeFragment(hash);
  if (params === null) return failure("malformed");
  if (params.size === 0) return failure("empty");

  if (params.get("v") !== "1") return failure("unsupported_version");

  const id = normalizeUuid(params.get("id"));
  if (id === null) return failure("invalid_id");

  const createdAt = normalizeTimestamp(params.get("ts"));
  if (createdAt === null) return failure("invalid_timestamp");

  const mode = params.get("mode");
  if (!MODES.has(mode)) return failure("invalid_mode");

  const route = params.get("route");
  if (!ROUTES.has(route)) return failure("invalid_route");

  const client = params.get("client");
  const sourceKind = typeof client === "string" ? CLIENT_SOURCE_KINDS[client] : undefined;
  if (sourceKind === undefined) return failure("invalid_client");

  const meta = { id, created_at: createdAt, mode, route, source_kind: sourceKind };

  if (params.get("clipboard") === "1") {
    return { ok: true, kind: "clipboard", meta };
  }

  const text = params.get("text");
  if (typeof text !== "string" || text.trim() === "") return failure("missing_text");
  if (text.length > MAX_FRAGMENT_TEXT_CHARACTERS) return failure("text_too_long");

  return { ok: true, kind: "text", meta, text };
}

/**
 * Build the local pending entry for a validated import. Used for both inline
 * and clipboard imports; `text` for clipboard mode arrives on tap.
 */
export function entryFromImport(meta, text) {
  const body = typeof text === "string" ? text : "";
  return {
    id: meta.id,
    created_at: meta.created_at,
    updated_at: meta.created_at,
    source_kind: meta.source_kind,
    mode: meta.mode,
    raw_text: body,
    polished_text: null,
    user_edited_text: null,
    display_text: body,
    destination_display_name: null,
    remote_route: meta.route,
    cleanup_backend: null,
    is_pinned: false,
    entry_revision: 0,
    local_state: "awaiting_import",
  };
}

/** Non-technical message for a rejected fragment. */
export function importErrorMessage(reason) {
  switch (reason) {
    case "text_too_long":
      return "That transcript was too long to import from the link.";
    case "empty":
      return "That import link was empty.";
    default:
      return "That import link could not be read. Try dictating again.";
  }
}
