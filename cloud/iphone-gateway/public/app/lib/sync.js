// The synchronization algorithm from the unified-history contract (section 4).
//
// Everything is written against an injected `api` and an injected `db` module so
// the whole algorithm is unit-testable without a browser or a network.

import * as defaultDb from "./db.js";
import {
  ApiError,
  ERROR_HISTORY_CHANGED,
  ERROR_HISTORY_DISABLED,
  ERROR_MISSING_CREDENTIALS,
  HISTORY_PAGE_LIMIT,
  MAX_OPERATIONS_PER_REQUEST,
  isOfflineError,
} from "./api.js";
import { randomUuid } from "./uuid.js";

/** Restarts allowed when the Mac's revision moves while we are paging. */
export const MAX_HISTORY_CHANGED_ATTEMPTS = 5;

/** Hard stop on paging so a broken cursor cannot spin forever. */
const MAX_HISTORY_PAGES = 1000;

export const SYNC_OK = "ok";
export const SYNC_OFFLINE = "offline";
export const SYNC_HISTORY_DISABLED = "history_disabled";
export const SYNC_NEEDS_CREDENTIALS = "needs_credentials";
export const SYNC_ERROR = "error";

/* ------------------------------------------------------- operation builders */

function baseOperation(type, entryId) {
  return { op_id: randomUuid(), type, entry_id: entryId, conflict: 0, server_entry: null };
}

export function buildImportOperation(entry) {
  return {
    ...baseOperation("import", entry.id),
    created_at: entry.created_at,
    source_kind: entry.source_kind,
    mode: entry.mode,
    text: entry.raw_text ?? "",
    route: entry.remote_route ?? "cloud_fallback",
    cleanup: entry.cleanup_backend ?? "none",
  };
}

export function buildEditOperation(entry, text) {
  return { ...baseOperation("edit", entry.id), base_revision: entry.entry_revision, text };
}

export function buildPinOperation(entry, pinned) {
  return {
    ...baseOperation(pinned ? "pin" : "unpin", entry.id),
    base_revision: entry.entry_revision,
  };
}

export function buildDeleteOperation(entry) {
  return { ...baseOperation("delete", entry.id), base_revision: entry.entry_revision };
}

/** Strip the local bookkeeping fields before an operation goes on the wire. */
export function operationBody(operation) {
  const body = { op_id: operation.op_id, type: operation.type, entry_id: operation.entry_id };
  if (operation.type === "import") {
    body.created_at = operation.created_at;
    body.source_kind = operation.source_kind;
    body.mode = operation.mode;
    body.text = operation.text;
    body.route = operation.route;
    body.cleanup = operation.cleanup;
    return body;
  }
  body.base_revision = operation.base_revision;
  if (operation.type === "edit") body.text = operation.text;
  return body;
}

/* ------------------------------------------------------------------- push */

/**
 * Step 2: send the queue in batches of at most 100 and apply the results.
 * `applied` / `already_applied` drop the op, `missing` drops the op and the
 * local entry, `conflict` parks the op with the server's entry attached, and
 * `invalid` drops an op that can never succeed.
 */
export async function pushOperations({ api, database, db = defaultDb }) {
  const queue = await db.listSendableOperations(database);
  const summary = { pushed: 0, conflicts: 0, missing: 0, invalid: 0, batches: 0, revision: null };
  if (queue.length === 0) return summary;

  for (let offset = 0; offset < queue.length; offset += MAX_OPERATIONS_PER_REQUEST) {
    const batch = queue.slice(offset, offset + MAX_OPERATIONS_PER_REQUEST);
    const response = await api.postOperations(batch.map(operationBody));
    summary.batches += 1;
    if (typeof response?.revision === "number") summary.revision = response.revision;

    const results = new Map(
      (Array.isArray(response?.results) ? response.results : []).map((row) => [row.op_id, row]),
    );

    for (const operation of batch) {
      const result = results.get(operation.op_id);
      // An op the server did not answer for stays queued for the next sync.
      if (result === undefined) continue;

      if (result.status === "applied" || result.status === "already_applied") {
        await db.removeOperation(database, operation.op_id);
        if (operation.type === "import") {
          await db.updatePendingEntry(database, operation.entry_id, {
            local_state: "awaiting_sync",
          });
        }
        summary.pushed += 1;
      } else if (result.status === "missing") {
        await db.removeOperation(database, operation.op_id);
        await db.deleteEntryLocally(database, operation.entry_id);
        summary.missing += 1;
      } else if (result.status === "conflict") {
        await db.markOperationConflict(database, operation.op_id, result.entry ?? null);
        summary.conflicts += 1;
      } else {
        await db.removeOperation(database, operation.op_id);
        summary.invalid += 1;
      }
    }
  }

  return summary;
}

