// Dictation — UI glue.
//
// Every node is built with createElement/textContent: no markup is ever parsed
// from a string, and there is no inline script, no inline style and no
// third-party code. Audio never touches storage; credentials never reach a log.

import * as db from "./lib/db.js";
import { changeEntry, saveTranscript, visibleEntries } from "./lib/history-actions.js";
import { createRecordingRecovery, canApplyUpdate } from "./lib/recording-recovery.js";
import { BUILD_ID } from "./lib/build.js";
import {
  ApiError,
  ERROR_ACCESS_DENIED,
  ERROR_AUDIO_TOO_LARGE,
  ERROR_AUDIO_TOO_LONG,
  ERROR_CLOUD_FALLBACK_FAILED,
  ERROR_CLOUD_FALLBACK_INVALID_RESPONSE,
  ERROR_HISTORY_DISABLED,
  ERROR_INVALID_AUDIO,
  ERROR_MISSING_CREDENTIALS,
  ERROR_ORIGIN_AUTH_FAILED,
  ERROR_TRANSCRIPTION_UNAVAILABLE,
  ERROR_UNSUPPORTED_AUDIO,
  createApiClient,
  isOfflineError,
} from "./lib/api.js";
import {
  clearDiagnostics,
  formatDiagnostics,
  listDiagnostics,
  recordDiagnostic,
} from "./lib/diagnostics.js";
import {
  SYNC_HISTORY_DISABLED,
  SYNC_NEEDS_CREDENTIALS,
  SYNC_OFFLINE,
  SYNC_OK,
  runSync,
} from "./lib/sync.js";
import { entryFromImport, importErrorMessage, parseImportFragment } from "./lib/fragment.js";
import { searchEntries } from "./lib/search.js";
import {
  createRecorder,
  isGatewayCompatible,
  isRecordingSupported,
} from "./lib/recorder.js";
import { createPCMCapture, isPCMStreamingSupported } from "./lib/pcm-capture.js";
import { createLiveStream, isLiveStreamingSupported } from "./lib/live-stream.js";
import {
  deviceLabel,
  displayTextOf,
  formatElapsed,
  friendlyTime,
  previewText,
  routeLabel,
} from "./lib/format.js";
import { randomUuid } from "./lib/uuid.js";

const MAX_IMPORT_CHARACTERS = 100_000;
const SEARCH_APPEARS_ABOVE = 5;
const HISTORY_PAGE_SIZE = 5;
const COPIED_MS = 1500;
const TOAST_MS = 2000;

const dom = {
  setup: document.getElementById("setup-region"),
  record: document.getElementById("record-region"),
  recordButton: document.getElementById("record-button"),
  timer: document.getElementById("record-timer"),
  status: document.getElementById("record-status"),
  liveTranscript: document.getElementById("live-transcript"),
  statusAction: document.getElementById("record-action"),
  result: document.getElementById("result-region"),
  history: document.getElementById("history-region"),
  search: document.getElementById("search-input"),
  list: document.getElementById("entry-list"),
  listEmpty: document.getElementById("list-empty"),
  historyActions: document.getElementById("history-actions"),
  settingsButton: document.getElementById("settings-button"),
  main: document.getElementById("main-view"),
  detail: document.getElementById("detail-view"),
  settings: document.getElementById("settings-view"),
  toast: document.getElementById("toast"),
  recovery: document.getElementById("recording-recovery"),
  copyRecovery: document.getElementById("copy-recovery"),
  persistentRecord: document.getElementById("persistent-record"),
  update: document.getElementById("update-ready"),
  globalControls: document.getElementById("global-controls"),
};

const state = {
  handle: null,
  entries: [],
  pending: [],
  operations: [],
  query: "",
  historyVisibleCount: HISTORY_PAGE_SIZE,
  credentials: null,
  cleanUp: true,
  allowCloudFallback: false,
  lastRoute: null,
  online: navigator.onLine,
  syncing: false,
  historyDisabled: false,
  problem: null,
  clipboardImport: null,
  copyFallbackText: null,
  recordingStarting: false,
  recording: false,
  transcribing: false,
  elapsedMs: 0,
  result: null,
  detailId: null,
  editing: false,
  editDraft: "",
  showOriginal: false,
  askDelete: false,
  askClear: false,
  askRemoveAll: false,
  removingAll: false,
  showSecret: false,
  testResult: null,
  diagnosticCount: 0,
  liveText: "",
  liveStatus: "connecting",
};

let recorder = null;
let pcmCapture = null;
let liveStream = null;
let recordingRequestId = null;
let recordingMode = null;
let recordingAllowsCloudFallback = null;
let toastTimer = null;
let waitingWorker = null;
let updateRequested = false;
let syncTask = null;
let syncAgain = false;
let editGeneration = 0;
const recovery = createRecordingRecovery();

const api = createApiClient({ getCredentials: () => state.credentials });

/* ------------------------------------------------------------ DOM helpers */

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className !== undefined && className !== null && className !== "") {
    node.className = className;
  }
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

function clear(node) {
  while (node.firstChild !== null) node.removeChild(node.firstChild);
}

function button(label, className, onClick) {
  const node = el("button", className, label);
  node.type = "button";
  node.addEventListener("click", onClick);
  return node;
}

function toast(message) {
  dom.toast.textContent = message;
  dom.toast.hidden = false;
  if (toastTimer !== null) window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => {
    dom.toast.hidden = true;
    toastTimer = null;
  }, TOAST_MS);
}

/** A Copy button that says "Copied ✓" for a moment after it works. */
function copyButton(text, className) {
  const node = button("Copy", className, async () => {
    const copied = await copyText(text);
    if (!copied) return;
    node.textContent = "Copied ✓";
    window.setTimeout(() => {
      node.textContent = "Copy";
    }, COPIED_MS);
  });
  return node;
}

/* ------------------------------------------------------------- derivations */

function conflictOperations() {
  return state.operations.filter((operation) => operation.conflict === 1);
}

function notOnMacIds() {
  const ids = new Set();
  for (const operation of state.operations) {
    if (operation.conflict !== 1) ids.add(operation.entry_id);
  }
  for (const entry of state.pending) ids.add(entry.id);
  return ids;
}

/** Synchronized cache plus local-only entries, de-duplicated by id. */
function combinedEntries() {
  return visibleEntries(state.entries, state.pending, state.operations);
}

function findEntry(id) {
  return combinedEntries().find((entry) => entry.id === id) ?? null;
}

