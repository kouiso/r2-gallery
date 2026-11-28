import { describe, expect, it } from "vitest";

import { PROBE_BYTES, probeDims } from "./probe";

// 手で組んだ先頭のバイト列だけで確かめる（本物の画像は要らない: 中身は読まない作りなので）

const bytes = (...parts: (number[] | Uint8Array | string)[]): Uint8Array => {
  const out: number[] = [];
  for (const p of parts) {
    if (typeof p === "string") for (const c of p) out.push(c.charCodeAt(0));
    else out.push(...p);
  }
  return Uint8Array.from(out);
};
const be16 = (v: number) => [(v >> 8) & 255, v & 255];
const le16 = (v: number) => [v & 255, (v >> 8) & 255];
const le24 = (v: number) => [v & 255, (v >> 8) & 255, (v >> 16) & 255];
const be32 = (v: number) => [(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255];
const le32 = (v: number) => [v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255];

/** JPEG の区切り 1 つ。len は長さ欄自身の 2 バイトを含む */
const seg = (marker: number, body: number[] | Uint8Array) => [
  0xff,
  marker,
  ...be16(body.length + 2),
  ...body,
];
const sof = (marker: number, w: number, h: number) =>
  seg(marker, [8, ...be16(h), ...be16(w), 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);

/** IFD0 に向き(0x0112)だけを持つ EXIF。big=true なら MM（big endian） */
function exif(orientation: number, big = false, padTo = 0): number[] {
  const r16 = big ? be16 : le16;
  const r32 = big ? be32 : le32;
  const tiff = [
    ...(big ? [0x4d, 0x4d] : [0x49, 0x49]),
    ...r16(42),
    ...r32(8),
    ...r16(1),
    ...r16(0x0112),
    ...r16(3),
    ...r32(1),
    ...r16(orientation),
    0,
    0,
    ...r32(0),
  ];
  const body = [..."Exif\0\0"].map((c) => c.charCodeAt(0)).concat(tiff);
  while (body.length < padTo) body.push(0);
  return seg(0xe1, body);
}

const SOI = [0xff, 0xd8];
const DQT = seg(0xdb, new Array(65).fill(1));
const DHT = seg(0xc4, new Array(30).fill(0));
const SOS = [0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0];

describe("probeDims: JPEG", () => {
  it("baseline と progressive の SOF から読む", () => {
    expect(probeDims(bytes(SOI, DQT, DHT, sof(0xc0, 640, 480), SOS))).toEqual({ w: 640, h: 480 });
    expect(probeDims(bytes(SOI, DQT, sof(0xc2, 1920, 1080), SOS))).toEqual({ w: 1920, h: 1080 });
    // 算術符号の SOF9 も寸法を持つ
    expect(probeDims(bytes(SOI, sof(0xc9, 33, 44), SOS))).toEqual({ w: 33, h: 44 });
  });

  it("DHT(C4)・DAC(CC)・JPG(C8) を SOF と取り違えない", () => {
    const dac = seg(0xcc, [0, 0x11]);
    const jpg = seg(0xc8, [1, 2, 3, 4, 5, 6, 7]);
    expect(probeDims(bytes(SOI, DHT, dac, jpg, sof(0xc1, 100, 200), SOS))).toEqual({
      w: 100,
      h: 200,
    });
  });

  it("40 KB の APP1 の後ろにある SOF も読む", () => {
    const bigExif = exif(1, false, 40 * 1024);
    const data = bytes(SOI, bigExif, DQT, sof(0xc0, 4000, 3000), SOS);
    expect(data.length).toBeGreaterThan(40 * 1024);
    expect(data.length).toBeLessThan(PROBE_BYTES);
    expect(probeDims(data)).toEqual({ w: 4000, h: 3000 });
  });

  it("64 KB より後ろの SOF は読まない（分からない扱い）", () => {
    const pad = [...seg(0xe2, new Array(65000).fill(0)), ...seg(0xe3, new Array(2000).fill(0))];
    expect(probeDims(bytes(SOI, pad, sof(0xc0, 10, 20), SOS))).toEqual({ w: 0, h: 0 });
  });

  it("EXIF の向き 5〜8 は縦横を入れ替える（II と MM の両方）", () => {
    for (const o of [1, 2, 3, 4]) {
      expect(probeDims(bytes(SOI, exif(o), sof(0xc0, 400, 300), SOS))).toEqual({ w: 400, h: 300 });
    }
    for (const o of [5, 6, 7, 8]) {
      expect(probeDims(bytes(SOI, exif(o), sof(0xc0, 400, 300), SOS))).toEqual({ w: 300, h: 400 });
      expect(probeDims(bytes(SOI, exif(o, true), sof(0xc0, 400, 300), SOS))).toEqual({
        w: 300,
        h: 400,
      });
    }
    // 範囲外の値は向きなしとして扱う
    expect(probeDims(bytes(SOI, exif(9), sof(0xc0, 400, 300), SOS))).toEqual({ w: 400, h: 300 });
  });

  it("EXIF でない APP1（XMP）の後の EXIF を読む", () => {
    const xmp = seg(
      0xe1,
      [..."http://ns.adobe.com/xap/1.0/\0<x/>"].map((c) => c.charCodeAt(0)),
    );
    expect(probeDims(bytes(SOI, xmp, exif(6), sof(0xc0, 50, 70), SOS))).toEqual({ w: 70, h: 50 });
  });

  it("区切りの前の詰め物 0xFF と長さなしの印を飛ばす", () => {
    const data = bytes(SOI, [0xff, 0xff, 0xff], DQT, [0xff, 0xd0], sof(0xc0, 12, 34), SOS);
    expect(probeDims(data)).toEqual({ w: 12, h: 34 });
  });

  it("SOF より前に SOS・EOI が来たら分からない扱い", () => {
    expect(probeDims(bytes(SOI, DQT, SOS, sof(0xc0, 1, 1)))).toEqual({ w: 0, h: 0 });
    expect(probeDims(bytes(SOI, [0xff, 0xd9]))).toEqual({ w: 0, h: 0 });
  });

  it("途中で切れた・壊れた入力は配列の外を読まずに 0,0", () => {
    const full = bytes(SOI, exif(6), DQT, sof(0xc0, 640, 480), SOS);
    // FF C0 長さ(2) 精度(1) 高さ(2) 幅(2) の 9 バイトが揃って初めて寸法が読める
    const dimsEnd = full.length - SOS.length - sof(0xc0, 640, 480).length + 9;
    for (let n = 0; n < full.length; n++) {
      const got = probeDims(full.subarray(0, n));
      expect(got).toEqual(n < dimsEnd ? { w: 0, h: 0 } : { w: 480, h: 640 });
    }
    expect(probeDims(full)).toEqual({ w: 480, h: 640 });
    // 長さ欄が 0・区切りが 0xFF で始まらない
    expect(probeDims(bytes(SOI, [0xff, 0xdb, 0, 0]))).toEqual({ w: 0, h: 0 });
    expect(probeDims(bytes(SOI, [0x12, 0x34, 0, 4, 0, 0]))).toEqual({ w: 0, h: 0 });
    // IFD の位置が範囲外の EXIF は向きなし
    const badIfd = seg(0xe1, [
      ...[..."Exif\0\0"].map((c) => c.charCodeAt(0)),
      0x49,
      0x49,
      42,
      0,
      ...le32(0xfffffff0),
    ]);
    expect(probeDims(bytes(SOI, badIfd, sof(0xc0, 9, 8), SOS))).toEqual({ w: 9, h: 8 });
    // 寸法 0（DNL で後から決める形式）は分からない扱い
    expect(probeDims(bytes(SOI, sof(0xc0, 100, 0), SOS))).toEqual({ w: 0, h: 0 });
  });
});

describe("probeDims: PNG / WebP / GIF / BMP", () => {
  const pngHead = (w: number, h: number) =>
    bytes("\x89PNG\r\n\x1a\n", be32(13), "IHDR", be32(w), be32(h), [8, 6, 0, 0, 0]);

  it("PNG の IHDR", () => {
    expect(probeDims(pngHead(1024, 768))).toEqual({ w: 1024, h: 768 });
    expect(probeDims(pngHead(70000, 3))).toEqual({ w: 70000, h: 3 });
    expect(probeDims(pngHead(5, 6).subarray(0, 23))).toEqual({ w: 0, h: 0 });
    // IHDR が先頭に無い物は読まない
    const bad = pngHead(5, 6);
    bad[12] = 0x58;
    expect(probeDims(bad)).toEqual({ w: 0, h: 0 });
  });

  const riff = (chunk: string, data: number[]) =>
    bytes("RIFF", le32(4 + 8 + data.length), "WEBP", chunk, le32(data.length), data);

  it("WebP の VP8（非可逆）", () => {
    const vp8 = riff("VP8 ", [
      0x30,
      0x01,
      0x00,
      0x9d,
      0x01,
      0x2a,
      ...le16(800),
      ...le16(600),
      0,
      0,
    ]);
    expect(probeDims(vp8)).toEqual({ w: 800, h: 600 });
    // 上 2 bit は拡大率なので寸法に混ぜない
    const scaled = riff("VP8 ", [
      0,
      0,
      0,
      0x9d,
      0x01,
      0x2a,
      ...le16(0xc000 | 321),
      ...le16(0x4000 | 123),
    ]);
    expect(probeDims(scaled)).toEqual({ w: 321, h: 123 });
    // 開始符号が違えば読まない
    expect(probeDims(riff("VP8 ", [0, 0, 0, 0x9d, 0x01, 0x2b, 1, 0, 1, 0]))).toEqual({
      w: 0,
      h: 0,
    });
  });

  it("WebP の VP8L（可逆）", () => {
    const w = 4000;
    const h = 2500;
    const bits = ((w - 1) | ((h - 1) << 14)) >>> 0;
    expect(probeDims(riff("VP8L", [0x2f, ...le32(bits), 0]))).toEqual({ w, h });
    expect(probeDims(riff("VP8L", [0x2e, ...le32(bits), 0]))).toEqual({ w: 0, h: 0 });
  });

  it("WebP の VP8X（拡張）", () => {
    const data = [0x10, 0, 0, 0, ...le24(16383 - 1), ...le24(9000 - 1)];
    expect(probeDims(riff("VP8X", data))).toEqual({ w: 16383, h: 9000 });
  });

  it("WebP の途中で切れた入力・知らない区画", () => {
    const vp8x = riff("VP8X", [0x10, 0, 0, 0, ...le24(99), ...le24(49)]);
    for (let n = 0; n < vp8x.length; n++) {
      expect(probeDims(vp8x.subarray(0, n))).toEqual({ w: 0, h: 0 });
    }
    expect(probeDims(vp8x)).toEqual({ w: 100, h: 50 });
    expect(probeDims(riff("ALPH", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))).toEqual({ w: 0, h: 0 });
  });

  it("GIF", () => {
    expect(probeDims(bytes("GIF89a", le16(320), le16(240), [0xf7, 0, 0]))).toEqual({
      w: 320,
      h: 240,
    });
    expect(probeDims(bytes("GIF87a", le16(1), le16(2)))).toEqual({ w: 1, h: 2 });
    expect(probeDims(bytes("GIF89a", le16(1)))).toEqual({ w: 0, h: 0 });
  });

  it("BMP（BITMAPINFOHEADER と CORE、上から下の負の高さ）", () => {
    const info = (w: number, h: number) =>
      bytes("BM", le32(0), le32(0), le32(54), le32(40), le32(w), le32(h >>> 0), le16(1), le16(24));
    expect(probeDims(info(640, 480))).toEqual({ w: 640, h: 480 });
    expect(probeDims(info(640, -480))).toEqual({ w: 640, h: 480 });
    const core = bytes(
      "BM",
      le32(0),
      le32(0),
      le32(26),
      le32(12),
      le16(77),
      le16(88),
      le16(1),
      le16(24),
    );
    expect(probeDims(core)).toEqual({ w: 77, h: 88 });
    expect(probeDims(info(640, 480).subarray(0, 25))).toEqual({ w: 0, h: 0 });
  });

  it("知らない形式・空は 0,0", () => {
    expect(probeDims(new Uint8Array(0))).toEqual({ w: 0, h: 0 });
    expect(probeDims(bytes([0xff]))).toEqual({ w: 0, h: 0 });
    // HEIC（ftyp）は読まない
    expect(probeDims(bytes(be32(24), "ftypheic", be32(0), "mif1heic"))).toEqual({ w: 0, h: 0 });
  });
});
