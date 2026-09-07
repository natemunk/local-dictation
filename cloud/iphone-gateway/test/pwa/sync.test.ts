import { describe, expect, it } from "vitest";
import * as db from "../../public/app/lib/db.js";
import {
  ApiError,
  ERROR_HISTORY_CHANGED,
  ERROR_HISTORY_DISABLED,
  ERROR_MAC_UNAVAILABLE,
} from "../../public/app/lib/api.js";
import {
  MAX_HISTORY_CHANGED_ATTEMPTS,
  SYNC_ERROR,
  SYNC_HISTORY_DISABLED,
  SYNC_OFFLINE,
  SYNC_OK,
  pullSnapshot,
  runSync,
} from "../../public/app/lib/sync.js";
import { entryFixture, openFreshDatabase } from "./helpers.js";

type Page = { revision: number; entries: any[]; next_cursor: string | null };

function buildApi(options: {
  manifestRevision?: number;
  pages?: Page[];
  manifestError?: unknown;
  pageError?: unknown;
  pageErrorTimes?: number;
  log?: string[];
}) {
  const log = options.log ?? [];
  let pageFailures = options.pageErrorTimes ?? Number.POSITIVE_INFINITY;
  const state = {
    log,
    manifestCalls: 0,
    pageCalls: 0,
    operationCalls: 0,
  };

  return {
    state,
    async postOperations(operations: any[]) {
      state.operationCalls += 1;
      log.push("operations");
      return {
        revision: options.manifestRevision ?? 1,
        results: operations.map((operation) => ({
          op_id: operation.op_id,
          status: "applied",
          entry: null,
        })),
      };
    },
    async fetchManifest() {
      state.manifestCalls += 1;
      log.push("manifest");
      if (options.manifestError !== undefined) throw options.manifestError;
      return {
        revision: options.manifestRevision ?? 1,
        entry_count: 0,
        pinned_count: 0,
        retention: { unpinned_days: 90, pinned: "until_unpinned_or_deleted" },
        max_operations_per_request: 100,
        max_text_characters: 100000,
      };
    },
    async fetchHistoryPage({ cursor }: { cursor: string | null }) {
      state.pageCalls += 1;
      log.push(`page:${cursor ?? "start"}`);
      if (options.pageError !== undefined && pageFailures > 0) {
        pageFailures -= 1;
        throw options.pageError;
      }
      const pages = options.pages ?? [];
      const page = cursor === null
        ? pages[0]
        : pages.find((candidate, index) => index > 0 && pages[index - 1]?.next_cursor === cursor);
      return page ?? { revision: options.manifestRevision ?? 1, entries: [], next_cursor: null };
    },
  };
}

describe("pullSnapshot", () => {
  it("does not fetch pages when the manifest revision is unchanged", async () => {
    const { handle } = await openFreshDatabase();
    await db.setSetting(handle, db.SETTING_SYNCED_REVISION, 42);
    const api = buildApi({ manifestRevision: 42 });

    const result = await pullSnapshot({ api: api as any, database: handle, db });

    expect(result.changed).toBe(false);
    expect(api.state.pageCalls).toBe(0);
  });

  it("merges every page into the synchronized cache and records the revision", async () => {
    const { handle } = await openFreshDatabase();
    await db.putSynchronizedEntries(handle, [entryFixture({ id: "stale" })]);
    const api = buildApi({
      manifestRevision: 43,
      pages: [
        {
          revision: 43,
          entries: [entryFixture({ id: "a" }), entryFixture({ id: "b" })],
          next_cursor: "118",
        },
        { revision: 43, entries: [entryFixture({ id: "c" })], next_cursor: null },
      ],
    });

    const result = await pullSnapshot({ api: api as any, database: handle, db });

    expect(result.changed).toBe(true);
    expect(result.pages).toBe(2);
    expect(result.entryCount).toBe(3);
    const ids = (await db.getSynchronizedEntries(handle)).map((entry: any) => entry.id).sort();
    expect(ids).toEqual(["a", "b", "c"]);
    expect(await db.getStagedEntries(handle)).toEqual([]);
    expect(await db.getSetting(handle, db.SETTING_SYNCED_REVISION)).toBe(43);
    expect(typeof await db.getSetting(handle, db.SETTING_LAST_SYNC_AT)).toBe("string");
  });

  it("rejects a page whose revision drifted from the manifest", async () => {
    const { handle } = await openFreshDatabase();
    const api = buildApi({
      manifestRevision: 43,
      pages: [{ revision: 44, entries: [], next_cursor: null }],
    });

    await expect(pullSnapshot({ api: api as any, database: handle, db })).rejects.toMatchObject({
      code: ERROR_HISTORY_CHANGED,
    });
  });
});

