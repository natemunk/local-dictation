import { afterEach, describe, expect, it } from "vitest";
import * as db from "../../public/app/lib/db.js";
import { entryFixture, openFreshDatabase, openLegacyVersionOne, uniqueName } from "./helpers.js";

const originalPut = IDBObjectStore.prototype.put;

afterEach(() => {
  IDBObjectStore.prototype.put = originalPut;
});

describe("schema", () => {
  it("creates every store and index from an empty database", async () => {
    const { handle } = await openFreshDatabase();
    expect(handle.version).toBe(db.DB_VERSION);

    const names = [...handle.objectStoreNames].sort();
    expect(names).toEqual(["entries", "ops", "pending", "settings", "staging"]);

    const transaction = handle.transaction(["entries", "ops"], "readonly");
    expect([...transaction.objectStore("entries").indexNames].sort())
      .toEqual(["by_created_at", "by_updated_at"]);
    expect([...transaction.objectStore("ops").indexNames].sort())
      .toEqual(["by_conflict", "by_entry_id", "by_seq"]);
  });

  it("migrates a version 1 database without losing its rows", async () => {
    const name = uniqueName();
    const legacy = await openLegacyVersionOne(name);
    await new Promise<void>((resolve, reject) => {
      const transaction = legacy.transaction(["entries", "settings"], "readwrite");
      transaction.objectStore("entries").put(entryFixture({ id: "kept-entry" }));
      transaction.objectStore("settings").put({ key: "default_mode", value: "literal" });
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
    });
    legacy.close();

    const handle = await db.openDatabase({ name });
    expect(handle.version).toBe(db.DB_VERSION);
    expect([...handle.objectStoreNames].sort())
      .toEqual(["entries", "ops", "pending", "settings", "staging"]);

    const entries = await db.getSynchronizedEntries(handle);
    expect(entries.map((entry: any) => entry.id)).toEqual(["kept-entry"]);
    expect(await db.getSetting(handle, db.SETTING_DEFAULT_MODE)).toBe("literal");

    const transaction = handle.transaction("entries", "readonly");
    expect([...transaction.objectStore("entries").indexNames]).toContain("by_updated_at");
  });

  it("is idempotent when reopening at the current version", async () => {
    const name = uniqueName();
    const first = await db.openDatabase({ name });
    first.close();
    const second = await db.openDatabase({ name });
    expect(second.version).toBe(db.DB_VERSION);
  });
});

describe("replaceEntriesFromStaging", () => {
  it("atomically swaps the synchronized cache and drops confirmed pending rows", async () => {
    const { handle } = await openFreshDatabase();
    await db.putSynchronizedEntries(handle, [entryFixture({ id: "old-1" })]);
    await db.putPendingEntry(handle, entryFixture({ id: "new-2", entry_revision: 0 }));
    await db.putStagedEntries(handle, [
      entryFixture({ id: "new-1" }),
      entryFixture({ id: "new-2" }),
    ]);

    const result = await db.replaceEntriesFromStaging(handle);

    expect(result.replaced).toBe(2);
    expect(result.pendingResolved).toEqual(["new-2"]);
    const ids = (await db.getSynchronizedEntries(handle)).map((entry: any) => entry.id).sort();
    expect(ids).toEqual(["new-1", "new-2"]);
    expect(await db.getStagedEntries(handle)).toEqual([]);
    expect(await db.getPendingEntries(handle)).toEqual([]);
  });

  it("leaves the previous cache intact when a write fails midway", async () => {
    const { handle } = await openFreshDatabase();
    await db.putSynchronizedEntries(handle, [
      entryFixture({ id: "old-1" }),
      entryFixture({ id: "old-2" }),
    ]);
    await db.putStagedEntries(handle, [
      entryFixture({ id: "new-1" }),
      entryFixture({ id: "new-2" }),
      entryFixture({ id: "new-3" }),
    ]);

    let writes = 0;
    IDBObjectStore.prototype.put = function patched(this: IDBObjectStore, ...args: any[]) {
      if (this.name === "entries") {
        writes += 1;
        if (writes === 2) throw new Error("storage_failure");
      }
      return (originalPut as any).apply(this, args);
    } as any;

    await expect(db.replaceEntriesFromStaging(handle)).rejects.toThrow("storage_failure");

    IDBObjectStore.prototype.put = originalPut;
    const ids = (await db.getSynchronizedEntries(handle)).map((entry: any) => entry.id).sort();
    expect(ids).toEqual(["old-1", "old-2"]);
    expect((await db.getStagedEntries(handle)).length).toBe(3);
  });
});

describe("local cache management", () => {
  it("refreshes synchronized cache while preserving pending results, operations and key", async () => {
    const { handle } = await openFreshDatabase();
    await db.putSynchronizedEntries(handle, [entryFixture()]);
    await db.putStagedEntries(handle, [entryFixture()]);
    await db.putPendingEntry(handle, entryFixture({ entry_revision: 0 }));
    await db.setSetting(handle, db.SETTING_SYNCED_REVISION, 42);
    await db.setSetting(handle, db.SETTING_CREDENTIALS, { clientId: "a", clientSecret: "b" });
    await db.enqueueOperation(handle, { op_id: "op-1", type: "pin", entry_id: "e-1" });

    await db.clearLocalCache(handle);

    expect(await db.getSynchronizedEntries(handle)).toEqual([]);
    expect(await db.getStagedEntries(handle)).toEqual([]);
    expect(await db.getPendingEntries(handle)).toHaveLength(1);
    expect(await db.getSetting(handle, db.SETTING_SYNCED_REVISION)).toBe(null);
    expect(await db.getSetting(handle, db.SETTING_CREDENTIALS)).toEqual({
      clientId: "a",
      clientSecret: "b",
    });
    expect((await db.listOperations(handle)).length).toBe(1);
  });

  it("removes an entry from both the synchronized cache and the pending store", async () => {
    const { handle } = await openFreshDatabase();
    await db.putSynchronizedEntries(handle, [entryFixture({ id: "same" })]);
    await db.putPendingEntry(handle, entryFixture({ id: "same", entry_revision: 0 }));

    await db.deleteEntryLocally(handle, "same");

    expect(await db.getSynchronizedEntries(handle)).toEqual([]);
    expect(await db.getPendingEntries(handle)).toEqual([]);
  });
});
