// Case-insensitive substring search across the local history cache.
// Pure functions: the caller supplies the entry array.

import {
  deviceLabel,
  displayTextOf,
  parseTimestamp,
  routeLabel,
  sourceLabel,
} from "./format.js";

/** Normalise a raw query string; an empty/blank query means "no filter". */
export function normalizeQuery(query) {
  return typeof query === "string" ? query.trim().toLowerCase() : "";
}

/**
 * All searchable text for one entry: display, raw, polished and edited text
 * plus the human source and route labels.
 */
export function entrySearchText(entry) {
  if (entry === null || typeof entry !== "object") return "";
  const parts = [
    displayTextOf(entry),
    entry.raw_text,
    entry.polished_text,
    entry.user_edited_text,
    entry.display_text,
    entry.destination_display_name,
    sourceLabel(entry.source_kind),
    deviceLabel(entry.source_kind),
    routeLabel(entry.remote_route),
  ];
  return parts
    .filter((part) => typeof part === "string" && part !== "")
    .join("\n")
    .toLowerCase();
}

/** True when the entry matches an already-normalised query. */
export function matchesQuery(entry, normalized) {
  if (normalized === "") return true;
  return entrySearchText(entry).includes(normalized);
}

/** Newest first by `created_at`, with the entry id as a stable tiebreaker. */
export function sortNewestFirst(entries) {
  return [...entries].sort((a, b) => {
    const left = parseTimestamp(a?.created_at) ?? 0;
    const right = parseTimestamp(b?.created_at) ?? 0;
    if (left !== right) return right - left;
    return String(b?.id ?? "").localeCompare(String(a?.id ?? ""));
  });
}

/** Filter + rank. Ranking is simply newest first, as specified. */
export function searchEntries(entries, query) {
  const normalized = normalizeQuery(query);
  const list = Array.isArray(entries) ? entries : [];
  return sortNewestFirst(list.filter((entry) => matchesQuery(entry, normalized)));
}
