import { describe, expect, it } from "vitest";
import * as db from "../../public/app/lib/db.js";
import {
  buildDeleteOperation,
  buildEditOperation,
  buildImportOperation,
  buildPinOperation,
  operationBody,
  pushOperations,
} from "../../public/app/lib/sync.js";
import { entryFixture, openFreshDatabase } from "./helpers.js";

function fakeApi(results: any[], revision = 7) {
  const sent: any[][] = [];
  return {
    sent,
    async postOperations(operations: any[]) {
      sent.push(operations);
      return { revision, results };
    },
    async fetchManifest() {
      throw new Error("not used");
    },
    async fetchHistoryPage() {
      throw new Error("not used");
    },
  };
}

describe("operation queue", () => {
  it("assigns increasing sequence numbers and preserves creation order", async () => {
    const { handle } = await openFreshDatabase();
    await db.enqueueOperation(handle, { op_id: "c", type: "pin", entry_id: "e3" });
    await db.enqueueOperation(handle, { op_id: "a", type: "unpin", entry_id: "e1" });
    await db.enqueueOperation(handle, { op_id: "b", type: "delete", entry_id: "e2" });

    const queue = await db.listOperations(handle);
    expect(queue.map((operation: any) => operation.op_id)).toEqual(["c", "a", "b"]);
    expect(queue.map((operation: any) => operation.seq)).toEqual([1, 2, 3]);
    expect(queue.every((operation: any) => operation.conflict === 0)).toBe(true);
  });

  it("holds conflicted operations back from the sendable queue", async () => {
    const { handle } = await openFreshDatabase();
    await db.enqueueOperation(handle, { op_id: "a", type: "pin", entry_id: "e1" });
    await db.enqueueOperation(handle, { op_id: "b", type: "pin", entry_id: "e2" });

    const serverEntry = entryFixture({ id: "e2", entry_revision: 9 });
    await db.markOperationConflict(handle, "b", serverEntry);

    expect((await db.listSendableOperations(handle)).map((row: any) => row.op_id)).toEqual(["a"]);
    const conflicts = await db.listConflictOperations(handle);
    expect(conflicts.length).toBe(1);
    expect(conflicts[0].server_entry.entry_revision).toBe(9);
  });

  it("serialises each operation type into the documented wire body", () => {
    const entry = entryFixture({
      id: "6f1d2c3e-1111-4222-8333-444455556666",
      entry_revision: 3,
      raw_text: "hello",
      source_kind: "iphone_pwa",
      remote_route: "cloud_fallback",
      cleanup_backend: "none",
    });

    const importBody: any = operationBody(buildImportOperation(entry));
    expect(importBody.type).toBe("import");
    expect(importBody.text).toBe("hello");
    expect(importBody.route).toBe("cloud_fallback");
    expect(importBody.cleanup).toBe("none");
    expect(importBody).not.toHaveProperty("base_revision");
    expect(importBody).not.toHaveProperty("conflict");
    expect(importBody).not.toHaveProperty("server_entry");

    expect(operationBody(buildEditOperation(entry, "edited"))).toMatchObject({
      type: "edit",
      base_revision: 3,
      text: "edited",
    });
    expect(operationBody(buildPinOperation(entry, true)).type).toBe("pin");
    expect(operationBody(buildPinOperation(entry, false)).type).toBe("unpin");
    const deleteBody: any = operationBody(buildDeleteOperation(entry));
    expect(deleteBody.type).toBe("delete");
    expect(deleteBody).not.toHaveProperty("text");
  });
});