function conflictFor(id) {
  return conflictOperations().find((operation) => operation.entry_id === id) ?? null;
}

/* ------------------------------------------------------------------ errors */

function problemWithReference(problem, error) {
  const requestId = error instanceof ApiError ? error.requestId : null;
  return {
    ...problem,
    reference: typeof requestId === "string" && requestId.length >= 8
      ? `Request ${requestId.slice(0, 8)}`
      : null,
  };
}

/** One plain sentence and at most one obvious next step. */
function describeProblem(error) {
  if (error instanceof ApiError) {
    if (error.code === ERROR_MISSING_CREDENTIALS) {
      return problemWithReference(
        { text: "Add your key to reach your Mac.", label: "Add your key", run: openSettings },
        error,
      );
    }
    if (error.code === ERROR_ACCESS_DENIED) {
      return problemWithReference(
        { text: "That key was refused.", label: "Check your key", run: openSettings },
        error,
      );
    }
    if (error.code === ERROR_HISTORY_DISABLED) {
      return problemWithReference(
        { text: "Your Mac is not saving history yet.", label: null, run: null },
        error,
      );
    }
    if (error.code === ERROR_UNSUPPORTED_AUDIO) {
      return problemWithReference(
        { text: "This browser cannot send audio your Mac accepts.", label: null, run: null },
        error,
      );
    }
    if (error.code === ERROR_AUDIO_TOO_LARGE || error.code === ERROR_AUDIO_TOO_LONG) {
      return problemWithReference(
        { text: "That recording is too long to send.", label: null, run: null },
        error,
      );
    }
    if (error.code === ERROR_INVALID_AUDIO) {
      return problemWithReference(
        { text: "The recording could not be read.", label: "Record again", run: recordAgain },
        error,
      );
    }
    if (error.code === ERROR_ORIGIN_AUTH_FAILED) {
      return problemWithReference(
        { text: "The protected Mac connection is misconfigured.", label: "Open settings", run: openSettings },
        error,
      );
    }
    if (
      error.code === ERROR_CLOUD_FALLBACK_FAILED
      || error.code === ERROR_CLOUD_FALLBACK_INVALID_RESPONSE
    ) {
      return problemWithReference(
        { text: "Cloud fallback could not transcribe that recording.", label: "Try again", run: retry },
        error,
      );
    }
    if (error.code === ERROR_TRANSCRIPTION_UNAVAILABLE) {
      return problemWithReference(
        { text: "The transcription service is temporarily unavailable.", label: "Try again", run: retry },
        error,
      );
    }
    if (isOfflineError(error)) {
      return problemWithReference(
        { text: "Your Mac is not reachable right now.", label: "Try again", run: retry },
        error,
      );
    }
  }
  return problemWithReference(
    { text: "That did not work. Diagnostics now contain the failure details.", label: "Try again", run: retry },
    error,
  );
}

function setProblem(error) {
  state.problem = describeProblem(error);
}

function retry() {
  state.problem = null;
  if (recovery.pending !== null) void submitPendingRecording();
  else void sync();
}

function recordAgain() {
  if (!recovery.discard()) return;
  state.problem = null;
  void startRecording();
}

/* --------------------------------------------------------------- rendering */

function renderSetup() {
  clear(dom.setup);

  clear(dom.copyRecovery);
  if (state.copyFallbackText === null && dom.copyRecovery.open) dom.copyRecovery.close();
  if (state.copyFallbackText !== null) {
    const card = el("section", "card");
    card.append(el("p", "caption", "Press and hold the text to copy it."));
    const area = el("textarea");
    area.readOnly = true;
    area.value = state.copyFallbackText;
    card.append(area);
    card.append(button("Done", "big done", () => {
      state.copyFallbackText = null;
      renderSetup();
    }));
    dom.copyRecovery.append(card);
    if (!dom.copyRecovery.open) dom.copyRecovery.showModal();
    area.focus();
    area.select();
  }

  if (state.clipboardImport !== null) {
    const card = el("section", "card");
    card.append(el("p", "caption", "Your transcript is on the clipboard."));
    card.append(button("Import Copied Transcript", "big", () => void importFromClipboard()));
    dom.setup.append(card);
  }

  if (state.credentials === null) {
    const card = el("section", "card");
    card.append(el("h2", null, "Connect to your Mac"));
    card.append(el("p", "caption", "Paste the two lines your Mac gave you. They stay on this phone."));

    const idInput = el("input");
    idInput.id = "setup-client-id";
    idInput.type = "text";
    idInput.autocomplete = "off";
    idInput.spellcheck = false;
    idInput.placeholder = "Client ID";
    card.append(labelled("Client ID", idInput));

    const secretInput = el("input");
    secretInput.id = "setup-client-secret";
    secretInput.type = "password";
    secretInput.autocomplete = "off";
    secretInput.spellcheck = false;
    secretInput.placeholder = "Client Secret";
    card.append(labelled("Client Secret", secretInput));

    card.append(button("Save", "big", () => {
      void saveCredentials(idInput.value.trim(), secretInput.value.trim());
    }));
    dom.setup.append(card);
  }
}

function labelled(text, input) {
  const wrapper = el("label", "field");
  wrapper.append(el("span", null, text), input);
  wrapper.htmlFor = input.id;
  return wrapper;
}

function statusInfo() {
  if (state.recordingStarting) return { text: "Starting microphone…" };
  if (state.recording) return { text: state.liveStatus === "receiving"
    ? "Mac is receiving audio…"
    : state.liveStatus === "preview_unavailable"
      ? "Live words unavailable · recording continues"
      : state.liveStatus === "sending"
        ? "Sending audio · waiting for Mac…"
    : state.liveStatus === "fallback"
      ? "Recording · file upload backup"
      : "Recording · connecting live audio…" };
  if (state.transcribing) return { text: "Transcribing…" };
  if (state.problem !== null) {
    const reference = typeof state.problem.reference === "string"
      ? ` · ${state.problem.reference}`
      : "";
    return { text: `${state.problem.text}${reference}`, bad: true, action: state.problem };
  }
  if (recovery.pending !== null) return { text: "Recording kept on this page. Retry when you are ready." };
  if (state.historyDisabled) return { text: "Your Mac is not saving history yet." };
  if (state.syncing) return { text: "Syncing…" };
  if (!state.online) return { text: "Offline · showing saved history" };
  if (!isRecordingSupported()) return { text: "This browser cannot record." };
  if (state.result !== null) {
    const route = routeLabel(state.result.remote_route);
    if (route !== null) return { text: route };
  }
  return { text: "Ready" };
}

