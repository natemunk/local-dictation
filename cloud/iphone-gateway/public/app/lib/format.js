// Presentation helpers. Pure functions only: no DOM, no storage, no network.

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

const SOURCE_LABELS = {
  desktop: "Desktop",
  iphone_shortcut: "Shortcut",
  iphone_pwa: "PWA",
};

const ROUTE_LABELS = {
  mac_local: "Mac",
  cloud_fallback: "Cloud",
};

/** Plain-language device name shown on a history row. */
const DEVICE_LABELS = {
  desktop: "Mac",
  iphone_shortcut: "iPhone",
  iphone_pwa: "iPhone",
};

const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

function startOfDay(ms) {
  const date = new Date(ms);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/** "iPhone" or "Mac" for a `source_kind`; empty string when it is unknown. */
export function deviceLabel(sourceKind) {
  if (typeof sourceKind !== "string") return "";
  return DEVICE_LABELS[sourceKind] ?? "";
}

/** Human source label for an entry's `source_kind`. */
export function sourceLabel(sourceKind) {
  if (typeof sourceKind !== "string") return "Unknown";
  return SOURCE_LABELS[sourceKind] ?? "Unknown";
}

/** Short badge text for a `remote_route`, or null when the entry has no route. */
export function routeLabel(route) {
  if (typeof route !== "string") return null;
  return ROUTE_LABELS[route] ?? null;
}

/** Parse an ISO timestamp, returning null instead of NaN for junk. */
export function parseTimestamp(value) {
  if (typeof value !== "string" || value === "") return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

/**
 * Coarse relative time ("just now", "4m ago", "3h ago", "2d ago", "Mar 4").
 * `now` is injected so the behaviour is testable.
 */
export function formatRelativeTime(value, now = Date.now()) {
  const ms = parseTimestamp(value);
  if (ms === null) return "";

  const delta = now - ms;
  if (delta < 0) return "just now";
  if (delta < MINUTE_MS) return "just now";
  if (delta < HOUR_MS) return `${Math.floor(delta / MINUTE_MS)}m ago`;
  if (delta < DAY_MS) return `${Math.floor(delta / HOUR_MS)}h ago`;
  if (delta < 7 * DAY_MS) return `${Math.floor(delta / DAY_MS)}d ago`;

  const date = new Date(ms);
  return `${MONTHS[date.getMonth()]} ${date.getDate()}`;
}

/**
 * Conversational timestamp for a history row: "Just now", "2 min ago",
 * "3 hours ago", "Yesterday", "4 days ago", "Mar 4". `now` is injected so the
 * behaviour is testable.
 */
export function friendlyTime(value, now = Date.now()) {
  const ms = parseTimestamp(value);
  if (ms === null) return "";

  const delta = now - ms;
  if (delta < MINUTE_MS) return "Just now";
  if (delta < HOUR_MS) return `${Math.max(1, Math.floor(delta / MINUTE_MS))} min ago`;

  const today = startOfDay(now);
  if (ms >= today) {
    const hours = Math.max(1, Math.floor(delta / HOUR_MS));
    return `${hours} ${hours === 1 ? "hour" : "hours"} ago`;
  }

  const days = Math.round((today - startOfDay(ms)) / DAY_MS);
  if (days <= 1) return "Yesterday";
  if (days < 7) return `${days} days ago`;

  const date = new Date(ms);
  return `${MONTHS[date.getMonth()]} ${date.getDate()}`;
}

/** mm:ss elapsed clock for the recorder. */
export function formatElapsed(milliseconds) {
  const total = Number.isFinite(milliseconds) && milliseconds > 0
    ? Math.floor(milliseconds / 1000)
    : 0;
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

/** Single-line preview of an entry body, clipped with an ellipsis. */
export function previewText(value, limit = 140) {
  if (typeof value !== "string") return "";
  const collapsed = value.replace(/\s+/g, " ").trim();
  if (collapsed.length <= limit) return collapsed;
  return `${collapsed.slice(0, limit - 1)}…`;
}

/** Redacted rendering of a stored secret: only the last four characters survive. */
export function redactSecret(secret) {
  if (typeof secret !== "string" || secret === "") return "";
  const tail = secret.slice(-4);
  return `••••${tail}`;
}

/** Display text resolution: user edit -> polished -> raw. */
export function displayTextOf(entry) {
  if (entry === null || typeof entry !== "object") return "";
  const edited = entry.user_edited_text;
  if (typeof edited === "string" && edited.trim() !== "") return edited;
  const polished = entry.polished_text;
  if (typeof polished === "string" && polished.trim() !== "") return polished;
  const raw = entry.raw_text;
  if (typeof raw === "string") return raw;
  return typeof entry.display_text === "string" ? entry.display_text : "";
}

/** Pluralising counter used by the status chips. */
export function countLabel(count, singular, plural = `${singular}s`) {
  const safe = Number.isFinite(count) ? Math.max(0, Math.floor(count)) : 0;
  return `${safe} ${safe === 1 ? singular : plural}`;
}
