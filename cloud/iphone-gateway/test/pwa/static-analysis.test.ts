import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { SHELL_ASSETS } from "../../public/app/lib/sw-routing.js";

const APP_ROOT = fileURLToPath(new URL("../../public/app", import.meta.url));

const BINARY_EXTENSIONS = new Set([".png", ".jpg", ".ico", ".webp"]);

function walk(directory: string): string[] {
  const found: string[] = [];
  for (const name of readdirSync(directory)) {
    const full = join(directory, name);
    if (statSync(full).isDirectory()) found.push(...walk(full));
    else found.push(full);
  }
  return found.sort();
}

const allFiles = walk(APP_ROOT);
const textFiles = allFiles.filter(
  (file) => !BINARY_EXTENSIONS.has(file.slice(file.lastIndexOf("."))),
);
const htmlFiles = allFiles.filter((file) => file.endsWith(".html"));

function read(file: string): string {
  return readFileSync(file, "utf8");
}

function label(file: string): string {
  return relative(APP_ROOT, file);
}

describe("content security", () => {
  it("finds the shipped files", () => {
    expect(textFiles.length).toBeGreaterThan(5);
    expect(htmlFiles.length).toBe(1);
  });

  it.each([
    "innerHTML",
    "outerHTML",
    "insertAdjacentHTML",
    "document.write",
    "eval(",
    "new Function",
  ])("never uses %s", (pattern) => {
    const offenders = textFiles.filter((file) => read(file).includes(pattern)).map(label);
    expect(offenders).toEqual([]);
  });

  it("has no absolute http or https url anywhere", () => {
    const offenders = textFiles
      .filter((file) => /https?:\/\//.test(read(file)))
      .map(label);
    expect(offenders).toEqual([]);
  });

  it("has no inline script in the shell", () => {
    for (const file of htmlFiles) {
      const source = read(file);
      const scripts = source.match(/<script\b[^>]*>/gi) ?? [];
      for (const tag of scripts) {
        expect(tag, `${label(file)}: ${tag}`).toMatch(/\bsrc=/);
      }
      expect(source).not.toMatch(/<script\b[^>]*>[^<\s]/i);
      expect(source).not.toMatch(/<style\b/i);
    }
  });

  it("has no inline style attribute and no inline event handler in the shell", () => {
    for (const file of htmlFiles) {
      const source = read(file);
      expect(source, label(file)).not.toMatch(/\sstyle\s*=\s*"/i);
      expect(source, label(file)).not.toMatch(/\son[a-z]+\s*=\s*"/i);
    }
  });
});

describe("privacy", () => {
  it("never uses web storage outside IndexedDB", () => {
    const offenders = textFiles
      .filter((file) => /\b(localStorage|sessionStorage|document\.cookie)\b/.test(read(file)))
      .map(label);
    expect(offenders).toEqual([]);
  });

  it("never logs to the console", () => {
    const offenders = textFiles
      .filter((file) => /\bconsole\.(log|info|warn|error|debug)\s*\(/.test(read(file)))
      .map(label);
    expect(offenders).toEqual([]);
  });

  it("never writes a recording into a store", () => {
    const recorderSource = read(join(APP_ROOT, "lib", "recorder.js"));
    expect(recorderSource).not.toContain("indexedDB");
    expect(recorderSource).not.toContain("putPendingEntry");

    const appSource = read(join(APP_ROOT, "app.js"));
    expect(appSource).not.toMatch(/put(Pending|Synchronized|Staged)[A-Za-z]*\([^)]*blob/i);
  });
});

describe("service worker precache", () => {
  it("lists every shipped shell file except the worker itself", () => {
    const shipped = allFiles
      .map((file) => `/app/${relative(APP_ROOT, file).split("\\").join("/")}`)
      .filter((path) => path !== "/app/sw.js");
    expect([...SHELL_ASSETS].sort()).toEqual(shipped.sort());
  });
});
