import { readFileSync } from "node:fs";
import vm from "node:vm";
import { describe, expect, it, vi } from "vitest";
import * as db from "../../public/app/lib/db.js";
import * as apiTypes from "../../public/app/lib/api.js";
import * as sync from "../../public/app/lib/sync.js";
import * as actions from "../../public/app/lib/history-actions.js";
import * as recovery from "../../public/app/lib/recording-recovery.js";
import * as format from "../../public/app/lib/format.js";
import { searchEntries } from "../../public/app/lib/search.js";
import { entryFixture, openFreshDatabase } from "./helpers.js";

class NodeStub {
  children: NodeStub[] = [];
  parent: NodeStub | null = null;
  hidden = false; open = false; value = ""; textContent = ""; className = "";
  listeners: Record<string, (...args: any[]) => unknown> = {};
  get firstChild() { return this.children[0] ?? null; }
  append(...nodes: NodeStub[]) { for (const node of nodes) { this.children.push(node); node.parent = this; } }
  removeChild(node: NodeStub) { this.children = this.children.filter(child => child !== node); }
  addEventListener(name: string, callback: (...args: any[]) => unknown) { this.listeners[name] = callback; }
  setAttribute() {} focus() {} select() {} showModal() { this.open = true; } close() { this.open = false; }
}

const ID = "00000000-0000-4000-8000-000000000123";
function server(initial: any[] = []) {
  const rows = new Map(initial.map(row => [row.id, structuredClone(row)]));
  const sent: any[][] = [];
  let revision = 1;
  const api = {
    rows, sent,
    beforePost: null as null | (() => Promise<void>),
    beforePage: null as null | (() => Promise<void>),
    async postOperations(ops: any[]) {
      sent.push(structuredClone(ops));
      await api.beforePost?.();
      const results = ops.map(op => {
        let entry: any = rows.get(op.entry_id);
        if (op.type === "import") {
          if (entry) return { op_id: op.op_id, status: "already_applied", entry: structuredClone(entry) };
          entry = entryFixture({ id: op.entry_id, raw_text: op.text, polished_text: null,
            display_text: op.text, entry_revision: 1, source_kind: "iphone_pwa" });
          rows.set(entry.id, entry);
        } else {
          if (!entry) return { op_id: op.op_id, status: op.type === "delete" ? "already_applied" : "missing", entry: null };
          if (op.base_revision !== entry.entry_revision) return { op_id: op.op_id, status: "conflict", entry: structuredClone(entry) };
          if (op.type === "delete") { rows.delete(entry.id); entry = null; }
          else {
            if (op.type === "edit") entry.user_edited_text = op.text.trim() === "" ? null : op.text;
            else entry.is_pinned = op.type === "pin";
            entry.display_text = entry.user_edited_text ?? entry.polished_text ?? entry.raw_text;
            entry.entry_revision += 1;
          }
        }
        revision += 1;
        return { op_id: op.op_id, status: "applied", entry: entry ? structuredClone(entry) : null };
      });
      return { revision, results };
    },
    async fetchManifest() { return { revision }; },
    async fetchHistoryPage() { await api.beforePage?.(); return { revision, entries: [...rows.values()].map(row => structuredClone(row)), next_cursor: null }; },
  };
  return api;
}