function renderRecord() {
  dom.record.hidden = state.credentials === null;

  dom.recordButton.textContent = state.recording
    ? "Stop"
    : (state.recordingStarting ? "Starting…" : "Record");
  dom.recordButton.className = state.recording ? "record-button on" : "record-button";
  dom.recordButton.disabled = state.recordingStarting
    || state.transcribing
    || recovery.pending !== null
    || !isRecordingSupported();

  dom.timer.hidden = !state.recording;
  dom.timer.textContent = formatElapsed(state.elapsedMs);

  dom.liveTranscript.hidden = state.liveText === "";
  dom.liveTranscript.textContent = state.liveText;

  renderGlobalControls();
  const info = statusInfo();
  dom.status.textContent = info.text;
  dom.status.className = info.bad === true ? "status bad" : "status";

  clear(dom.statusAction);
  if (info.action !== undefined && info.action !== null && info.action.label !== null) {
    dom.statusAction.append(button(info.action.label, "big", info.action.run));
  }
}

function updateIsSafe() {
  return canApplyUpdate({ ...state, hasRecording: recovery.pending !== null,
    settingsOpen: !dom.settings.hidden });
}

function renderGlobalControls() {
  clear(dom.persistentRecord);
  const away = dom.main.hidden && (state.recording || state.recordingStarting || state.transcribing);
  dom.globalControls.className = away ? "global-controls active-sheet" : "global-controls";
  for (const sheet of [dom.settings, dom.detail]) sheet.className = away ? "sheet with-recording" : "sheet";
  dom.persistentRecord.hidden = !away;
  if (away) {
    dom.persistentRecord.append(el("p", "status", statusInfo().text));
    if (state.recording) dom.persistentRecord.append(button("Stop recording", "big", () => void stopRecording()));
  }
  clear(dom.recovery);
  dom.recovery.hidden = recovery.pending === null || (dom.main.hidden && !state.transcribing);
  if (!dom.recovery.hidden) {
    if (state.transcribing) {
      dom.recovery.append(button("Cancel transcription", "plain", () => recovery.cancel()));
    } else {
      dom.recovery.append(el("p", "caption", "Your recording is kept on this page until you retry or discard it. Closing this page loses it."));
      dom.recovery.append(button("Retry recording", "big", () => void submitPendingRecording()));
      dom.recovery.append(button("Discard recording", "plain warn", () => {
        if (!recovery.discard()) return;
        state.problem = null;
        render();
      }));
    }
  }
  clear(dom.update);
  dom.update.hidden = waitingWorker === null || !updateIsSafe();
  if (!dom.update.hidden) dom.update.append(button("Update ready · reload", "plain", () => {
    if (!updateIsSafe() || waitingWorker === null) return;
    updateRequested = true;
    waitingWorker.postMessage({ type: "ACTIVATE_UPDATE" });
  }));
}

function renderResult() {
  clear(dom.result);
  if (state.result === null) return;

  const entry = findEntry(state.result.id) ?? state.result;
  const card = el("section", "card");
  card.append(el("p", "transcript", displayTextOf(entry)));
  card.append(copyButton(displayTextOf(entry), "big"));
  card.append(button("Edit", "link", () => openDetail(entry.id, { edit: true })));
  dom.result.append(card);
}

function metaLine(entry, notOnMac) {
  const parts = [friendlyTime(entry.created_at, Date.now())];
  const device = deviceLabel(entry.source_kind);
  if (device !== "") parts.push(device);
  if (entry.remote_route === "cloud_fallback") parts.push("cloud");
  let line = parts.filter((part) => part !== "").join(" · ");
  if (entry.is_pinned === true) line += " 📌";
  if (notOnMac) line += " · not yet on Mac";
  return line;
}

function copyIconButton(text) {
  const node = button("", "row-copy", async () => {
    const copied = await copyText(text);
    if (copied) toast("Copied");
  });
  node.setAttribute("aria-label", "Copy");
  const icon = el("span", "copy-icon");
  icon.setAttribute("aria-hidden", "true");
  node.append(icon);
  return node;
}

function entryRow(entry, notOnMac) {
  const item = el("li", "row");

  const open = el("button", "row-open");
  open.type = "button";
  open.append(el("span", "row-text", previewText(displayTextOf(entry), 200) || "Empty"));
  open.append(el("span", "row-meta", metaLine(entry, notOnMac)));
  open.addEventListener("click", () => openDetail(entry.id));

  item.append(open, copyIconButton(displayTextOf(entry)));
  return item;
}

function renderList() {
  const all = combinedEntries();
  const notOnMac = notOnMacIds();

  dom.history.hidden = state.credentials === null && all.length === 0;
  dom.search.hidden = all.length <= SEARCH_APPEARS_ABOVE;
  if (dom.search.hidden && state.query !== "") {
    state.query = "";
    dom.search.value = "";
  }
  // Search always covers the complete saved history, independent of browsing
  // depth. Clearing it restores the user's previous browsing limit.
  const matches = searchEntries(all, state.query);
  const searching = state.query.trim() !== "";
  const visible = searching ? matches : matches.slice(0, state.historyVisibleCount);

  clear(dom.list);
  for (const entry of visible) dom.list.append(entryRow(entry, notOnMac.has(entry.id)));

  clear(dom.historyActions);
  dom.historyActions.hidden = searching || visible.length >= matches.length;
  if (!dom.historyActions.hidden) {
    dom.historyActions.append(el("p", "caption", `Showing ${visible.length} of ${matches.length}`));
    const actions = el("div", "trio");
    actions.append(button("Load more", "plain", () => {
      state.historyVisibleCount += HISTORY_PAGE_SIZE;
      renderList();
    }));
    actions.append(button("Show all", "plain", () => {
      state.historyVisibleCount = Infinity;
      renderList();
    }));
    dom.historyActions.append(actions);
  }

  dom.listEmpty.hidden = matches.length > 0;
  dom.listEmpty.textContent = state.query === ""
    ? "Nothing here yet."
    : "Nothing matches that search.";
}

function sheetHead(onDone) {
  const head = el("div", "sheet-head");
  head.append(button("Done", "sheet-done", onDone));
  return head;
}

