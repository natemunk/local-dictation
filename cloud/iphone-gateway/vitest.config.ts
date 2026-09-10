import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    projects: [
      {
        // Worker tests run inside workerd against wrangler.jsonc.
        plugins: [
          cloudflareTest({
            wrangler: { configPath: "./wrangler.jsonc" },
            // Contract tests inject Mac/AI adapters. Never open a remote binding
            // session or require Cloudflare credentials to run the suite.
            remoteBindings: false,
          }),
        ],
        test: {
          name: "gateway",
          include: ["test/*.test.ts"],
        },
      },
      {
        // PWA module tests run in plain Node with a fake IndexedDB.
        test: {
          name: "pwa",
          environment: "node",
          include: ["test/pwa/**/*.test.ts"],
          setupFiles: ["fake-indexeddb/auto"],
        },
      },
    ],
  },
});
