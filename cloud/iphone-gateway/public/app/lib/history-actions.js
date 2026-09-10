// User actions share one durable path, including results not yet in a snapshot.
import * as defaultDb from "./db.js";
import { buildEditOperation, buildPinOperation, buildDeleteOperation, buildImportOperation } from "./sync.js";

export async function saveTranscript(database, entry, savedOnMac, db = defaultDb) {
  return db.putPendingWithOperation(database, entry, savedOnMac ? null : buildImportOperation(entry));
}

export async function changeEntry(database, entry, type, value, db = defaultDb) {
  // A fresh Mac result was inserted at revision 1. Imports obtain the revision
  // from their acknowledgement, never by changing a request already in flight.
  const base = { ...entry, entry_revision: entry.entry_revision > 0
    ? entry.entry_revision : (entry.local_state === "awaiting_sync" ? 1 : null) };
  const operation = type === "edit" ? buildEditOperation(base, value)
    : type === "delete" ? buildDeleteOperation(base) : buildPinOperation(base, value);
  return db.queueEntryMutation(database, entry, operation);
}

/** Overlay durable local intent even while a new server snapshot replaces cache. */
export function visibleEntries(entries, pending, operations) {
  const byId = new Map(entries.map(entry => [entry.id, { ...entry }]));
  for (const entry of pending) if (!byId.has(entry.id)) byId.set(entry.id, { ...entry });
  for (const operation of [...operations].sort((a, b) => a.seq - b.seq)) {
    const entry = byId.get(operation.entry_id);
    if (!entry) continue;
    if (operation.type === "edit") {
      entry.user_edited_text = operation.text.trim() === "" ? null : operation.text;
      entry.display_text = entry.user_edited_text ?? entry.polished_text ?? entry.raw_text;
    } else if (operation.type === "pin" || operation.type === "unpin") {
      entry.is_pinned = operation.type === "pin";
    } else if (operation.type === "delete" && operation.conflict !== 1) {
      byId.delete(entry.id);
    }
  }
  return [...byId.values()];
}
