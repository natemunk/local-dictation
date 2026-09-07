// IndexedDB schema, migrations and typed accessors.
//
// Privacy: this database holds transcript text, queued operations and the
// Access service-token pair only. Audio is never written here or anywhere else
// that survives a recording.

export const DB_NAME = "dictation-inbox";
export const DB_VERSION = 2;

export const STORE_ENTRIES = "entries";
export const STORE_STAGING = "staging";
export const STORE_PENDING = "pending";
export const STORE_OPS = "ops";
export const STORE_SETTINGS = "settings";

export const SETTING_CREDENTIALS = "credentials";
export const SETTING_DEFAULT_MODE = "default_mode";
export const SETTING_ALLOW_CLOUD_FALLBACK = "allow_cloud_fallback";
export const SETTING_SYNCED_REVISION = "synced_revision";
export const SETTING_LAST_SYNC_AT = "last_sync_at";
export const SETTING_LAST_ROUTE = "last_route";

function promisify(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("indexeddb_request_failed"));
  });
}

function transactionDone(transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve(undefined);
    transaction.onabort = () =>
      reject(transaction.error ?? new Error("indexeddb_transaction_aborted"));
    transaction.onerror = () =>
      reject(transaction.error ?? new Error("indexeddb_transaction_failed"));
  });
}

function abortQuietly(transaction) {
  try {
    transaction.abort();
  } catch {
    // The transaction was already finished; nothing to undo.
  }
}

/**
 * Apply the schema for every version the caller has not seen yet. Exported so
 * migrations can be unit-tested against a synthetic starting version.
 */
export function upgradeDatabase(db, oldVersion, transaction) {
  if (oldVersion < 1) {
    const entries = db.createObjectStore(STORE_ENTRIES, { keyPath: "id" });
    entries.createIndex("by_created_at", "created_at", { unique: false });
    db.createObjectStore(STORE_SETTINGS, { keyPath: "key" });
  }

  if (oldVersion < 2) {
    const entries = transaction.objectStore(STORE_ENTRIES);
    if (!entries.indexNames.contains("by_updated_at")) {
      entries.createIndex("by_updated_at", "updated_at", { unique: false });
    }

    const staging = db.createObjectStore(STORE_STAGING, { keyPath: "id" });
    staging.createIndex("by_created_at", "created_at", { unique: false });

    const pending = db.createObjectStore(STORE_PENDING, { keyPath: "id" });
    pending.createIndex("by_created_at", "created_at", { unique: false });

    const ops = db.createObjectStore(STORE_OPS, { keyPath: "op_id" });
    ops.createIndex("by_seq", "seq", { unique: true });
    ops.createIndex("by_entry_id", "entry_id", { unique: false });
    ops.createIndex("by_conflict", "conflict", { unique: false });
  }
}

/** Open (and migrate) the database. The factory is injectable for tests. */
export function openDatabase(options = {}) {
  const name = options.name ?? DB_NAME;
  const version = options.version ?? DB_VERSION;
  const factory = options.factory ?? globalThis.indexedDB;

  return new Promise((resolve, reject) => {
    const request = factory.open(name, version);
    request.onupgradeneeded = (event) => {
      upgradeDatabase(request.result, event.oldVersion, request.transaction);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("indexeddb_open_failed"));
    request.onblocked = () => reject(new Error("indexeddb_blocked"));
  });
}

async function readAll(db, storeName) {
  const transaction = db.transaction(storeName, "readonly");
  const rows = await promisify(transaction.objectStore(storeName).getAll());
  await transactionDone(transaction);
  return rows;
}

async function writeAll(db, storeName, rows) {
  const transaction = db.transaction(storeName, "readwrite");
  const store = transaction.objectStore(storeName);
  for (const row of rows) store.put(row);
  await transactionDone(transaction);
}

/* ---------------------------------------------------------------- entries */

export function getSynchronizedEntries(db) {
  return readAll(db, STORE_ENTRIES);
}

export function putSynchronizedEntries(db, entries) {
  return writeAll(db, STORE_ENTRIES, entries);
}

export async function getSynchronizedEntry(db, id) {
  const transaction = db.transaction(STORE_ENTRIES, "readonly");
  const row = await promisify(transaction.objectStore(STORE_ENTRIES).get(id));
  await transactionDone(transaction);
  return row ?? null;
}

/* ---------------------------------------------------------------- staging */

export function getStagedEntries(db) {
  return readAll(db, STORE_STAGING);
}

export function putStagedEntries(db, entries) {
  return writeAll(db, STORE_STAGING, entries);
}

export async function clearStaging(db) {
  const transaction = db.transaction(STORE_STAGING, "readwrite");
  transaction.objectStore(STORE_STAGING).clear();
  await transactionDone(transaction);
}

/**
 * Atomically swap the synchronized cache for the staged snapshot.
 *
 * One transaction spans `entries`, `staging` and `pending`: the old cache is
 * cleared, the staged rows become the new cache, any pending local entry the
 * Mac has now confirmed is dropped, and the staging store is emptied. A failure
 * anywhere in the middle aborts, leaving the previous cache exactly as it was.
 *
 * @returns {Promise<{ replaced: number, pendingResolved: string[] }>}
 */
export async function replaceEntriesFromStaging(db) {
  const transaction = db.transaction(
    [STORE_ENTRIES, STORE_STAGING, STORE_PENDING],
    "readwrite",
  );
  const entries = transaction.objectStore(STORE_ENTRIES);
  const staging = transaction.objectStore(STORE_STAGING);
  const pending = transaction.objectStore(STORE_PENDING);

  try {
    const staged = await promisify(staging.getAll());
    const pendingIds = new Set(await promisify(pending.getAllKeys()));

    entries.clear();
    const resolved = [];
    for (const row of staged) {
      entries.put(row);
      if (pendingIds.has(row.id)) {
        pending.delete(row.id);
        resolved.push(row.id);
      }
    }
    staging.clear();

    await transactionDone(transaction);
    return { replaced: staged.length, pendingResolved: resolved };
  } catch (error) {
    abortQuietly(transaction);
    throw error;
  }
}