function renderDetail() {
  if (state.detailId === null) {
    dom.detail.hidden = true;
    clear(dom.detail);
    dom.main.hidden = dom.settings.hidden === false;
    return;
  }

  const entry = findEntry(state.detailId);
  if (entry === null) {
    closeDetail();
    return;
  }

  dom.main.hidden = true;
  dom.detail.hidden = false;
  clear(dom.detail);
  dom.detail.append(sheetHead(closeDetail));

  const body = el("div", "sheet-inner");
  body.append(el("p", "row-meta", metaLine(entry, notOnMacIds().has(entry.id))));

  const conflict = conflictFor(entry.id);
  if (conflict !== null) {
    const card = el("section", "card");
    card.append(el("p", "ask", conflict.failure === "invalid"
      ? "This change could not be saved. Your words are still here."
      : "This was also changed on your Mac."));
    if (conflict.type === "edit") {
      card.append(el("h3", null, "Your change"), el("p", "transcript", conflict.text));
      card.append(el("h3", null, "On your Mac"), el("p", "transcript", displayTextOf(conflict.server_entry) || "No saved text"));
    } else {
      card.append(el("p", "caption", conflict.type === "delete" ? "You asked to delete this." : "You changed whether to keep this pinned."));
    }
    const row = el("div", "trio");
    if (conflict.failure !== "invalid") row.append(button("Keep mine", "plain", () => void keepMine(conflict)));
    row.append(button(conflict.failure === "invalid" ? "Discard this change" : "Use Mac's", "plain", () => void useMacs(conflict)));
    card.append(row);
    body.append(card);
  }

  if (state.editing) {
    const area = el("textarea");
    area.value = state.editDraft;
    area.addEventListener("input", () => {
      state.editDraft = area.value;
    });
    body.append(area);

    const row = el("div", "trio");
    row.append(button("Save", "plain", () => void saveEdit(entry)));
    row.append(button("Cancel", "plain", () => {
      editGeneration += 1;
      state.editing = false;
      state.editDraft = "";
      state.showOriginal = false;
      renderDetail();
    }));
    body.append(row);

    body.append(button(
      state.showOriginal ? "Hide original" : "Show original",
      "link",
      () => {
        state.showOriginal = !state.showOriginal;
        renderDetail();
      },
    ));

    if (state.showOriginal) {
      const original = el("div", "original");
      original.append(el("h3", null, "What you said"));
      original.append(el("p", null, entry.raw_text || "Nothing saved."));
      original.append(el("h3", null, "Tidied up"));
      original.append(el("p", null, entry.polished_text || "Nothing saved."));
      body.append(original);
    }
  } else {
    body.append(el("p", "transcript", displayTextOf(entry) || "Empty"));
    body.append(copyButton(displayTextOf(entry), "big"));

    if (state.askDelete) {
      const card = el("section", "card");
      card.append(el("p", "ask", "Delete this?"));
      const row = el("div", "trio");
      row.append(button("Delete", "plain warn", () => void deleteEntry(entry)));
      row.append(button("Cancel", "plain", () => {
        state.askDelete = false;
        renderDetail();
      }));
      card.append(row);
      body.append(card);
    } else {
      const row = el("div", "trio");
      row.append(button("Edit", "plain", () => {
        editGeneration += 1;
        state.editing = true;
        state.editDraft = displayTextOf(entry);
        renderDetail();
      }));
      row.append(button(entry.is_pinned === true ? "Unpin" : "Pin", "plain", () => {
        void togglePin(entry);
      }));
      row.append(button("Delete", "plain warn", () => {
        state.askDelete = true;
        renderDetail();
      }));
      body.append(row);
    }
  }

  dom.detail.append(body);
}

function toggleRow(labelText, checked, onChange) {
  const row = el("label", "toggle");
  const input = el("input");
  input.type = "checkbox";
  input.checked = checked;
  input.addEventListener("change", () => onChange(input.checked));
  row.append(el("span", null, labelText), input);
  return row;
}