describe("runSync", () => {
  it("pushes the operation queue before fetching the manifest", async () => {
    const { handle } = await openFreshDatabase();
    await db.enqueueOperation(handle, { op_id: "a", type: "pin", entry_id: "e1" });
    const log: string[] = [];
    const api = buildApi({
      manifestRevision: 5,
      pages: [{ revision: 5, entries: [], next_cursor: null }],
      log,
    });

    const outcome = await runSync({ api: api as any, database: handle, db });

    expect(outcome.status).toBe(SYNC_OK);
    expect(log[0]).toBe("operations");
    expect(log[1]).toBe("manifest");
    expect(await db.listOperations(handle)).toEqual([]);
  });

  it("restarts at the manifest when the Mac reports HISTORY_CHANGED", async () => {
    const { handle } = await openFreshDatabase();
    const log: string[] = [];
    const api = buildApi({
      manifestRevision: 9,
      pages: [{ revision: 9, entries: [entryFixture({ id: "z" })], next_cursor: null }],
      pageError: new ApiError(ERROR_HISTORY_CHANGED, "changed", { status: 409 }),
      pageErrorTimes: 1,
      log,
    });

    const outcome = await runSync({ api: api as any, database: handle, db });

    expect(outcome.status).toBe(SYNC_OK);
    expect(outcome.attempts).toBe(2);
    expect(api.state.manifestCalls).toBe(2);
    expect((await db.getSynchronizedEntries(handle)).length).toBe(1);
  });

  it("gives up after the attempt cap when history keeps changing", async () => {
    const { handle } = await openFreshDatabase();
    const api = buildApi({
      manifestRevision: 9,
      pages: [{ revision: 9, entries: [], next_cursor: null }],
      pageError: new ApiError(ERROR_HISTORY_CHANGED, "changed", { status: 409 }),
    });

    const outcome = await runSync({ api: api as any, database: handle, db });

    expect(outcome.status).toBe(SYNC_ERROR);
    expect(outcome.attempts).toBe(MAX_HISTORY_CHANGED_ATTEMPTS);
    expect(api.state.manifestCalls).toBe(MAX_HISTORY_CHANGED_ATTEMPTS);
    expect(await db.getStagedEntries(handle)).toEqual([]);
  });

  it("leaves the cache and the queue untouched when the Mac is unavailable", async () => {
    const { handle } = await openFreshDatabase();
    await db.putSynchronizedEntries(handle, [entryFixture({ id: "kept" })]);
    await db.setSetting(handle, db.SETTING_SYNCED_REVISION, 3);
    const api = buildApi({
      manifestError: new ApiError(ERROR_MAC_UNAVAILABLE, "unavailable", { status: 503 }),
    });
    (api as any).postOperations = async () => {
      throw new ApiError(ERROR_MAC_UNAVAILABLE, "unavailable", { status: 503 });
    };
    await db.enqueueOperation(handle, { op_id: "a", type: "pin", entry_id: "kept" });

    const outcome = await runSync({ api: api as any, database: handle, db });

    expect(outcome.status).toBe(SYNC_OFFLINE);
    expect((await db.getSynchronizedEntries(handle)).map((entry: any) => entry.id))
      .toEqual(["kept"]);
    expect((await db.listOperations(handle)).length).toBe(1);
    expect(await db.getSetting(handle, db.SETTING_SYNCED_REVISION)).toBe(3);
  });

  it("reports HISTORY_DISABLED without discarding the queue", async () => {
    const { handle } = await openFreshDatabase();
    await db.enqueueOperation(handle, { op_id: "a", type: "import", entry_id: "e1" });
    const api = buildApi({
      manifestError: new ApiError(ERROR_HISTORY_DISABLED, "off", { status: 403 }),
    });
    (api as any).postOperations = async () => {
      throw new ApiError(ERROR_HISTORY_DISABLED, "off", { status: 403 });
    };

    const outcome = await runSync({ api: api as any, database: handle, db });

    expect(outcome.status).toBe(SYNC_HISTORY_DISABLED);
    expect((await db.listOperations(handle)).length).toBe(1);
  });

  it("reports conflict and queue counts after a successful sync", async () => {
    const { handle } = await openFreshDatabase();
    await db.enqueueOperation(handle, { op_id: "a", type: "edit", entry_id: "e1" });
    const api = buildApi({
      manifestRevision: 2,
      pages: [{ revision: 2, entries: [], next_cursor: null }],
    });
    (api as any).postOperations = async (operations: any[]) => ({
      revision: 2,
      results: operations.map((operation) => ({
        op_id: operation.op_id,
        status: "conflict",
        entry: entryFixture({ id: "e1", entry_revision: 8 }),
      })),
    });

    const outcome = await runSync({ api: api as any, database: handle, db });

    expect(outcome.status).toBe(SYNC_OK);
    expect(outcome.conflictCount).toBe(1);
    expect(outcome.queuedCount).toBe(0);
  });
});
