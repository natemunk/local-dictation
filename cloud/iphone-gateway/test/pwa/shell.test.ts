import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const APP_ROOT = fileURLToPath(new URL("../../public/app/", import.meta.url));

const html = readFileSync(`${APP_ROOT}index.html`, "utf8");
const css = readFileSync(`${APP_ROOT}app.css`, "utf8");
const js = readFileSync(`${APP_ROOT}app.js`, "utf8");

/**
 * Words the UX contract forbids in anything a person can read. The list is the
 * one written into docs/unified-history.md section 5.
 */
const JARGON_WORDS =
  /\b(revision|indexeddb|dto|conflict|gateway|payload|operation|queue|fragment|token|http)\b/i;

/** The same words plus a bare status code, for prose the app speaks. */
const JARGON = new RegExp(`${JARGON_WORDS.source}|\\b\\d{3}\\b`, "i");

/**
 * Double-quoted literals that read like a sentence or a label: long enough to
 * be prose and containing a space. Class names, module specifiers and enum
 * values are all shorter or space-free. The source uses double quotes only, so
 * splitting on the quote character pairs the literals correctly.
 */
function proseLiterals(source: string): string[] {
  const parts = source.split('"');
  const found: string[] = [];
  for (let index = 1; index < parts.length; index += 2) {
    const value = parts[index];
    if (value.length >= 13 && value.includes(" ")) found.push(value);
  }
  return found;
}

describe("the shell is one screen", () => {
  it("has a header with the app name and a single settings control", () => {
    expect(html).toMatch(/<h1 class="bar-title">Dictation<\/h1>/);
    expect(html).toContain('id="settings-button"');
    expect(html).toContain('aria-label="Settings"');
  });

  it("has exactly one record control with its own status line", () => {
    expect(html.match(/id="record-button"/g)).toHaveLength(1);
    expect(html).toContain('id="record-timer"');
    expect(html).toContain('id="record-status"');
  });

  it("keeps the result, the list and the two sheets", () => {
    for (const id of ["result-region", "entry-list", "search-input", "detail-view", "settings-view", "toast"]) {
      expect(html, id).toContain(`id="${id}"`);
    }
  });

  it("no longer ships a chip row, a mode picker or a toolbar", () => {
    for (const gone of ["status-chips", "mode-clean", "mode-literal", "fallback-toggle", "toolbar", "copy-all-button"]) {
      expect(html, gone).not.toContain(gone);
    }
  });

  it("labels the search field with the single word Search", () => {
    expect(html).toContain('placeholder="Search"');
  });

  it("hides the search field and the record button until the app decides", () => {
    expect(html).toMatch(/id="search-input"[\s\S]*?hidden/);
    expect(html).toMatch(/id="record-region"[\s\S]*?hidden/);
  });
});

describe("the record button is enormous and round", () => {
  it("is at least 45% of the viewport and never below 200px", () => {
    expect(css).toContain("width: max(200px, 45vw)");
    expect(css).toMatch(/\.record-button[\s\S]*?border-radius: 50%/);
  });

  it("turns red and pulses while recording", () => {
    expect(css).toMatch(/\.record-button\.on[\s\S]*?var\(--danger\)/);
    expect(css).toContain("@keyframes pulse");
  });

  it("respects the safe area and both colour schemes", () => {
    expect(css).toContain("env(safe-area-inset-top");
    expect(css).toContain("env(safe-area-inset-bottom");
    expect(css).toContain("prefers-color-scheme: dark");
  });

  it("keeps touch targets at 48px", () => {
    expect(css).toContain("--tap: 48px");
  });
});

describe("the words a person reads", () => {
  it("never uses a technical word in the shell", () => {
    expect(html).not.toMatch(JARGON_WORDS);
  });

  it("never uses a technical word in a sentence the app shows", () => {
    const offenders = proseLiterals(js).filter((value) => JARGON.test(value));
    expect(offenders).toEqual([]);
  });

  it("says the plain-language status lines", () => {
    for (const line of ["Ready", "Recording…", "Transcribing…", "Syncing…", "Offline · showing saved history"]) {
      expect(js, line).toContain(line);
    }
  });

  it("marks entries the Mac has not seen in plain words", () => {
    expect(js).toContain("not yet on Mac");
  });

  it("confirms a delete exactly once, in plain words", () => {
    expect(js).toContain("Delete this?");
  });

  it("explains a sync disagreement without naming it", () => {
    expect(js).toContain("This was also changed on your Mac.");
    expect(js).toContain("Keep mine");
    expect(js).toContain("Use Mac's");
  });

  it("confirms a copy for a moment", () => {
    expect(js).toContain("Copied ✓");
  });

  it("greets a new phone with one setup card", () => {
    expect(js).toContain("Connect to your Mac");
  });

  it("says where a shortcut import went", () => {
    expect(js).toContain("Saved from Shortcut");
  });
});