/* ---------------------------------------------------------------- pending */

export function getPendingEntries(db) {
  return readAll(db, STORE_PENDING);
}

export async function putPendingEntry(db, entry) {
  await writeAll(db, STORE_PENDING, [entry]);
  return entry;
}

export async function deletePendingEntry(db, id) {
  const transaction = db.transaction(STORE_PENDING, "readwrite");
  transaction.objectStore(STORE_PENDING).delete(id);
  await transactionDone(transaction);
}

export async function updatePendingEntry(db, id, patch) {
  const transaction = db.transaction(STORE_PENDING, "readwrite");
  const store = transaction.objectStore(STORE_PENDING);
  const existing = await promisify(store.get(id));
  if (existing === undefined) {
    await transactionDone(transaction);
    return null;
  }
  const updated = { ...existing, ...patch };
  store.put(updated);
  await transactionDone(transaction);
  return updated;
}

/** Remove an entry id from both the synchronized cache and the pending store. */
export async function deleteEntryLocally(db, id) {
  const transaction = db.transaction([STORE_ENTRIES, STORE_PENDING], "readwrite");
  transaction.objectStore(STORE_ENTRIES).delete(id);
  transaction.objectStore(STORE_PENDING).delete(id);
  await transactionDone(transaction);
}

/* ------------------------------------------------------------ operations */

/**
 * Append an operation to the queue. The sequence number is allocated inside the
 * same transaction as the write, so concurrent enqueues cannot collide.
 */
export async function enqueueOperation(db, operation) {
  const transaction = db.transaction(STORE_OPS, "readwrite");
  const store = transaction.objectStore(STORE_OPS);

  try {
    const cursor = await promisify(store.index("by_seq").openCursor(null, "prev"));
    const nextSeq = cursor === null ? 1 : cursor.value.seq + 1;
    const row = {
      conflict: 0,
      server_entry: null,
      ...operation,
      seq: nextSeq,
    };
    store.put(row);
    await transactionDone(transaction);
    return row;
  } catch (error) {
    abortQuietly(transaction);
    throw error;
  }
}

/** The whole queue in creation order. */
export async function listOperations(db) {
  const rows = await readAll(db, STORE_OPS);
  return rows.sort((a, b) => a.seq - b.seq);
}

/** Queued operations that are ready to send (conflicts are held back). */
export async function listSendableOperations(db) {
  const rows = await listOperations(db);
  return rows.filter((row) => row.conflict !== 1);
}

/** Operations parked for user resolution, each carrying the server's entry. */
export async function listConflictOperations(db) {
  const rows = await listOperations(db);
  return rows.filter((row) => row.conflict === 1);
}

export async function removeOperation(db, opId) {
  const transaction = db.transaction(STORE_OPS, "readwrite");
  transaction.objectStore(STORE_OPS).delete(opId);
  await transactionDone(transaction);
}

export async function updateOperation(db, opId, patch) {
  const transaction = db.transaction(STORE_OPS, "readwrite");
  const store = transaction.objectStore(STORE_OPS);
  const existing = await promisify(store.get(opId));
  if (existing === undefined) {
    await transactionDone(transaction);
    return null;
  }
  const updated = { ...existing, ...patch };
  store.put(updated);
  await transactionDone(transaction);
  return updated;
}

/** Park an operation as a conflict, retaining the server's current entry. */
export function markOperationConflict(db, opId, serverEntry) {
  return updateOperation(db, opId, { conflict: 1, server_entry: serverEntry ?? null });
}

/* --------------------------------------------------------------- settings */

export async function getSetting(db, key, fallback = null) {
  const transaction = db.transaction(STORE_SETTINGS, "readonly");
  const row = await promisify(transaction.objectStore(STORE_SETTINGS).get(key));
  await transactionDone(transaction);
  return row === undefined ? fallback : row.value;
}

export async function setSetting(db, key, value) {
  const transaction = db.transaction(STORE_SETTINGS, "readwrite");
  transaction.objectStore(STORE_SETTINGS).put({ key, value });
  await transactionDone(transaction);
  return value;
}

export async function deleteSetting(db, key) {
  const transaction = db.transaction(STORE_SETTINGS, "readwrite");
  transaction.objectStore(STORE_SETTINGS).delete(key);
  await transactionDone(transaction);
}

export async function getAllSettings(db) {
  const rows = await readAll(db, STORE_SETTINGS);
  const settings = {};
  for (const row of rows) settings[row.key] = row.value;
  return settings;
}

/**
 * Drop every cached transcript on this phone. The Mac is untouched and the
 * operation queue survives so unsynchronised imports are not lost.
 */
export async function clearLocalCache(db) {
  const transaction = db.transaction(
    [STORE_ENTRIES, STORE_STAGING, STORE_PENDING, STORE_SETTINGS],
    "readwrite",
  );
  transaction.objectStore(STORE_ENTRIES).clear();
  transaction.objectStore(STORE_STAGING).clear();
  transaction.objectStore(STORE_PENDING).clear();
  const settings = transaction.objectStore(STORE_SETTINGS);
  settings.delete(SETTING_SYNCED_REVISION);
  settings.delete(SETTING_LAST_SYNC_AT);
  await transactionDone(transaction);
}