function renderSettings() {
  if (dom.settings.hidden) return;
  clear(dom.settings);
  dom.settings.append(sheetHead(closeSettings));

  const body = el("div", "sheet-inner");

  /* --- connect --- */
  const connect = el("section", "group");
  connect.append(el("h2", null, "Connect to your Mac"));
  connect.append(el("p", "caption", "The two lines your Mac gave you. They stay on this phone."));

  const idInput = el("input");
  idInput.id = "settings-client-id";
  idInput.type = "text";
  idInput.autocomplete = "off";
  idInput.spellcheck = false;
  idInput.placeholder = "Client ID";
  idInput.value = state.credentials?.clientId ?? "";
  connect.append(labelled("Client ID", idInput));

  const secretInput = el("input");
  secretInput.id = "settings-client-secret";
  secretInput.type = state.showSecret ? "text" : "password";
  secretInput.autocomplete = "off";
  secretInput.spellcheck = false;
  secretInput.placeholder = "Client Secret";
  secretInput.value = state.credentials?.clientSecret ?? "";
  connect.append(labelled("Client Secret", secretInput));
  connect.append(button(state.showSecret ? "Hide" : "Show", "link start", () => {
    state.showSecret = !state.showSecret;
    renderSettings();
  }));

  const connectActions = el("div", "stack");
  connectActions.append(button("Save", "big", () => {
    void saveCredentials(idInput.value.trim(), secretInput.value.trim());
  }));
  connectActions.append(button("Test", "plain", () => void testConnection()));
  connectActions.append(button("Remove key", "plain warn", () => void clearCredentials()));
  connect.append(connectActions);

  if (state.testResult !== null) {
    connect.append(el(
      "p",
      state.testResult.ok ? "note ok" : "note bad",
      state.testResult.ok ? "✓ Connected" : `✗ ${state.testResult.reason}`,
    ));
  }
  body.append(connect);

  /* --- dictation --- */
  const dictation = el("section", "group");
  dictation.append(el("h2", null, "Dictation"));
  dictation.append(el("p", "caption", "How your words are handled after you stop talking."));
  dictation.append(toggleRow("Clean up my words", state.cleanUp, (on) => void setCleanUp(on)));
  dictation.append(toggleRow(
    "Use cloud when Mac is unavailable",
    state.allowCloudFallback,
    (on) => void setAllowCloudFallback(on),
  ));
  body.append(dictation);

  /* --- history --- */
  const history = el("section", "group");
  history.append(el("h2", null, "History"));
  history.append(el("p", "caption", "Your Mac keeps the real history. This phone keeps a copy."));
  const historyActions = el("div", "stack");
  historyActions.append(button("Refresh now", "plain", () => void sync()));
  historyActions.append(button("Export", "plain", exportEntries));
  historyActions.append(button("Copy all", "plain", () => void copyAll()));
  if (state.askClear) {
    historyActions.append(el("p", "ask", "Refresh the saved copy from your Mac? Unsaved work and your key stay here."));
    const row = el("div", "trio");
    row.append(button("Refresh saved copy", "plain", () => void clearHistory()));
    row.append(button("Cancel", "plain", () => {
      state.askClear = false;
      renderSettings();
    }));
    historyActions.append(row);
  } else {
    historyActions.append(button("Refresh saved copy", "plain", () => {
      state.askClear = true;
      renderSettings();
    }));
  }
  if (state.askRemoveAll) {
    historyActions.append(el("p", "ask", "Remove every saved word and your key from this phone? Changes not yet on your Mac will be lost. Your Mac is untouched."));
    historyActions.append(button("Remove all phone data", "plain warn", () => void removeAllPhoneData()));
    historyActions.append(button("Cancel", "plain", () => { state.askRemoveAll = false; renderSettings(); }));
  } else {
    historyActions.append(button("Remove all data from this phone", "plain warn", () => {
      state.askRemoveAll = true; renderSettings();
    }));
  }
  history.append(historyActions);
  body.append(history);

  /* --- diagnostics --- */
  const diagnostics = el("section", "group");
  const diagnosticCount = state.diagnosticCount;
  diagnostics.append(el("h2", null, "Diagnostics"));
  diagnostics.append(el("p", "caption", `App ${BUILD_ID}`));
  diagnostics.append(el(
    "p",
    "caption",
    `${diagnosticCount} safe event${diagnosticCount === 1 ? "" : "s"} saved on this phone.`,
  ));
  diagnostics.append(el(
    "p",
    "caption",
    "Includes request IDs, phases, status codes, routes, and timing — never recordings, words, or keys.",
  ));
  const diagnosticActions = el("div", "stack");
  diagnosticActions.append(button("Copy diagnostics", "plain", () => void copySafeDiagnostics()));
  diagnosticActions.append(button("Clear diagnostics", "plain warn", () => void clearSafeDiagnostics()));
  diagnostics.append(diagnosticActions);
  body.append(diagnostics);

  /* --- install --- */
  const install = el("section", "group");
  install.append(el("h2", null, "Add to Home Screen"));
  install.append(el("p", "caption", "Three steps to get an app icon on your phone."));
  const steps = el("ol", "steps");
  for (const step of [
    "Open this page in Safari.",
    "Tap the Share button.",
    "Choose Add to Home Screen.",
  ]) {
    steps.append(el("li", null, step));
  }
  install.append(steps);
  body.append(install);

  /* --- privacy --- */
  const privacy = el("section", "group privacy");
  privacy.append(el("h2", null, "Privacy"));
  privacy.append(el("p", "caption", "What happens to what you say."));
  privacy.append(el("p", null, "Your recording is sent for transcribing and is never saved on this phone."));
  privacy.append(el("p", null, "Your words pass through Cloudflare on the way to your Mac, and no copy is kept there."));
  privacy.append(el("p", null, "There is no behavioral tracking. Troubleshooting diagnostics stay on this phone and never contain what you said or your keys."));
  body.append(privacy);

  dom.settings.append(body);
}

function render() {
  renderSetup();
  renderRecord();
  renderResult();
  renderList();
  renderDetail();
  renderSettings();
  renderGlobalControls();
}

/* --------------------------------------------------------------- data load */

async function reload() {
  const [entries, pending, operations, settings] = await Promise.all([
    db.getSynchronizedEntries(state.handle),
    db.getPendingEntries(state.handle),
    db.listOperations(state.handle),
    db.getAllSettings(state.handle),
  ]);
  state.entries = entries;
  state.pending = pending;
  state.operations = operations;
  state.credentials = settings[db.SETTING_CREDENTIALS] ?? null;
  state.cleanUp = (settings[db.SETTING_DEFAULT_MODE] ?? "clean") === "clean";
  state.allowCloudFallback = settings[db.SETTING_ALLOW_CLOUD_FALLBACK] === true;
  state.lastRoute = settings[db.SETTING_LAST_ROUTE] ?? null;
}

/* -------------------------------------------------------------------- sync */

function sync(options = {}) {
  if (state.removingAll) return syncTask ?? Promise.resolve();
  if (state.syncing) {
    syncAgain = true;
    return syncTask;
  }
  syncTask = (async () => {
    do {
      syncAgain = false;
      await performSync(options);
    } while (syncAgain && !state.removingAll);
  })().finally(() => { syncTask = null; });
  return syncTask;
}

async function performSync({ silent = false } = {}) {
  if (state.credentials === null) {
    if (!silent) openSettings();
    return;
  }

  state.syncing = true;
  renderRecord();

  try {
    const outcome = await runSync({ api, database: state.handle, db });
    await reload();

    if (outcome.status === SYNC_OK) {
      state.historyDisabled = false;
      state.online = true;
      state.problem = null;
      if (!silent) toast("Up to date");
    } else if (outcome.status === SYNC_OFFLINE) {
      state.online = false;
      if (!silent) setProblem(outcome.error);
    } else if (outcome.status === SYNC_HISTORY_DISABLED) {
      state.historyDisabled = true;
    } else if (outcome.status === SYNC_NEEDS_CREDENTIALS) {
      setProblem(outcome.error);
    } else if (!silent) {
      setProblem(outcome.error);
    }
  } catch {
    if (!silent) setProblem(null);
  } finally {
    state.syncing = false;
    render();
  }
}

/* --------------------------------------------------------------- recording */

