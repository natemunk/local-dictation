import { describe, expect, it } from "vitest";
import {
  MAX_FRAGMENT_TEXT_CHARACTERS,
  entryFromImport,
  importErrorMessage,
  parseImportFragment,
} from "../../public/app/lib/fragment.js";

const ID = "6f1d2c3e-1111-4222-8333-444455556666";
const TS = "2026-09-06T17:20:00.000Z";

function fragment(overrides: Record<string, string | null> = {}): string {
  const base: Record<string, string | null> = {
    v: "1",
    id: ID,
    ts: TS,
    mode: "clean",
    route: "cloud_fallback",
    client: "shortcut",
    text: "hello there",
  };
  const merged = { ...base, ...overrides };
  const parts: string[] = [];
  for (const [key, value] of Object.entries(merged)) {
    if (value === null) continue;
    parts.push(`${key}=${encodeURIComponent(value)}`);
  }
  return `#${parts.join("&")}`;
}

describe("parseImportFragment", () => {
  it("accepts a well-formed inline transcript", () => {
    const result = parseImportFragment(fragment());
    expect(result).toEqual({
      ok: true,
      kind: "text",
      meta: {
        id: ID,
        created_at: TS,
        mode: "clean",
        route: "cloud_fallback",
        source_kind: "iphone_shortcut",
      },
      text: "hello there",
    });
  });

  it("accepts a fragment without the leading hash", () => {
    expect(parseImportFragment(fragment().slice(1)).ok).toBe(true);
  });

  it("maps the pwa client to its own source kind", () => {
    const result: any = parseImportFragment(fragment({ client: "pwa" }));
    expect(result.meta.source_kind).toBe("iphone_pwa");
  });

  it("normalises a timestamp with an offset to UTC", () => {
    const result: any = parseImportFragment(fragment({ ts: "2026-09-06T19:20:00+02:00" }));
    expect(result.meta.created_at).toBe("2026-09-06T17:20:00.000Z");
  });

  it("recognises clipboard mode and ignores any inline text", () => {
    const result = parseImportFragment(fragment({ clipboard: "1", text: null }));
    expect(result).toMatchObject({ ok: true, kind: "clipboard" });
    expect(result).not.toHaveProperty("text");
  });

  it("rejects an oversized transcript", () => {
    const long = "a".repeat(MAX_FRAGMENT_TEXT_CHARACTERS + 1);
    expect(parseImportFragment(fragment({ text: long })))
      .toEqual({ ok: false, reason: "text_too_long" });
  });

  it("accepts a transcript of exactly the maximum length", () => {
    const exact = "a".repeat(MAX_FRAGMENT_TEXT_CHARACTERS);
    expect(parseImportFragment(fragment({ text: exact })).ok).toBe(true);
  });

  it.each([
    ["v", "unsupported_version"],
    ["id", "invalid_id"],
    ["ts", "invalid_timestamp"],
    ["mode", "invalid_mode"],
    ["route", "invalid_route"],
    ["client", "invalid_client"],
    ["text", "missing_text"],
  ])("rejects a fragment missing %s", (field, reason) => {
    expect(parseImportFragment(fragment({ [field]: null })))
      .toEqual({ ok: false, reason });
  });

  it.each([
    ["not-a-uuid", "invalid_id"],
    ["6F1D2C3E-1111-4222-8333-44445555666", "invalid_id"],
  ])("rejects the bad uuid %s", (id, reason) => {
    expect(parseImportFragment(fragment({ id }))).toEqual({ ok: false, reason });
  });

  it("uppercases a valid uuid down to lowercase", () => {
    const result: any = parseImportFragment(fragment({ id: ID.toUpperCase() }));
    expect(result.meta.id).toBe(ID);
  });

  it.each([
    ["2026-09-06 17:20:00"],
    ["yesterday"],
    ["2026-09-06T17:20:00"],
  ])("rejects the bad timestamp %s", (ts) => {
    expect(parseImportFragment(fragment({ ts }))).toEqual({
      ok: false,
      reason: "invalid_timestamp",
    });
  });

  it("rejects an unknown mode and an unknown route", () => {
    expect(parseImportFragment(fragment({ mode: "polished" })))
      .toEqual({ ok: false, reason: "invalid_mode" });
    expect(parseImportFragment(fragment({ route: "somewhere" })))
      .toEqual({ ok: false, reason: "invalid_route" });
  });

  it("rejects whitespace-only text", () => {
    expect(parseImportFragment(fragment({ text: "   " })))
      .toEqual({ ok: false, reason: "missing_text" });
  });

  it.each([
    ["", "empty"],
    ["#", "empty"],
    ["#garbage", "malformed"],
    ["#v=1&text=%E0%A4%A", "malformed"],
  ])("never throws on the garbage input %s", (hash, reason) => {
    expect(parseImportFragment(hash)).toEqual({ ok: false, reason });
  });

  it.each([null, undefined, 12, {}])("never throws on the non-string input %s", (value) => {
    expect(parseImportFragment(value as any)).toEqual({ ok: false, reason: "malformed" });
  });

  it("refuses a fragment beyond the defensive length ceiling", () => {
    expect(parseImportFragment(`#${"a".repeat(200_001)}`))
      .toEqual({ ok: false, reason: "text_too_long" });
  });
});

describe("entryFromImport", () => {
  it("builds a pending entry that carries no polish and no revision", () => {
    const parsed: any = parseImportFragment(fragment());
    const entry = entryFromImport(parsed.meta, parsed.text);

    expect(entry).toMatchObject({
      id: ID,
      created_at: TS,
      updated_at: TS,
      source_kind: "iphone_shortcut",
      mode: "clean",
      raw_text: "hello there",
      polished_text: null,
      user_edited_text: null,
      remote_route: "cloud_fallback",
      is_pinned: false,
      entry_revision: 0,
      local_state: "awaiting_import",
    });
  });

  it("tolerates a missing clipboard payload", () => {
    const parsed: any = parseImportFragment(fragment({ clipboard: "1", text: null }));
    expect(entryFromImport(parsed.meta, undefined).raw_text).toBe("");
  });
});

describe("importErrorMessage", () => {
  it("stays non-technical for every reason", () => {
    for (const reason of ["malformed", "invalid_id", "text_too_long", "empty"]) {
      const message = importErrorMessage(reason);
      expect(message.length).toBeGreaterThan(10);
      expect(message).not.toMatch(/uuid|fragment|parse|null/i);
    }
  });
});
