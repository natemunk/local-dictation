import * as db from "../../public/app/lib/db.js";

let counter = 0;

export function uniqueName(prefix = "dictation-test"): string {
  counter += 1;
  return `${prefix}-${counter}-${Math.random().toString(16).slice(2)}`;
}

/** A freshly migrated database at the current schema version. */
export async function openFreshDatabase(): Promise<{ handle: any; name: string }> {
  const name = uniqueName();
  const handle = await db.openDatabase({ name });
  return { handle, name };
}

/**
 * The historical v1 schema: only `entries` (with `by_created_at`) and
 * `settings`. Used to prove the v1 -> v2 migration path.
 */
export function openLegacyVersionOne(name: string): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(name, 1);
    request.onupgradeneeded = () => {
      const handle = request.result;
      const entries = handle.createObjectStore("entries", { keyPath: "id" });
      entries.createIndex("by_created_at", "created_at", { unique: false });
      handle.createObjectStore("settings", { keyPath: "key" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export function entryFixture(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: uniqueName("entry"),
    created_at: "2026-09-06T17:20:00.000Z",
    updated_at: "2026-09-06T17:20:00.000Z",
    source_kind: "desktop",
    mode: "clean",
    raw_text: "raw text",
    polished_text: "polished text",
    user_edited_text: null,
    display_text: "polished text",
    destination_display_name: "Notes",
    remote_route: null,
    cleanup_backend: null,
    is_pinned: false,
    entry_revision: 1,
    ...overrides,
  };
}
