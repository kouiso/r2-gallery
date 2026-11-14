import { readFileSync } from "node:fs";
import { expect, it } from "vitest";

it("loads the web manifest with credentials behind Cloudflare Access", () => {
  const html = readFileSync(new URL("../flutter/web/index.html", import.meta.url), "utf8");
  const manifest = html.match(/<link\b[^>]*\brel="manifest"[^>]*>/)?.[0];
  expect(manifest).toBeDefined();
  expect(manifest).toContain('crossorigin="use-credentials"');
});

// アプリの地の色（flutter/lib/src/ui/theme.dart の AppColors.bg）。起動時に雛形の青が出ないよう揃える
const APP_BG = "#0A0A0F";

it("names, describes and colours the web build like the app, not the Flutter template", () => {
  const read = (f) => readFileSync(new URL(`../flutter/${f}`, import.meta.url), "utf8");
  const manifest = JSON.parse(read("web/manifest.json"));
  const html = read("web/index.html");
  const pubspec = read("pubspec.yaml");
  expect(manifest.name).toBe("R2 Gallery");
  expect(manifest.short_name).toBe("R2 Gallery");
  expect(manifest.background_color.toUpperCase()).toBe(APP_BG);
  expect(manifest.theme_color.toUpperCase()).toBe(APP_BG);
  expect(html).toContain("<title>R2 Gallery</title>");
  expect(html).toContain('name="apple-mobile-web-app-title" content="R2 Gallery"');
  expect(html).toMatch(/<style>[^<]*\bhtml,body\{[^}]*background:#0A0A0F/i);
  for (const text of [JSON.stringify(manifest), html, pubspec]) {
    expect(text).not.toContain("A new Flutter project");
  }
  // 説明文は manifest を正として、index.html と pubspec.yaml が空でなく同一である事を見る
  const metaDescription = html.match(/<meta\s+name="description"\s+content="([^"]*)"/)?.[1];
  const pubspecDescription = pubspec.match(/^description:\s*"?(.*?)"?\s*$/m)?.[1];
  expect(manifest.description).toBeTruthy();
  expect(metaDescription).toBe(manifest.description);
  expect(pubspecDescription).toBe(manifest.description);
});
