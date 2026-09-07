// UUID helpers shared by the fragment parser, the operation queue and the API
// client. `crypto.randomUUID` is available on every browser that can run this
// app and in the Node test environment.

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** True for a canonical (lowercase or uppercase) RFC 4122 v1-v5 UUID. */
export function isUuid(value) {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

/** Lowercase a validated UUID, or return null when it is not one. */
export function normalizeUuid(value) {
  return isUuid(value) ? value.toLowerCase() : null;
}

/** Fresh lowercase v4 UUID. */
export function randomUuid() {
  return globalThis.crypto.randomUUID().toLowerCase();
}
