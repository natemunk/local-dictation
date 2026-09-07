import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ENTRY = resolve(__dirname, "../../src/index.ts");

describe("worker entry module", () => {
  it("exports only the default fetch handler", () => {
    // workerd validates every named export of the main module as a handler or
    // class and refuses to start otherwise. `wrangler deploy --dry-run` does
    // not execute the module, so this file-level check is the automated guard.
    const source = readFileSync(ENTRY, "utf8");
    const namedExports = source.match(/^export\s+(?!default\b)[a-z]+\s+\w+/gm) ?? [];
    expect(namedExports).toEqual([]);
    expect(source).toMatch(/^export default \{/m);
  });
});