async function startRecording() {
  if (state.credentials === null) {
    openSettings();
    return;
  }
  if (!isRecordingSupported() || state.recordingStarting || state.recording || state.transcribing || recovery.pending !== null || state.removingAll) {
    return;
  }

  state.recordingStarting = true;
  state.liveStatus = "connecting";
  state.problem = null;
  renderRecord();

  const requestId = randomUuid();
  recordingRequestId = requestId;
  const mode = state.cleanUp ? "clean" : "literal";
  const allowsCloudFallback = state.allowCloudFallback;
  let candidateCapture = null;
  let candidateStream = null;

  if (isPCMStreamingSupported() && isLiveStreamingSupported()) {
    try {
      candidateStream = createLiveStream({
        api,
        requestId,
        mode,
        allowCloudFallback: allowsCloudFallback,
        onStatus: (status) => {
          if (recordingRequestId !== requestId) return;
          state.liveStatus = status;
          renderRecord();
        },
        onPartial: (text) => {
          if (recordingRequestId !== requestId) return;
          state.liveText = text;
          renderRecord();
        },
      });
      candidateCapture = createPCMCapture({
        onChunk: (chunk) => candidateStream?.push(chunk),
      });
    } catch {
      state.liveStatus = "fallback";
      void recordDiagnostic({ operation: "live_transcription", phase: "capture",
        outcome: "failed", requestId, code: "STREAM_CAPTURE_FAILED" });
      candidateCapture = null;
      candidateStream = null;
    }
  } else {
    state.liveStatus = "fallback";
    void recordDiagnostic({ operation: "live_transcription", phase: "capture",
      outcome: "failed", requestId, code: "STREAM_UNSUPPORTED" });
  }

  recorder = createRecorder({
    onElapsed: (elapsed) => {
      state.elapsedMs = elapsed;
      dom.timer.textContent = formatElapsed(elapsed);
    },
    onAutoStop: (reason) => {
      toast(reason === "size" ? "Recording size limit reached" : "Ten minute limit reached");
      void stopRecording();
    },
    onError: () => {
      liveStream?.cancel();
      void pcmCapture?.cancel();
      liveStream = null;
      pcmCapture = null;
      recordingRequestId = null;
      recordingMode = null;
      recordingAllowsCloudFallback = null;
      state.recordingStarting = false;
      state.recording = false;
      state.elapsedMs = 0;
      state.liveText = "";
      toast("Recording stopped");
      renderRecord();
    },
    onStreamError: () => {
      candidateStream?.captureFailed();
      void candidateCapture?.cancel();
      if (liveStream === candidateStream) liveStream = null;
      if (pcmCapture === candidateCapture) pcmCapture = null;
      if (recordingRequestId === requestId) {
        state.liveStatus = "fallback";
        renderRecord();
      }
    },
    onStreamReady: async (microphoneStream, signal) => {
      if (candidateCapture === null || candidateStream === null) return;
      try {
        await candidateCapture.attach(microphoneStream, { signal });
        if (liveStream !== candidateStream) {
          await candidateCapture.cancel();
          return;
        }
        pcmCapture = candidateCapture;
      } catch {
        candidateStream.captureFailed();
        await candidateCapture.cancel();
        if (liveStream === candidateStream) liveStream = null;
        if (pcmCapture === candidateCapture) pcmCapture = null;
      }
    },
  });

  try {
    recordingRequestId = requestId;
    recordingMode = mode;
    recordingAllowsCloudFallback = allowsCloudFallback;
    liveStream = candidateStream;
    const streamStart = candidateStream?.start() ?? Promise.resolve(false);
    await recorder.start();
    if (candidateCapture !== null && candidateStream !== null) {
      void streamStart.then((available) => {
        if (available || liveStream !== candidateStream) return;
        candidateStream.cancel();
        void candidateCapture.cancel();
        liveStream = null;
        if (pcmCapture === candidateCapture) pcmCapture = null;
      });
    }
    state.recording = true;
    state.recordingStarting = false;
    state.problem = null;
    state.elapsedMs = 0;
    state.liveText = "";
    renderRecord();
  } catch {
    candidateStream?.cancel();
    void candidateCapture?.cancel();
    recorder = null;
    liveStream = null;
    pcmCapture = null;
    recordingRequestId = null;
    recordingMode = null;
    recordingAllowsCloudFallback = null;
    state.recordingStarting = false;
    state.recording = false;
    toast("Microphone is blocked");
    renderRecord();
  }
}

async function stopRecording() {
  if (recorder === null) return;
  const active = recorder;
  const activeCapture = pcmCapture;
  const activeStream = liveStream;
  const requestId = recordingRequestId ?? randomUuid();
  const mode = recordingMode ?? (state.cleanUp ? "clean" : "literal");
  const allowsCloudFallback = recordingAllowsCloudFallback ?? state.allowCloudFallback;
  recorder = null;
  pcmCapture = null;
  liveStream = null;
  recordingRequestId = null;
  recordingMode = null;
  recordingAllowsCloudFallback = null;
  state.recording = false;
  state.transcribing = true;
  state.problem = null;
  renderRecord();

  let recording;
  try {
    await activeCapture?.stop();
    recording = await active.stop();
  } catch {
    activeStream?.cancel();
    state.elapsedMs = 0;
    state.liveText = "";
    state.transcribing = false;
    toast("That recording was empty");
    renderRecord();
    return;
  }
  if (recording === null) {
    activeStream?.cancel();
    state.transcribing = false;
    state.liveText = "";
    renderRecord();
    return;
  }

  recovery.retain({ recording, requestId, mode, allowCloudFallback: allowsCloudFallback });
  await submitPendingRecording(activeStream);
}

async function submitPendingRecording(activeStream = null) {
  if (recovery.pending === null || recovery.busy || state.removingAll) return;
  const { requestId, mode } = recovery.pending;
  state.transcribing = true;
  state.problem = null;
  renderRecord();
  try {
    const response = await recovery.submit(async (pending, signal) => {
      const cancelStream = () => activeStream?.cancel();
      signal.addEventListener("abort", cancelStream, { once: true });
      try {
        let result = activeStream === null ? null : await activeStream.finish(pending.recording.durationSeconds);
        if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
        if (result !== null) return result;
        if (!isGatewayCompatible(pending.recording.mimeType)) {
          throw new ApiError(ERROR_UNSUPPORTED_AUDIO, "Unsupported recording");
        }
        return await api.transcribe({
          blob: pending.recording.blob,
          mimeType: pending.recording.mimeType,
          durationSeconds: pending.recording.durationSeconds,
          mode: pending.mode,
          allowCloudFallback: pending.allowCloudFallback,
          requestId: pending.requestId,
          signal,
        });
      } finally {
        signal.removeEventListener("abort", cancelStream);
      }
    });
    await acceptTranscription(response, requestId, mode);
  } catch (error) {
    state.elapsedMs = 0;
    state.transcribing = false;
    state.problem = error?.name === "AbortError" || error?.code === "REQUEST_CANCELLED"
      ? { text: "Transcription cancelled. Your recording is still here.", label: null, run: null }
      : describeProblem(error);
    render();
  }
}