async function harness(api: any, overrides: Record<string, any> = {}) {
  const { handle } = await openFreshDatabase();
  const nodes: Record<string, NodeStub> = {};
  const get = (id: string) => nodes[id] ??= new NodeStub();
  get("settings-view").hidden = true;
  get("detail-view").hidden = true;
  const source = readFileSync(new URL("../../public/app/app.js", import.meta.url), "utf8")
    .replace(/^import[\s\S]*?;\n/gm, "").replace(/^void boot\(\);/m, "");
  const context: any = vm.createContext({
    ...apiTypes, ...sync, ...actions, ...recovery, ...format, db, searchEntries,
    BUILD_ID: "synthetic-test", createApiClient: () => api,
    recordDiagnostic: async () => {}, clearDiagnostics: async () => {}, listDiagnostics: async () => [],
    navigator: { onLine: true, clipboard: { writeText: async () => { throw new Error("synthetic denial"); } } },
    document: { getElementById: get, createElement: () => new NodeStub(), addEventListener: () => {} },
    window: { setTimeout: () => 1, clearTimeout: () => {}, scrollTo: () => {}, addEventListener: () => {} },
    isRecordingSupported: () => true, isGatewayCompatible: () => true,
    Blob, AbortController, DOMException, URL, structuredClone,
    ...overrides,
  });
  vm.runInContext(source + `\nglobalThis.app = { state, acceptTranscription, saveEdit, togglePin, deleteEntry,
    openDetail, openSettings, closeSettings, sync, reload, removeAllPhoneData, copyText, render,
    retry, submitPendingRecording, wireEvents, getRecovery: () => recovery };`, context);
  const app = context.app;
  app.state.handle = handle;
  return { app, handle, nodes };
}
const credentials = { clientId: "synthetic", clientSecret: "synthetic" };
async function connect(app: any, handle: any) {
  await db.setSetting(handle, db.SETTING_CREDENTIALS, credentials);
  await app.reload();
}
async function result(app: any, savedOnMac: boolean) {
  await app.acceptTranscription({ request_id: ID, text: "Synthetic original", route: savedOnMac ? "mac_local" : "cloud_fallback",
    cleanup: "none", history_state: savedOnMac ? "saved_on_mac" : "pending_device_sync" }, ID, "literal");
}
function deferred() { let resolve!: () => void; const promise = new Promise<void>(yes => { resolve = yes; }); return { promise, resolve }; }

