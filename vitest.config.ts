import { defineConfig } from "vitest/config";

// ルート vitest は tools/*.test.mjs だけを対象にする。
// worker のテストは worker/vitest.config.ts（Workers Pool）が別経路で受け持つ。
export default defineConfig({
  test: {
    environment: "node",
    include: ["tools/**/*.test.mjs"],
  },
});