async function acceptTranscription(response, requestId, mode) {
  const historyState = typeof response.history_state === "string"
    ? response.history_state
    : "disabled";
  const savedOnMac = historyState === "saved_on_mac";
  const createdAt = new Date().toISOString();
  const text = typeof response.text === "string" ? response.text : "";
  const entry = {
    id: typeof response.request_id === "string" ? response.request_id : requestId,
    created_at: createdAt,
    updated_at: createdAt,
    source_kind: "iphone_pwa",
    mode,
    raw_text: text,
    polished_text: null,
    user_edited_text: null,
    display_text: text,
    destination_display_name: null,
    remote_route: typeof response.route === "string" ? response.route : null,
    cleanup_backend: typeof response.cleanup === "string" ? response.cleanup : null,
    is_pinned: false,
    entry_revision: 0,
    local_state: savedOnMac ? "awaiting_sync" : "awaiting_import",
  };

  // Make the successful transcript immediately available even if IndexedDB
  // subsequently fails. The diagnostics event never includes `entry` or text.
  state.result = entry;
  state.lastRoute = entry.remote_route;
  state.elapsedMs = 0;
  state.liveText = "";

  const persistenceStartedAt = Date.now();
  try {
    await saveTranscript(state.handle, entry, savedOnMac);
    if (historyState === "disabled") state.historyDisabled = true;

    await db.setSetting(state.handle, db.SETTING_LAST_ROUTE, entry.remote_route);
    await reload();
    void recordDiagnostic({
      operation: "transcription",
      phase: "local_history",
      outcome: "succeeded",
      requestId: entry.id,
      code: "OK",
      route: entry.remote_route ?? "none",
      latencyMs: Date.now() - persistenceStartedAt,
    });
  } catch {
    void recordDiagnostic({
      operation: "transcription",
      phase: "local_history",
      outcome: "failed",
      requestId: entry.id,
      code: "LOCAL_HISTORY_SAVE_FAILED",
      route: entry.remote_route ?? "none",
      latencyMs: Date.now() - persistenceStartedAt,
    });
    state.transcribing = false;
    state.problem = {
      text: "Your words were transcribed, but this phone could not save them.",
      label: "Copy diagnostics",
      run: () => void copySafeDiagnostics(),
      reference: `Request ${entry.id.slice(0, 8)}`,
    };
    render();
    return;
  }

  state.transcribing = false;
  render();
  void sync({ silent: true });
}

/* ------------------------------------------------------------- entry edits */

async function saveEdit(entry) {
  if (state.removingAll) return;
  const text = state.editDraft;
  const generation = editGeneration;
  try {
    await changeEntry(state.handle, entry, "edit", text);
    if (generation === editGeneration && state.detailId === entry.id && state.editDraft === text) {
      state.editing = false;
      state.editDraft = "";
      state.showOriginal = false;
    }
    await reload();
    render();
    void sync({ silent: true });
  } catch {
    toast("Your change could not be saved. Keep this page open and try again.");
  }
}

async function togglePin(entry) {
  if (state.removingAll) return;
  try {
    await changeEntry(state.handle, entry, "pin", entry.is_pinned !== true);
    await reload();
    render();
    void sync({ silent: true });
  } catch { toast("Your change could not be saved. Try again."); }
}

async function deleteEntry(entry) {
  if (state.removingAll) return;
  try {
    await changeEntry(state.handle, entry, "delete");
    state.askDelete = false;
    if (state.result?.id === entry.id) state.result = null;
    await reload();
    closeDetail();
    toast("Deletion saved on this phone");
    void sync({ silent: true });
  } catch { toast("Your change could not be saved. Try again."); }
}

async function keepMine(operation) {
  const serverRevision = operation.server_entry?.entry_revision;
  if (typeof serverRevision !== "number") {
    await db.removeOperation(state.handle, operation.op_id);
  } else {
    await db.updateOperation(state.handle, operation.op_id, {
      conflict: 0,
      server_entry: null,
      base_revision: serverRevision,
    });
  }
  await reload();
  render();
  void sync({ silent: true });
}

async function useMacs(operation) {
  await db.discardEntryOperations(state.handle, operation.entry_id, operation.server_entry);
  await reload();
  render();
}

/* ------------------------------------------------------------------ import */

async function storeImport(meta, text) {
  const entry = entryFromImport(meta, text);
  await saveTranscript(state.handle, entry, false);
}

async function importFromClipboard() {
  const meta = state.clipboardImport;
  if (meta === null) return;

  let text = "";
  try {
    text = await navigator.clipboard.readText();
  } catch {
    toast("Could not read the clipboard");
    return;
  }

  if (typeof text !== "string" || text.trim() === "") {
    toast("The clipboard was empty");
    return;
  }

  await storeImport(meta, text.slice(0, MAX_IMPORT_CHARACTERS));
  state.clipboardImport = null;
  await reload();
  render();
  toast("Saved from Shortcut");
  void sync({ silent: true });
}

/**
 * Consume an `/app/import` fragment before the first render, then rewrite the
 * URL so the transcript never lingers in the address bar or in history.
 */
async function consumeImportRoute() {
  if (window.location.pathname !== "/app/import" && window.location.pathname !== "/app/import/") {
    return null;
  }

  let message = null;
  const result = parseImportFragment(window.location.hash);
  if (result.ok && result.kind === "text") {
    try {
      await storeImport(result.meta, result.text);
      message = "Saved from Shortcut";
    } catch {
      message = "That transcript could not be saved";
    }
  } else if (result.ok) {
    state.clipboardImport = result.meta;
  } else if (result.reason !== "empty") {
    message = importErrorMessage(result.reason);
  }

  window.history.replaceState(null, "", "/app/");
  return message;
}

/* ---------------------------------------------------------------- clipboard */

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    state.copyFallbackText = text;
    renderSetup();
    return false;
  }
}