describe("real fresh-result UI actions and synchronization", () => {
  it.each(["edit", "pin", "delete"])("preserves %s before the first Mac snapshot", async type => {
    const api = server([entryFixture({ id: ID, raw_text: "Synthetic original", polished_text: null, entry_revision: 1 })]);
    const { app, handle } = await harness(api);
    await result(app, true);
    await connect(app, handle);
    const entry = app.state.pending[0];
    if (type === "edit") {
      app.openDetail(ID, { edit: true }); app.state.editDraft = "Synthetic correction"; await app.saveEdit(entry);
    } else if (type === "pin") await app.togglePin(entry);
    else await app.deleteEntry(entry);
    await app.sync();
    expect(await db.listOperations(handle)).toEqual([]);
    if (type === "delete") expect(api.rows.has(ID)).toBe(false);
    else {
      expect(api.rows.get(ID).raw_text).toBe("Synthetic original");
      expect(type === "edit" ? api.rows.get(ID).user_edited_text : api.rows.get(ID).is_pinned)
        .toBe(type === "edit" ? "Synthetic correction" : true);
    }
  });

  it.each(["edit", "pin", "delete"])("keeps in-flight import immutable and applies dependent %s", async type => {
    const api = server(); const gate = deferred(); api.beforePost = () => gate.promise;
    const { app, handle } = await harness(api);
    await result(app, false); await connect(app, handle);
    const entry = app.state.pending[0]; const syncing = app.sync();
    await vi.waitFor(() => expect(api.sent).toHaveLength(1));
    const sentImport = structuredClone(api.sent[0][0]);
    if (type === "edit") { app.openDetail(ID, { edit: true }); app.state.editDraft = "Synthetic correction"; await app.saveEdit(entry); }
    else if (type === "pin") await app.togglePin(entry);
    else await app.deleteEntry(entry);
    const queued = await db.listOperations(handle);
    expect(queued[0].text).toBe("Synthetic original");
    expect(queued[1].after_op_id).toBe(queued[0].op_id);
    expect(api.sent[0][0]).toEqual(sentImport);
    gate.resolve(); await syncing;
    expect((await db.listOperations(handle))).toEqual([]);
    expect(api.sent.map(batch => batch[0].type)).toEqual(["import", type]);
    if (type === "delete") expect(api.rows.has(ID)).toBe(false);
    else {
      expect(api.rows.get(ID).raw_text).toBe("Synthetic original");
      expect(type === "edit" ? api.rows.get(ID).user_edited_text : api.rows.get(ID).is_pinned)
        .toBe(type === "edit" ? "Synthetic correction" : true);
    }
  });

  it("advances revisions for multiple local changes without self-conflict", async () => {
    const api = server(); const gate = deferred(); api.beforePost = () => gate.promise;
    const { app, handle } = await harness(api);
    await result(app, false); await connect(app, handle); const entry = app.state.pending[0];
    const syncing = app.sync(); await vi.waitFor(() => expect(api.sent).toHaveLength(1));
    await actions.changeEntry(handle, entry, "edit", "First correction");
    await actions.changeEntry(handle, entry, "pin", true);
    await actions.changeEntry(handle, entry, "edit", "Last correction");
    gate.resolve(); await syncing;
    expect(api.rows.get(ID)).toMatchObject({ raw_text: "Synthetic original", user_edited_text: "Last correction", is_pinned: true, entry_revision: 4 });
    expect(await db.listOperations(handle)).toEqual([]);
  });

  it("keeps a newer draft open when an older save completes", async () => {
    const api = server(); const gate = deferred();
    const { app } = await harness(api, { changeEntry: async (...args: any[]) => { await gate.promise; return (actions.changeEntry as any)(...args); } });
    await result(app, false); const entry = app.state.pending[0];
    app.openDetail(ID, { edit: true }); app.state.editDraft = "Old draft";
    const saving = app.saveEdit(entry);
    app.openDetail(ID, { edit: true }); app.state.editDraft = "New draft";
    gate.resolve(); await saving;
    expect(app.state.editing).toBe(true); expect(app.state.editDraft).toBe("New draft");
  });

  it("removes all device data after in-flight sync settles, without resurrection", async () => {
    const api = server([entryFixture({ id: ID })]); const gate = deferred(); const started = deferred();
    api.beforePage = async () => { started.resolve(); await gate.promise; };
    const { app, handle } = await harness(api); await connect(app, handle);
    const syncing = app.sync(); await started.promise;
    await db.putPendingWithOperation(handle, entryFixture({ id: "not-yet-imported", entry_revision: 0 }), { op_id: "unsent", entry_id: "not-yet-imported", type: "import", text: "Synthetic unsent text" });
    const clearing = app.removeAllPhoneData(); expect(app.state.removingAll).toBe(true);
    gate.resolve(); await Promise.all([syncing, clearing]);
    expect(await db.getSynchronizedEntries(handle)).toEqual([]);
    expect(await db.getPendingEntries(handle)).toEqual([]);
    expect(await db.listOperations(handle)).toEqual([]);
    expect(await db.getAllSettings(handle)).toEqual({});
    expect(app.state.entries).toEqual([]); expect(app.state.credentials).toBeNull();
  });

  it("synchronizes an edit created while the previous snapshot is downloading", async () => {
    const api = server([entryFixture({ id: ID, raw_text: "Synthetic original", polished_text: null, entry_revision: 1 })]);
    const gate = deferred(); const started = deferred();
    api.beforePage = async () => { started.resolve(); await gate.promise; };
    const { app, handle } = await harness(api); await result(app, true); await connect(app, handle);
    const syncing = app.sync(); await started.promise;
    app.openDetail(ID, { edit: true }); app.state.editDraft = "Correction during snapshot";
    await app.saveEdit(app.state.pending[0]); gate.resolve(); await syncing;
    expect(api.rows.get(ID).user_edited_text).toBe("Correction during snapshot");
    expect(await db.listOperations(handle)).toEqual([]);
  });

  it("retains the successful text in memory when local persistence fails", async () => {
    const api = server() as any;
    api.transcribe = async () => ({ request_id: ID, text: "Synthetic result", route: "mac_local", history_state: "saved_on_mac" });
    const { app, nodes } = await harness(api, { saveTranscript: async () => { throw new Error("synthetic storage failure"); } });
    app.getRecovery().retain({ requestId: ID, mode: "literal", allowCloudFallback: false,
      recording: { blob: new Blob(["synthetic"]), mimeType: "audio/mp4", durationSeconds: 1 } });
    await app.submitPendingRecording();
    expect(app.getRecovery().pending).toBeNull();
    expect(app.state.result.raw_text).toBe("Synthetic result");
    expect(app.state.problem.text).toContain("could not save");
    const texts = (node: NodeStub): string[] => [node.textContent, ...node.children.flatMap(texts)];
    expect(texts(nodes["result-region"])).toContain("Synthetic result");
  });

  it("refuses device reset while an attempt is still transcribing", async () => {
    const api = server() as any; const gate = deferred();
    api.transcribe = async () => { await gate.promise; return { request_id: ID, text: "Synthetic result", route: "mac_local", history_state: "saved_on_mac" }; };
    const { app, handle } = await harness(api);
    await db.setSetting(handle, db.SETTING_CREDENTIALS, credentials);
    app.getRecovery().retain({ requestId: ID, mode: "literal", allowCloudFallback: false,
      recording: { blob: new Blob(["synthetic"]), mimeType: "audio/mp4", durationSeconds: 1 } });
    const sending = app.submitPendingRecording();
    await app.removeAllPhoneData();
    expect(await db.getSetting(handle, db.SETTING_CREDENTIALS)).toEqual(credentials);
    expect(app.state.removingAll).toBe(false);
    gate.resolve(); await sending;
    expect(app.state.result.raw_text).toBe("Synthetic result");
  });

  it("keeps Stop visible after opening settings during recording", async () => {
    const { app, nodes } = await harness(server());
    app.state.recording = true; app.openSettings();
    expect(nodes["main-view"].hidden).toBe(true);
    expect(nodes["persistent-record"].hidden).toBe(false);
    expect(nodes["persistent-record"].children.some(node => node.textContent === "Stop recording")).toBe(true);
    expect(nodes["global-controls"].className).toContain("active-sheet");
  });

  it("shows both texts when a Mac edit conflicts with a phone edit", async () => {
    const api = server([entryFixture({ id: ID, raw_text: "Synthetic original", polished_text: null,
      user_edited_text: "Mac correction", display_text: "Mac correction", entry_revision: 2 })]);
    const { app, handle, nodes } = await harness(api);
    await result(app, true); await connect(app, handle);
    app.openDetail(ID, { edit: true }); app.state.editDraft = "Phone correction";
    await app.saveEdit(app.state.pending[0]); await app.sync(); app.openDetail(ID);
    const texts = (node: NodeStub): string[] => [node.textContent, ...node.children.flatMap(texts)];
    expect(texts(nodes["detail-view"])).toEqual(expect.arrayContaining(["Your change", "Phone correction", "On your Mac", "Mac correction"]));
    expect(api.rows.get(ID).user_edited_text).toBe("Mac correction");
  });

  it("opens manual copy above an active settings sheet", async () => {
    const { app, nodes } = await harness(server()); app.openSettings();
    expect(nodes["main-view"].hidden).toBe(true);
    await app.copyText("Synthetic copy text");
    expect(nodes["copy-recovery"].open).toBe(true);
    expect(nodes["settings-view"].hidden).toBe(false);
  });

  it("retains the exact recording across failed upload and retries from the actual UI handler", async () => {
    const api = server() as any; const sent: any[] = [];
    api.transcribe = async (request: any) => { sent.push(request); if (sent.length === 1) throw new apiTypes.ApiError("ACCESS_DENIED", "Synthetic refusal");
      return { request_id: ID, text: "Synthetic result", route: "mac_local", history_state: "saved_on_mac" }; };
    const { app } = await harness(api);
    const blob = new Blob(["synthetic audio fixture"]);
    app.getRecovery().retain({ requestId: ID, mode: "literal", allowCloudFallback: false,
      recording: { blob, mimeType: "audio/mp4", durationSeconds: 1 } });
    await app.submitPendingRecording();
    expect(app.getRecovery().pending.recording.blob).toBe(blob);
    app.retry();
    await vi.waitFor(() => expect(app.getRecovery().pending).toBeNull());
    expect(sent).toHaveLength(2); expect(sent[0].blob).toBe(sent[1].blob);
    expect(sent[1].requestId).toBe(ID); expect(sent[1].allowCloudFallback).toBe(false);
  });
});


