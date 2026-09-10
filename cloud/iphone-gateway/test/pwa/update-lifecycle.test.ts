import { readFileSync } from "node:fs";
import vm from "node:vm";
import { describe, expect, it, vi } from "vitest";
import * as routing from "../../public/app/lib/sw-routing.js";

describe("shell update activation", () => {
  it("caches a waiting release without activating until the idle page requests it", async () => {
    const events: Record<string, any> = {};
    const skipWaiting = vi.fn(async () => {});
    const addAll = vi.fn(async () => {});
    const source = readFileSync(new URL("../../public/app/sw.js", import.meta.url), "utf8")
      .replace(/^import[\s\S]*?;\n/gm, "");
    vm.runInNewContext(source, { ...routing,
      self: { addEventListener: (name: string, fn: any) => { events[name] = fn; }, skipWaiting },
      caches: { open: async () => ({ addAll }) },
    });
    let pending: Promise<void> = Promise.resolve();
    const event = (data?: any) => ({ data, waitUntil: (promise: Promise<void>) => { pending = promise; } });
    events.install(event()); await pending;
    expect(addAll).toHaveBeenCalledWith(routing.SHELL_ASSETS);
    expect(skipWaiting).not.toHaveBeenCalled();
    events.message(event({ type: "ACTIVATE_UPDATE" })); await pending;
    expect(skipWaiting).toHaveBeenCalledTimes(1);
  });
});
