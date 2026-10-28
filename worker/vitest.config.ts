import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.test.toml" },
        // Per-test storage isolation breaks on nested SELF.fetch() calls;
        // tests are written to coexist on the shared local R2 state instead.
        isolatedStorage: false,
      },
    },
  },
});
