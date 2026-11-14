import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { render } from "./gen-media-ext.mjs";
import { IMAGE_EXT, MEDIA_EXT, VIDEO_EXT } from "../worker/src/lib/const.ts";

const table = JSON.parse(
  readFileSync(new URL("../worker/src/lib/media-ext.json", import.meta.url), "utf8"),
);
const read = (rel) => readFileSync(new URL(rel, import.meta.url), "utf8");

it("Dart 側の表は media-ext.json から生成した物と一致する（食い違うと落ちる）", () => {
  expect(read("../flutter/lib/src/webdl/listed_ext.g.dart")).toBe(render(table));
});

it("アプリは拡張子を手書きせず生成表だけを使う", () => {
  const src = read("../flutter/lib/src/webdl/media_name.dart");
  expect(src).toContain("listed_ext.g.dart");
  expect(src).not.toMatch(/jpe\?g|\|mp4\|/);
});

it("Worker の正規表現は表の全拡張子を拾い、表に無い形式（HEIC など）は拾わない", () => {
  for (const e of table.image) {
    expect(IMAGE_EXT.test(`a.${e.toUpperCase()}`)).toBe(true);
    expect(MEDIA_EXT.test(`a.${e}`)).toBe(true);
  }
  for (const e of table.video) {
    expect(VIDEO_EXT.test(`a.${e}`)).toBe(true);
    expect(MEDIA_EXT.test(`a.${e}`)).toBe(true);
  }
  for (const e of ["heic", "heif", "dng", "bmp"]) expect(MEDIA_EXT.test(`a.${e}`)).toBe(false);
});
