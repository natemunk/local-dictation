import { describe, expect, it } from "vitest";
import {
  entrySearchText,
  matchesQuery,
  normalizeQuery,
  searchEntries,
  sortNewestFirst,
} from "../../public/app/lib/search.js";

const entries = [
  {
    id: "old",
    created_at: "2026-09-01T10:00:00.000Z",
    source_kind: "desktop",
    remote_route: null,
    raw_text: "Quarterly Revenue Notes",
    polished_text: null,
    user_edited_text: null,
  },
  {
    id: "middle",
    created_at: "2026-09-03T10:00:00.000Z",
    source_kind: "iphone_shortcut",
    remote_route: "cloud_fallback",
    raw_text: "raw grocery list",
    polished_text: "Polished grocery list",
    user_edited_text: null,
  },
  {
    id: "new",
    created_at: "2026-09-05T10:00:00.000Z",
    source_kind: "iphone_pwa",
    remote_route: "mac_local",
    raw_text: "meeting agenda",
    polished_text: "Meeting agenda",
    user_edited_text: "Edited meeting agenda with ACTION items",
  },
];

describe("normalizeQuery", () => {
  it("trims, lowercases and treats blanks as no filter", () => {
    expect(normalizeQuery("  Hello  ")).toBe("hello");
    expect(normalizeQuery("   ")).toBe("");
    expect(normalizeQuery(undefined as any)).toBe("");
  });
});

describe("entrySearchText", () => {
  it("covers raw, polished, edited text and the labels", () => {
    const text = entrySearchText(entries[2]);
    expect(text).toContain("meeting agenda");
    expect(text).toContain("edited meeting agenda");
    expect(text).toContain("pwa");
    expect(text).toContain("mac");
  });

  it("returns an empty string for a non-entry", () => {
    expect(entrySearchText(null)).toBe("");
    expect(entrySearchText(undefined)).toBe("");
  });
});

describe("searchEntries", () => {
  it("returns everything newest first for an empty query", () => {
    expect(searchEntries(entries, "").map((entry: any) => entry.id))
      .toEqual(["new", "middle", "old"]);
  });

  it("is case-insensitive", () => {
    expect(searchEntries(entries, "REVENUE").map((entry: any) => entry.id)).toEqual(["old"]);
    expect(searchEntries(entries, "action").map((entry: any) => entry.id)).toEqual(["new"]);
  });

  it("matches raw text that the polished text hides", () => {
    expect(searchEntries(entries, "raw grocery").map((entry: any) => entry.id))
      .toEqual(["middle"]);
  });

  it("matches source and route labels", () => {
    expect(searchEntries(entries, "shortcut").map((entry: any) => entry.id)).toEqual(["middle"]);
    expect(searchEntries(entries, "cloud").map((entry: any) => entry.id)).toEqual(["middle"]);
  });

  it("returns nothing when there is no match", () => {
    expect(searchEntries(entries, "zzzz")).toEqual([]);
  });

  it("tolerates a non-array input", () => {
    expect(searchEntries(null as any, "anything")).toEqual([]);
  });

  it("does not mutate the caller's array", () => {
    const copy = [...entries];
    searchEntries(entries, "");
    expect(entries).toEqual(copy);
  });
});

describe("sortNewestFirst", () => {
  it("falls back to the id when timestamps tie", () => {
    const tied = [
      { id: "a", created_at: "2026-09-05T10:00:00.000Z" },
      { id: "b", created_at: "2026-09-05T10:00:00.000Z" },
    ];
    expect(sortNewestFirst(tied).map((entry: any) => entry.id)).toEqual(["b", "a"]);
  });

  it("sorts entries with unparseable timestamps last", () => {
    const messy = [
      { id: "bad", created_at: "nonsense" },
      { id: "good", created_at: "2026-09-05T10:00:00.000Z" },
    ];
    expect(sortNewestFirst(messy).map((entry: any) => entry.id)).toEqual(["good", "bad"]);
  });
});

describe("matchesQuery", () => {
  it("matches everything on an empty query", () => {
    expect(matchesQuery(entries[0], "")).toBe(true);
  });
});
