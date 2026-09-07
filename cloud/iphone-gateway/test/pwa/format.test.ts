import { describe, expect, it } from "vitest";
import {
  countLabel,
  deviceLabel,
  displayTextOf,
  formatElapsed,
  formatRelativeTime,
  friendlyTime,
  parseTimestamp,
  previewText,
  redactSecret,
  routeLabel,
  sourceLabel,
} from "../../public/app/lib/format.js";

const NOW = Date.parse("2026-09-06T12:00:00.000Z");

describe("formatRelativeTime", () => {
  it.each([
    ["2026-09-06T11:59:40.000Z", "just now"],
    ["2026-09-06T11:56:00.000Z", "4m ago"],
    ["2026-09-06T09:00:00.000Z", "3h ago"],
    ["2026-09-04T12:00:00.000Z", "2d ago"],
  ])("renders %s as %s", (value, expected) => {
    expect(formatRelativeTime(value, NOW)).toBe(expected);
  });

  it("falls back to a calendar date beyond a week", () => {
    expect(formatRelativeTime("2026-03-04T12:00:00.000Z", NOW)).toMatch(/^[A-Z][a-z]{2} \d{1,2}$/);
  });

  it("treats a future timestamp as just now", () => {
    expect(formatRelativeTime("2026-09-06T12:30:00.000Z", NOW)).toBe("just now");
  });

  it("returns an empty string for junk", () => {
    expect(formatRelativeTime("nonsense", NOW)).toBe("");
    expect(formatRelativeTime(null as any, NOW)).toBe("");
  });
});

describe("parseTimestamp", () => {
  it("returns null rather than NaN", () => {
    expect(parseTimestamp("nope")).toBe(null);
    expect(parseTimestamp("")).toBe(null);
    expect(parseTimestamp("2026-09-06T12:00:00.000Z")).toBe(NOW);
  });
});

describe("sourceLabel and routeLabel", () => {
  it.each([
    ["desktop", "Desktop"],
    ["iphone_shortcut", "Shortcut"],
    ["iphone_pwa", "PWA"],
    ["martian", "Unknown"],
  ])("labels the source %s", (kind, expected) => {
    expect(sourceLabel(kind)).toBe(expected);
  });

  it.each([
    ["mac_local", "Mac"],
    ["cloud_fallback", "Cloud"],
  ])("badges the route %s", (route, expected) => {
    expect(routeLabel(route)).toBe(expected);
  });

  it("returns null for an absent route", () => {
    expect(routeLabel(null)).toBe(null);
    expect(routeLabel("elsewhere")).toBe(null);
  });
});

describe("formatElapsed", () => {
  it.each([
    [0, "00:00"],
    [1500, "00:01"],
    [61_000, "01:01"],
    [600_000, "10:00"],
    [-5, "00:00"],
  ])("renders %s ms as %s", (ms, expected) => {
    expect(formatElapsed(ms)).toBe(expected);
  });
});

describe("previewText", () => {
  it("collapses whitespace and clips long text", () => {
    expect(previewText("  a \n\n b  ")).toBe("a b");
    const long = "x".repeat(200);
    const preview = previewText(long, 20);
    expect(preview.length).toBe(20);
    expect(preview.endsWith("…")).toBe(true);
  });

  it("returns an empty string for a non-string", () => {
    expect(previewText(undefined as any)).toBe("");
  });
});

describe("redactSecret", () => {
  it("keeps only the final four characters", () => {
    expect(redactSecret("abcdefgh1234")).toBe("••••1234");
    expect(redactSecret("")).toBe("");
  });

  it("never leaks the leading characters of the secret", () => {
    const secret = "supersecretvalue9999";
    expect(redactSecret(secret)).not.toContain("supersecret");
  });
});

describe("displayTextOf", () => {
  it("resolves user edit over polished over raw", () => {
    expect(displayTextOf({ raw_text: "r", polished_text: "p", user_edited_text: "u" })).toBe("u");
    expect(displayTextOf({ raw_text: "r", polished_text: "p", user_edited_text: null })).toBe("p");
    expect(displayTextOf({ raw_text: "r", polished_text: null })).toBe("r");
    expect(displayTextOf({ raw_text: "r", polished_text: "p", user_edited_text: "  " })).toBe("p");
    expect(displayTextOf(null)).toBe("");
  });
});

describe("countLabel", () => {
  it("pluralises", () => {
    expect(countLabel(1, "conflict")).toBe("1 conflict");
    expect(countLabel(2, "conflict")).toBe("2 conflicts");
    expect(countLabel(0, "pending op")).toBe("0 pending ops");
  });
});

describe("deviceLabel", () => {
  it.each([
    ["desktop", "Mac"],
    ["iphone_shortcut", "iPhone"],
    ["iphone_pwa", "iPhone"],
  ])("names the device behind %s", (kind, expected) => {
    expect(deviceLabel(kind)).toBe(expected);
  });

  it("says nothing at all for an unknown source", () => {
    expect(deviceLabel("martian")).toBe("");
    expect(deviceLabel(null as any)).toBe("");
  });
});

describe("friendlyTime", () => {
  // Anchored to local noon so the calendar-day branches are timezone-stable.
  const anchor = new Date(2026, 8, 6, 12, 0, 0, 0).getTime();

  function localTime(daysAgo: number, hour: number): string {
    const date = new Date(anchor);
    date.setDate(date.getDate() - daysAgo);
    date.setHours(hour, 0, 0, 0);
    return date.toISOString();
  }

  it("says just now for the last minute and for the future", () => {
    expect(friendlyTime(new Date(anchor - 30_000).toISOString(), anchor)).toBe("Just now");
    expect(friendlyTime(new Date(anchor + 60_000).toISOString(), anchor)).toBe("Just now");
  });

  it("counts minutes in plain words", () => {
    expect(friendlyTime(new Date(anchor - 2 * 60_000).toISOString(), anchor)).toBe("2 min ago");
    expect(friendlyTime(new Date(anchor - 59 * 60_000).toISOString(), anchor)).toBe("59 min ago");
  });

  it("counts hours inside today", () => {
    expect(friendlyTime(localTime(0, 11), anchor)).toBe("1 hour ago");
    expect(friendlyTime(localTime(0, 9), anchor)).toBe("3 hours ago");
  });

  it("names yesterday and the days after it", () => {
    expect(friendlyTime(localTime(1, 12), anchor)).toBe("Yesterday");
    expect(friendlyTime(localTime(1, 1), anchor)).toBe("Yesterday");
    expect(friendlyTime(localTime(3, 12), anchor)).toBe("3 days ago");
  });

  it("falls back to a calendar date beyond a week", () => {
    expect(friendlyTime(localTime(20, 12), anchor)).toMatch(/^[A-Z][a-z]{2} \d{1,2}$/);
  });

  it("returns an empty string for junk", () => {
    expect(friendlyTime("nonsense", anchor)).toBe("");
    expect(friendlyTime(null as any, anchor)).toBe("");
  });

  it("never uses a technical word", () => {
    for (const days of [0, 1, 3, 20]) {
      expect(friendlyTime(localTime(days, 9), anchor)).not.toMatch(/revision|sync|utc/i);
    }
  });
});