/* ------------------------------------------------------------------- pull */

/**
 * Steps 3 and 4: compare the manifest revision with the synchronized revision
 * and, when they differ, page the whole snapshot into staging before swapping
 * it into the synchronized cache in one transaction.
 */
export async function pullSnapshot({ api, database, db = defaultDb }) {
  const manifest = await api.fetchManifest();
  const revision = manifest?.revision;
  if (typeof revision !== "number") {
    throw new ApiError("UNEXPECTED_RESPONSE", "The history manifest was unreadable.");
  }

  const synchronized = await db.getSetting(database, db.SETTING_SYNCED_REVISION, null);
  if (synchronized === revision) {
    return { changed: false, revision, manifest, pages: 0, entryCount: 0 };
  }

  await db.clearStaging(database);

  let cursor = null;
  let pages = 0;
  let entryCount = 0;

  for (;;) {
    const page = await api.fetchHistoryPage({ revision, cursor, limit: HISTORY_PAGE_LIMIT });
    if (typeof page?.revision === "number" && page.revision !== revision) {
      throw new ApiError(ERROR_HISTORY_CHANGED, "History changed while syncing.", {
        status: 409,
        revision: page.revision,
      });
    }
    const entries = Array.isArray(page?.entries) ? page.entries : [];
    if (entries.length > 0) await db.putStagedEntries(database, entries);
    entryCount += entries.length;
    pages += 1;

    const next = page?.next_cursor ?? null;
    if (next === null || next === cursor) break;
    if (pages >= MAX_HISTORY_PAGES) {
      throw new ApiError("UNEXPECTED_RESPONSE", "The history snapshot did not terminate.");
    }
    cursor = next;
  }

  const replaced = await db.replaceEntriesFromStaging(database);
  await db.setSetting(database, db.SETTING_SYNCED_REVISION, revision);
  await db.setSetting(database, db.SETTING_LAST_SYNC_AT, new Date().toISOString());

  return { changed: true, revision, manifest, pages, entryCount, replaced };
}

/* ------------------------------------------------------------------- sync */

function isCode(error, code) {
  return error instanceof ApiError && error.code === code;
}

/**
 * Full sync: push first, then pull, restarting the pull at the manifest when the
 * Mac reports `HISTORY_CHANGED` (at most `MAX_HISTORY_CHANGED_ATTEMPTS` times).
 * `MAC_UNAVAILABLE` and network failures leave the cache and the queue alone.
 */
export async function runSync({ api, database, db = defaultDb }) {
  let push = null;

  for (let attempt = 1; attempt <= MAX_HISTORY_CHANGED_ATTEMPTS; attempt += 1) {
    try {
      if (push === null) push = await pushOperations({ api, database, db });
      const pull = await pullSnapshot({ api, database, db });
      const conflicts = await db.listConflictOperations(database);
      const queued = await db.listSendableOperations(database);
      return {
        status: SYNC_OK,
        attempts: attempt,
        push,
        pull,
        conflictCount: conflicts.length,
        queuedCount: queued.length,
      };
    } catch (error) {
      if (isCode(error, ERROR_HISTORY_CHANGED)) {
        await db.clearStaging(database);
        continue;
      }
      if (isOfflineError(error)) {
        return { status: SYNC_OFFLINE, attempts: attempt, push, error };
      }
      if (isCode(error, ERROR_HISTORY_DISABLED)) {
        return { status: SYNC_HISTORY_DISABLED, attempts: attempt, push, error };
      }
      if (isCode(error, ERROR_MISSING_CREDENTIALS)) {
        return { status: SYNC_NEEDS_CREDENTIALS, attempts: attempt, push, error };
      }
      return { status: SYNC_ERROR, attempts: attempt, push, error };
    }
  }

  return {
    status: SYNC_ERROR,
    attempts: MAX_HISTORY_CHANGED_ATTEMPTS,
    push,
    error: new ApiError(
      ERROR_HISTORY_CHANGED,
      "History kept changing while syncing. Try again.",
      { status: 409 },
    ),
  };
}