function exportEntries() {
  const payload = {
    exported_at: new Date().toISOString(),
    entries: searchEntries(combinedEntries(), ""),
  };
  const blob = new Blob([JSON.stringify(payload, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const link = el("a");
  link.href = url;
  link.download = `dictation-${new Date().toISOString().slice(0, 10)}.json`;
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

async function copyAll() {
  const text = searchEntries(combinedEntries(), "")
    .map((entry) => displayTextOf(entry))
    .join("\n\n");
  if (await copyText(text)) toast("Copied");
}

async function copySafeDiagnostics() {
  if (await copyText(await formatDiagnostics())) toast("Diagnostics copied");
}

async function clearSafeDiagnostics() {
  await clearDiagnostics();
  state.diagnosticCount = 0;
  state.testResult = null;
  renderSettings();
  toast("Diagnostics cleared");
}

async function refreshSafeDiagnostics() {
  state.diagnosticCount = (await listDiagnostics()).length;
  renderSettings();
}

async function clearHistory() {
  state.askClear = false;
  await db.clearLocalCache(state.handle);
  await reload();
  state.result = null;
  render();
  toast("Refreshing saved copy");
  void sync({ silent: true });
}

async function removeAllPhoneData() {
  if (state.recording || state.recordingStarting || state.transcribing || recovery.pending !== null) {
    toast("Finish or discard your recording first.");
    return;
  }
  state.removingAll = true;
  try {
    // Let any already-started sync settle before clearing; it must not refill
    // this phone after the user has removed its data.
    await syncTask;
    await db.clearAllDeviceData(state.handle);
    await clearDiagnostics();
    state.credentials = null;
    state.result = null;
    state.copyFallbackText = null;
    state.editDraft = "";
    state.editing = false;
    state.detailId = null;
    state.clipboardImport = null;
    state.askRemoveAll = false;
    state.problem = null;
    state.historyDisabled = false;
    state.diagnosticCount = 0;
    await reload();
    closeSettings();
    toast("All phone data removed");
  } catch { toast("Some phone data could not be removed. Try again."); }
  finally { state.removingAll = false; render(); }
}

/* ---------------------------------------------------------------- settings */

async function saveCredentials(clientId, clientSecret) {
  if (state.removingAll) return;
  if (clientId === "" || clientSecret === "") {
    toast("Both lines are needed");
    return;
  }
  await db.setSetting(state.handle, db.SETTING_CREDENTIALS, { clientId, clientSecret });
  state.credentials = { clientId, clientSecret };
  state.problem = null;
  state.testResult = null;
  closeSettings();
  toast("Connected");
  void sync({ silent: true });
}

async function clearCredentials() {
  if (state.removingAll) return;
  await db.deleteSetting(state.handle, db.SETTING_CREDENTIALS);
  state.credentials = null;
  state.testResult = null;
  toast("Key removed");
  render();
}

async function setCleanUp(on) {
  if (state.removingAll) return;
  state.cleanUp = on;
  await db.setSetting(state.handle, db.SETTING_DEFAULT_MODE, on ? "clean" : "literal");
}

async function setAllowCloudFallback(allow) {
  if (state.removingAll) return;
  state.allowCloudFallback = allow;
  await db.setSetting(state.handle, db.SETTING_ALLOW_CLOUD_FALLBACK, allow);
}

async function testConnection() {
  if (state.credentials === null) {
    state.testResult = { ok: false, reason: "Add your key first." };
    renderSettings();
    return;
  }
  try {
    await api.healthz();
    state.testResult = { ok: true };
  } catch (error) {
    state.testResult = { ok: false, reason: describeProblem(error).text };
  }
  renderSettings();
}

/* ------------------------------------------------------------- navigation */

function openDetail(id, { edit = false } = {}) {
  editGeneration += 1;
  state.detailId = id;
  state.editing = edit;
  state.editDraft = edit ? displayTextOf(findEntry(id)) : "";
  state.showOriginal = false;
  state.askDelete = false;
  renderDetail();
  renderGlobalControls();
  window.scrollTo(0, 0);
}

function closeDetail() {
  editGeneration += 1;
  state.detailId = null;
  state.editing = false;
  state.editDraft = "";
  state.showOriginal = false;
  state.askDelete = false;
  dom.detail.hidden = true;
  clear(dom.detail);
  dom.main.hidden = false;
  render();
}

function openSettings() {
  state.askClear = false;
  state.showSecret = false;
  state.testResult = null;
  dom.settings.hidden = false;
  dom.main.hidden = true;
  dom.detail.hidden = true;
  renderSettings();
  renderGlobalControls();
  void refreshSafeDiagnostics();
  window.scrollTo(0, 0);
}

function closeSettings() {
  dom.settings.hidden = true;
  clear(dom.settings);
  dom.main.hidden = false;
  render();
}

/* --------------------------------------------------------------- listeners */

function wireEvents() {
  dom.copyRecovery.addEventListener("cancel", () => { state.copyFallbackText = null; });
  dom.recordButton.addEventListener("click", () => {
    if (state.recording) void stopRecording();
    else void startRecording();
  });
  dom.search.addEventListener("input", () => {
    state.query = dom.search.value;
    renderList();
  });
  dom.settingsButton.addEventListener("click", openSettings);

  window.addEventListener("beforeunload", event => {
    if (state.recording || state.recordingStarting || recovery.pending !== null || state.editing) {
      event.preventDefault();
      event.returnValue = "";
    }
  });

  window.addEventListener("online", () => {
    state.online = true;
    renderRecord();
    void sync({ silent: true });
  });
  window.addEventListener("offline", () => {
    state.online = false;
    renderRecord();
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void sync({ silent: true });
  });
}

function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) return;

  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (updateRequested && updateIsSafe()) window.location.reload();
  });
  const register = () => {
    navigator.serviceWorker
      .register("/app/sw.js", { type: "module", scope: "/app/", updateViaCache: "none" })
      .then(registration => {
        waitingWorker = registration.waiting;
        renderGlobalControls();
        registration.addEventListener("updatefound", () => {
          const installing = registration.installing;
          installing?.addEventListener("statechange", () => {
            if (installing.state === "installed" && navigator.serviceWorker.controller) {
              waitingWorker = registration.waiting;
              renderGlobalControls();
            }
          });
        });
      })
      .catch(() => { /* Offline shell updates can wait. */ });
  };

  // Boot is async, so `load` has usually already fired by the time we get here.
  if (document.readyState === "complete") register();
  else window.addEventListener("load", register, { once: true });
}

/* ------------------------------------------------------------------- boot */

async function boot() {
  try {
    state.handle = await db.openDatabase();
  } catch {
    const card = el("section", "card");
    card.append(el(
      "p",
      null,
      "This browser cannot save anything here. Open the app in Safari without Private Browsing.",
    ));
    dom.setup.append(card);
    return;
  }

  await reload();
  const imported = await consumeImportRoute();
  await reload();

  wireEvents();
  render();
  if (imported !== null) toast(imported);
  registerServiceWorker();

  if (state.credentials !== null) void sync({ silent: true });
}

void boot();
