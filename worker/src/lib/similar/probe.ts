/**
 * 原本の先頭（最大 64 KB）だけから縦横の画素数を読む。中身は復号しない。
 *
 * 署名はサムネから作るので、元の寸法はここでしか分からない。残す物の順（画素の多い方）と
 * 「差分かも」（同じ寸法・同じ形式なのに少し違う物）の判定に使う。
 * PC ツールからも Node の型除去でそのまま読み込むので import を持たない。
 * 壊れた・途中で切れた入力でも、配列の長さを超えて読まない（分からなければ 0,0 を返す）。
 */

export interface Dims {
  /** 分からなければ 0 */
  w: number;
  h: number;
}

/** 先頭から読む量。JPEG の SOF は大きな EXIF の後ろにあることがあるので 64 KB まで見る */
export const PROBE_BYTES = 65536;

const UNKNOWN: Dims = Object.freeze({ w: 0, h: 0 });

const u16be = (b: Uint8Array, o: number) => (b[o]! << 8) | b[o + 1]!;
const u16le = (b: Uint8Array, o: number) => b[o]! | (b[o + 1]! << 8);
const u24le = (b: Uint8Array, o: number) => b[o]! | (b[o + 1]! << 8) | (b[o + 2]! << 16);
const u32be = (b: Uint8Array, o: number) =>
  ((b[o]! << 24) | (b[o + 1]! << 16) | (b[o + 2]! << 8) | b[o + 3]!) >>> 0;
const u32le = (b: Uint8Array, o: number) =>
  (b[o]! | (b[o + 1]! << 8) | (b[o + 2]! << 16) | (b[o + 3]! << 24)) >>> 0;
const i32le = (b: Uint8Array, o: number) =>
  b[o]! | (b[o + 1]! << 8) | (b[o + 2]! << 16) | (b[o + 3]! << 24);

const ascii = (b: Uint8Array, o: number, s: string): boolean => {
  if (o + s.length > b.length) return false;
  for (let i = 0; i < s.length; i++) if (b[o + i] !== s.charCodeAt(i)) return false;
  return true;
};

const dims = (w: number, h: number): Dims => (w > 0 && h > 0 ? { w, h } : UNKNOWN);

export function probeDims(input: Uint8Array): Dims {
  const b = input.length > PROBE_BYTES ? input.subarray(0, PROBE_BYTES) : input;
  if (b.length >= 2 && b[0] === 0xff && b[1] === 0xd8) return jpeg(b);
  if (ascii(b, 0, "\x89PNG\r\n\x1a\n")) return png(b);
  if (ascii(b, 0, "RIFF") && ascii(b, 8, "WEBP")) return webp(b);
  if (ascii(b, 0, "GIF87a") || ascii(b, 0, "GIF89a")) return gif(b);
  if (ascii(b, 0, "BM")) return bmp(b);
  return UNKNOWN;
}

/* ---------------- JPEG ---------------- */

// SOF0〜15 の印。C4(DHT)・C8(JPG 拡張)・CC(DAC) は同じ並びにあるが寸法を持たない
const isSof = (m: number) => m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc;

function jpeg(b: Uint8Array): Dims {
  let orientation = 1;
  let i = 2;
  while (i + 3 < b.length) {
    if (b[i] !== 0xff) return UNKNOWN; // 区切りが崩れている。当て推量で読まない
    let m = b[i + 1]!;
    // 区切りの前に詰め物の 0xFF が続くことがある
    while (m === 0xff && i + 2 < b.length) {
      i++;
      m = b[i + 1]!;
    }
    if (m === 0xff) return UNKNOWN;
    // 長さを持たない印（SOI・RST・TEM）
    if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7)) {
      i += 2;
      continue;
    }
    // 画素の本体（SOS）や終わり（EOI）まで来たら、その先に寸法は無い
    if (m === 0xda || m === 0xd9) return UNKNOWN;
    if (i + 3 >= b.length) return UNKNOWN;
    const len = u16be(b, i + 2);
    if (len < 2) return UNKNOWN;
    const body = i + 4;
    if (isSof(m)) {
      // P(1) Y(2) X(2)。途中で切れていたら分からない扱い
      if (body + 5 > b.length) return UNKNOWN;
      const h = u16be(b, body + 1);
      const w = u16be(b, body + 3);
      // 向き 5〜8 は 90 度回すので縦横が入れ替わる。署名は向きを直した絵から作るので揃える
      return orientation >= 5 && orientation <= 8 ? dims(h, w) : dims(w, h);
    }
    if (m === 0xe1 && orientation === 1) {
      const end = Math.min(b.length, i + 2 + len);
      orientation = exifOrientation(b, body, end);
    }
    i += 2 + len;
  }
  return UNKNOWN;
}

/** APP1 の中の EXIF から IFD0 の向き(0x0112)を読む。無い・壊れていれば 1 */
function exifOrientation(b: Uint8Array, start: number, end: number): number {
  if (!ascii(b, start, "Exif\0\0")) return 1;
  const tiff = start + 6;
  if (tiff + 8 > end) return 1;
  const le = b[tiff] === 0x49 && b[tiff + 1] === 0x49;
  const be = b[tiff] === 0x4d && b[tiff + 1] === 0x4d;
  if (!le && !be) return 1;
  const r16 = (o: number) => (le ? u16le(b, o) : u16be(b, o));
  const r32 = (o: number) => (le ? u32le(b, o) : u32be(b, o));
  const ifd = tiff + r32(tiff + 4);
  if (ifd + 2 > end) return 1;
  const count = r16(ifd);
  for (let k = 0; k < count; k++) {
    const e = ifd + 2 + k * 12;
    if (e + 12 > end) return 1;
    if (r16(e) !== 0x0112) continue;
    const v = r16(e + 8);
    return v >= 1 && v <= 8 ? v : 1;
  }
  return 1;
}

/* ---------------- PNG / WebP / GIF / BMP ---------------- */

function png(b: Uint8Array): Dims {
  if (b.length < 24 || !ascii(b, 12, "IHDR")) return UNKNOWN;
  return dims(u32be(b, 16), u32be(b, 20));
}

function webp(b: Uint8Array): Dims {
  if (ascii(b, 12, "VP8 ")) {
    // 3 バイトのフレーム情報の後に開始符号 9D 01 2A、続いて 14 bit の幅と高さ
    if (b.length < 30 || b[23] !== 0x9d || b[24] !== 0x01 || b[25] !== 0x2a) return UNKNOWN;
    return dims(u16le(b, 26) & 0x3fff, u16le(b, 28) & 0x3fff);
  }
  if (ascii(b, 12, "VP8L")) {
    if (b.length < 25 || b[20] !== 0x2f) return UNKNOWN;
    const bits = u32le(b, 21);
    return dims((bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1);
  }
  if (ascii(b, 12, "VP8X")) {
    if (b.length < 30) return UNKNOWN;
    return dims(u24le(b, 24) + 1, u24le(b, 27) + 1);
  }
  return UNKNOWN;
}

function gif(b: Uint8Array): Dims {
  if (b.length < 10) return UNKNOWN;
  return dims(u16le(b, 6), u16le(b, 8));
}

function bmp(b: Uint8Array): Dims {
  if (b.length < 18) return UNKNOWN;
  const header = u32le(b, 14);
  if (header === 12) {
    if (b.length < 22) return UNKNOWN;
    return dims(u16le(b, 18), u16le(b, 20));
  }
  if (header < 40 || b.length < 26) return UNKNOWN;
  // 高さが負なら上から下への並び。寸法としては絶対値
  return dims(Math.abs(i32le(b, 18)), Math.abs(i32le(b, 22)));
}