describe("history display paging", () => {
  const entries = Array.from({ length: 13 }, (_, index) => entryFixture({
    id: `history-${index}`, created_at: new Date(Date.UTC(2026, 8, 1, 0, index)).toISOString(),
    raw_text: `Synthetic entry ${index}`, polished_text: null,
    display_text: `Synthetic entry ${index}`,
  }));
  const texts = (node: NodeStub): string[] => [node.textContent, ...node.children.flatMap(texts)];
  const click = (root: NodeStub, label: string) => {
    const visit = (node: NodeStub): NodeStub | undefined => node.textContent === label
      ? node : node.children.map(visit).find(Boolean);
    const target = visit(root);
    expect(target, `button ${label}`).toBeDefined();
    target!.listeners.click();
  };

  it("renders five newest initially, five more per tap, then every saved row", async () => {
    const { app, handle, nodes } = await harness(server());
    await db.putSynchronizedEntries(handle, entries); await app.reload(); app.render();
    expect(nodes["entry-list"].children).toHaveLength(5);
    expect(texts(nodes["entry-list"])).toContain("Synthetic entry 12");
    expect(texts(nodes["entry-list"])).not.toContain("Synthetic entry 7");
    click(nodes["history-actions"], "Load more");
    expect(nodes["entry-list"].children).toHaveLength(10);
    click(nodes["history-actions"], "Show all");
    expect(nodes["entry-list"].children).toHaveLength(13);
    expect(nodes["history-actions"].hidden).toBe(true);
    expect(await db.getSynchronizedEntries(handle)).toHaveLength(13);
  });

  it("searches older hidden entries and restores browsing depth when cleared", async () => {
    const { app, handle, nodes } = await harness(server());
    await db.putSynchronizedEntries(handle, entries); await app.reload(); app.render(); app.wireEvents();
    click(nodes["history-actions"], "Load more");
    nodes["search-input"].value = "Synthetic entry 0"; nodes["search-input"].listeners.input();
    expect(nodes["entry-list"].children).toHaveLength(1);
    expect(texts(nodes["entry-list"])).toContain("Synthetic entry 0");
    nodes["search-input"].value = ""; nodes["search-input"].listeners.input();
    expect(nodes["entry-list"].children).toHaveLength(10);
  });

  it("keeps detail drafts and active result separate from the row limit", async () => {
    const { app, handle, nodes } = await harness(server());
    await db.putSynchronizedEntries(handle, entries); await app.reload(); app.render();
    app.openDetail("history-0", { edit: true }); app.state.editDraft = "Unsaved correction";
    app.render();
    expect(app.state.detailId).toBe("history-0"); expect(app.state.editDraft).toBe("Unsaved correction");
    expect(nodes["detail-view"].hidden).toBe(false);
    expect(nodes["entry-list"].children).toHaveLength(5);
    await result(app, true);
    expect(app.state.detailId).toBe("history-0"); expect(app.state.editDraft).toBe("Unsaved correction");
    expect(texts(nodes["result-region"])).toContain("Synthetic original");
    expect(nodes["entry-list"].children).toHaveLength(5);
  });
});