describe("pushOperations", () => {
  it("removes applied and already_applied operations", async () => {
    const { handle } = await openFreshDatabase();
    await db.enqueueOperation(handle, { op_id: "a", type: "pin", entry_id: "e1" });
    await db.enqueueOperation(handle, { op_id: "b", type: "unpin", entry_id: "e2" });

    const api = fakeApi([
      { op_id: "a", status: "applied", entry: entryFixture({ id: "e1" }) },
      { op_id: "b", status: "already_applied", entry: null },
    ]);
    const summary = await pushOperations({ api, database: handle, db });

    expect(summary.pushed).toBe(2);
    expect(summary.batches).toBe(1);
    expect(await db.listOperations(handle)).toEqual([]);
  });

  it("drops the operation and the local entry when the server reports missing", async () => {
    const { handle } = await openFreshDatabase();
    await db.putSynchronizedEntries(handle, [entryFixture({ id: "gone" })]);
    await db.enqueueOperation(handle, { op_id: "a", type: "edit", entry_id: "gone" });

    const api = fakeApi([{ op_id: "a", status: "missing", entry: null }]);
    const summary = await pushOperations({ api, database: handle, db });

    expect(summary.missing).toBe(1);
    expect(await db.listOperations(handle)).toEqual([]);
    expect(await db.getSynchronizedEntries(handle)).toEqual([]);
  });

  it("retains a conflicted operation together with the server entry", async () => {
    const { handle } = await openFreshDatabase();
    await db.enqueueOperation(handle, {
      op_id: "a",
      type: "edit",
      entry_id: "e1",
      base_revision: 2,
      text: "mine",
    });

    const server = entryFixture({ id: "e1", entry_revision: 5, user_edited_text: "theirs" });
    const api = fakeApi([{ op_id: "a", status: "conflict", entry: server }]);
    const summary = await pushOperations({ api, database: handle, db });

    expect(summary.conflicts).toBe(1);
    const queue = await db.listOperations(handle);
    expect(queue.length).toBe(1);
    expect(queue[0].conflict).toBe(1);
    expect(queue[0].server_entry.entry_revision).toBe(5);
    expect(await db.listSendableOperations(handle)).toEqual([]);
  });

  it("drops invalid operations and keeps unanswered ones queued", async () => {
    const { handle } = await openFreshDatabase();
    await db.enqueueOperation(handle, { op_id: "a", type: "pin", entry_id: "e1" });
    await db.enqueueOperation(handle, { op_id: "b", type: "pin", entry_id: "e2" });

    const api = fakeApi([{ op_id: "a", status: "invalid", entry: null }]);
    const summary = await pushOperations({ api, database: handle, db });

    expect(summary.invalid).toBe(1);
    expect((await db.listOperations(handle)).map((row: any) => row.op_id)).toEqual(["b"]);
  });

  it("marks a pending entry as awaiting sync once its import applies", async () => {
    const { handle } = await openFreshDatabase();
    const entry = entryFixture({ id: "p1", entry_revision: 0, local_state: "awaiting_import" });
    await db.putPendingEntry(handle, entry);
    await db.enqueueOperation(handle, buildImportOperation(entry));

    const queued = (await db.listOperations(handle))[0];
    const api = fakeApi([{ op_id: queued.op_id, status: "applied", entry }]);
    await pushOperations({ api, database: handle, db });

    const pending = await db.getPendingEntries(handle);
    expect(pending[0].local_state).toBe("awaiting_sync");
  });

  it("splits the queue into batches of one hundred", async () => {
    const { handle } = await openFreshDatabase();
    for (let index = 0; index < 105; index += 1) {
      await db.enqueueOperation(handle, {
        op_id: `op-${index}`,
        type: "pin",
        entry_id: `e-${index}`,
      });
    }

    const api = {
      sent: [] as any[][],
      async postOperations(operations: any[]) {
        api.sent.push(operations);
        return {
          revision: 1,
          results: operations.map((operation) => ({
            op_id: operation.op_id,
            status: "applied",
            entry: null,
          })),
        };
      },
    };
    const summary = await pushOperations({ api: api as any, database: handle, db });

    expect(summary.batches).toBe(2);
    expect(api.sent[0].length).toBe(100);
    expect(api.sent[1].length).toBe(5);
    expect(await db.listOperations(handle)).toEqual([]);
  });
});
