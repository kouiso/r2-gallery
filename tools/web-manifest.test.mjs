import { readFileSync } from "node:fs";
import { expect, it } from "vitest";

it("loads the web manifest with credentials behind Cloudflare Access", () => {
  const html = readFileSync(new URL("../flutter/web/index.html", import.meta.url), "utf8");
  const manifest = html.match(/<link\b[^>]*\brel="manifest"[^>]*>/)?.[0];
  expect(manifest).toBeDefined();
  expect(manifest).toContain('crossorigin="use-credentials"');
});
