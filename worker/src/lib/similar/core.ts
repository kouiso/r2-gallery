/**
 * 見た目の照合 "vs1" の基準実装。署名・二枚の判定・候補探し・束ね方の正はここだけに置く。
 * Dart 版（flutter/lib/src/duplicates/visual_signature.dart）と PC ツールは、この結果にバイト単位で合わせる。
 *
 * tools から Node の型除去でそのまま読み込むので、import を持たず、消すだけで JS になる型構文だけで書く。
 * 復号した後は整数演算だけにし、ビット演算は 2^32 未満の値にしか使わない: Dart の web 版は int が
 * double で、32 bit を超えるビット演算や浮動小数の丸め差があると、端末ごとに署名が変わってしまう。
 */

/** しきい値はコードに置く（env にしない）。PC ツールの報告と Worker の判定が必ず一致するように。 */
export const PARAMS = {
  version: "p1",
  alg: "vs1",
  same: { ph: 4, dh: 6, asp: 0.02, gMax: 12, gSum: 768, col: 20 },
  mirror: { mph: 4, asp: 0.02, gMax: 12, gSum: 768, col: 20 },
  similar: { ph: 10, dh: 12, asp: 0.1, col: 48 },
  /** 同じ寸法・同じ形式でここを超えて違うなら、描き足しの差分かもしれない */
  variantGMax: 3,
  /** 16 bit 4 区画で各区画 2 bit 以内を引くと、鳩の巣原理で距離 11 以下は漏れなく拾える */
  mihMaxDist: 11,
  maxNeighbours: 64,
} as const;

export const SIG_BYTES = 297;
export const SIG_B64_LENGTH = 396;
export const FLAG_FLAT = 1;
export const FLAG_FROM_ORIGINAL = 2;
export const FLAG_MULTI_FRAME = 4;

const OFF_P = 0;
const OFF_D = 8;
const OFF_M = 16;
const OFF_GRID = 24;
const OFF_COLOR = 280;
const OFF_W = 292;
const OFF_H = 294;
const OFF_FLAGS = 296;

/**
 * C[u][x] = round(16384*cos((2x+1)*u*π/64))、u<8・x<32 を u ごとに並べた物。
 * 式から毎回作らず定数で持つ: cos の最後の桁は実行系ごとに違い得るので、Dart と表を共有して揃える。
 */
export const COS_TABLE: readonly number[] = Object.freeze([
  16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384,
  16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384,
  16384, 16384, 16384, 16384, 16364, 16207, 15893, 15426, 14811, 14053, 13160, 12140, 11003, 9760,
  8423, 7005, 5520, 3981, 2404, 804, -804, -2404, -3981, -5520, -7005, -8423, -9760, -11003, -12140,
  -13160, -14053, -14811, -15426, -15893, -16207, -16364, 16305, 15679, 14449, 12665, 10394, 7723,
  4756, 1606, -1606, -4756, -7723, -10394, -12665, -14449, -15679, -16305, -16305, -15679, -14449,
  -12665, -10394, -7723, -4756, -1606, 1606, 4756, 7723, 10394, 12665, 14449, 15679, 16305, 16207,
  14811, 12140, 8423, 3981, -804, -5520, -9760, -13160, -15426, -16364, -15893, -14053, -11003,
  -7005, -2404, 2404, 7005, 11003, 14053, 15893, 16364, 15426, 13160, 9760, 5520, 804, -3981, -8423,
  -12140, -14811, -16207, 16069, 13623, 9102, 3196, -3196, -9102, -13623, -16069, -16069, -13623,
  -9102, -3196, 3196, 9102, 13623, 16069, 16069, 13623, 9102, 3196, -3196, -9102, -13623, -16069,
  -16069, -13623, -9102, -3196, 3196, 9102, 13623, 16069, 15893, 12140, 5520, -2404, -9760, -14811,
  -16364, -14053, -8423, -804, 7005, 13160, 16207, 15426, 11003, 3981, -3981, -11003, -15426,
  -16207, -13160, -7005, 804, 8423, 14053, 16364, 14811, 9760, 2404, -5520, -12140, -15893, 15679,
  10394, 1606, -7723, -14449, -16305, -12665, -4756, 4756, 12665, 16305, 14449, 7723, -1606, -10394,
  -15679, -15679, -10394, -1606, 7723, 14449, 16305, 12665, 4756, -4756, -12665, -16305, -14449,
  -7723, 1606, 10394, 15679, 15426, 8423, -2404, -12140, -16364, -13160, -3981, 7005, 14811, 15893,
  9760, -804, -11003, -16207, -14053, -5520, 5520, 14053, 16207, 11003, 804, -9760, -15893, -14811,
  -7005, 3981, 13160, 16364, 12140, 2404, -8423, -15426,
]);

const COS = Int32Array.from(COS_TABLE);

// 16 bit ごとの立っている bit 数。候補探しの内側で何千万回も数えるので表を引く
const POP16 = new Uint8Array(65536);
for (let v = 1; v < 65536; v++) POP16[v] = (v & 1) + POP16[v >>> 1]!;

export function popcount32(v: number): number {
  return POP16[v >>> 16]! + POP16[v & 0xffff]!;
}

const ham64 = (aHi: number, aLo: number, bHi: number, bLo: number): number =>
  popcount32(aHi ^ bHi) + popcount32(aLo ^ bLo);

// ---------------------------------------------------------------- 署名

const isDim = (v: number) => Number.isInteger(v) && v >= 1 && v <= 65535;

/**
 * 箱平均の格子。境界の割り振りは floor(x*GW/w) に決め打ちする（Dart も同じ式で割り振る）。
 * 元が格子より小さいと空のマスが出るので、そのマスは対応する 1 画素を採る。
 */
function boxGrid(
  src: Uint8Array,
  ch: number,
  w: number,
  h: number,
  gw: number,
  gh: number,
): Uint8Array {
  const cells = gw * gh;
  // 和は 2^32 を超え得る（大きな元画像）。浮動小数でも 2^53 未満の整数なら正確なので Float64 に積む
  const sums = new Float64Array(cells * ch);
  const counts = new Float64Array(cells);
  const colOf = new Int32Array(w);
  for (let x = 0; x < w; x++) colOf[x] = Math.floor((x * gw) / w);
  for (let y = 0; y < h; y++) {
    const rowCell = Math.floor((y * gh) / h) * gw;
    let p = y * w * ch;
    for (let x = 0; x < w; x++) {
      const cell = rowCell + colOf[x]!;
      counts[cell]!++;
      const s = cell * ch;
      for (let c = 0; c < ch; c++) sums[s + c]! += src[p++]!;
    }
  }
  const out = new Uint8Array(cells * ch);
  for (let cy = 0; cy < gh; cy++) {
    for (let cx = 0; cx < gw; cx++) {
      const cell = cy * gw + cx;
      const n = counts[cell]!;
      if (n > 0) {
        for (let c = 0; c < ch; c++) out[cell * ch + c] = Math.floor(sums[cell * ch + c]! / n);
      } else {
        const px = Math.floor((cx * w) / gw);
        const py = Math.floor((cy * h) / gh);
        const p = (py * w + px) * ch;
        for (let c = 0; c < ch; c++) out[cell * ch + c] = src[p + c]!;
      }
    }
  }
  return out;
}

/** 32x32 の輝度から低周波 8x8 の DCT を整数で取り、中央値と比べる（imagehash と同じく DC 込み）。 */
function pHashOf(g32: Uint8Array, mirror: boolean): Uint8Array {
  const r = new Float64Array(8 * 32);
  for (let u = 0; u < 8; u++) {
    for (let y = 0; y < 32; y++) {
      let s = 0;
      for (let x = 0; x < 32; x++) s += COS[u * 32 + x]! * g32[y * 32 + (mirror ? 31 - x : x)]!;
      r[u * 32 + y] = s;
    }
  }
  // 値は 2^53 未満に収まるので、web の Dart（double）でも誤差なく同じ値になる
  const d = new Float64Array(64);
  for (let v = 0; v < 8; v++) {
    for (let u = 0; u < 8; u++) {
      let s = 0;
      for (let y = 0; y < 32; y++) s += COS[v * 32 + y]! * r[u * 32 + y]!;
      d[v * 8 + u] = s;
    }
  }
  const sorted = d.slice().sort();
  // 中央値を 2 倍のまま比べて割り算を避ける
  const m2 = sorted[31]! + sorted[32]!;
  const out = new Uint8Array(8);
  for (let i = 0; i < 64; i++) if (2 * d[i]! > m2) out[i >> 3]! |= 0x80 >> (i & 7);
  return out;
}

function dHashOf(g98: Uint8Array): Uint8Array {
  const out = new Uint8Array(8);
  for (let r = 0; r < 8; r++) {
    for (let c = 0; c < 8; c++) {
      const i = r * 8 + c;
      if (g98[r * 9 + c]! > g98[r * 9 + c + 1]!) out[i >> 3]! |= 0x80 >> (i & 7);
    }
  }
  return out;
}

/** 標準偏差 6 未満を単色とみなす。単色同士はハッシュが偶然揃うので比べない */
function isFlatGrid(g32: Uint8Array): boolean {
  let s = 0;
  let q = 0;
  for (let i = 0; i < 1024; i++) {
    const v = g32[i]!;
    s += v;
    q += v * v;
  }
  return 1024 * q - s * s < 36 * 1024 * 1024;
}

/**
 * 素の（乗算済みでない）RGBA から 297 バイトの署名を作る。EXIF の向きは呼ぶ側で直してから渡す。
 * extraFlags には FLAG_FROM_ORIGINAL / FLAG_MULTI_FRAME だけが効く（単色は中で決める）。
 */
export function vs1FromRgba(
  w: number,
  h: number,
  rgba: ArrayLike<number>,
  extraFlags = 0,
): Uint8Array {
  if (!isDim(w) || !isDim(h)) throw new RangeError("vs1_bad_size");
  const n = w * h;
  if (rgba.length < n * 4) throw new RangeError("vs1_short_rgba");
  const luma = new Uint8Array(n);
  const rgb = new Uint8Array(n * 3);
  for (let p = 0; p < n; p++) {
    const q = p * 4;
    let r = rgba[q]!;
    let g = rgba[q + 1]!;
    let b = rgba[q + 2]!;
    const a = rgba[q + 3]!;
    if (a !== 255) {
      // 透過は白の上に置いてから見る。黒の上だと、透過 PNG と白地の JPEG が別物に見える
      const bg = 255 * (255 - a) + 127;
      r = Math.floor((r * a + bg) / 255);
      g = Math.floor((g * a + bg) / 255);
      b = Math.floor((b * a + bg) / 255);
    }
    rgb[p * 3] = r;
    rgb[p * 3 + 1] = g;
    rgb[p * 3 + 2] = b;
    luma[p] = (77 * r + 150 * g + 29 * b) >> 8;
  }
  const g32 = boxGrid(luma, 1, w, h, 32, 32);
  const g98 = boxGrid(luma, 1, w, h, 9, 8);
  const g16 = boxGrid(luma, 1, w, h, 16, 16);
  const c22 = boxGrid(rgb, 3, w, h, 2, 2);
  const out = new Uint8Array(SIG_BYTES);
  out.set(pHashOf(g32, false), OFF_P);
  out.set(dHashOf(g98), OFF_D);
  out.set(pHashOf(g32, true), OFF_M);
  out.set(g16, OFF_GRID);
  out.set(c22, OFF_COLOR);
  out[OFF_W] = w >> 8;
  out[OFF_W + 1] = w & 255;
  out[OFF_H] = h >> 8;
  out[OFF_H + 1] = h & 255;
  out[OFF_FLAGS] =
    (isFlatGrid(g32) ? FLAG_FLAT : 0) | (extraFlags & (FLAG_FROM_ORIGINAL | FLAG_MULTI_FRAME));
  return out;
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const B64_INV = new Int16Array(128).fill(-1);
for (let i = 0; i < 64; i++) B64_INV[B64.charCodeAt(i)] = i;

/** base64url（詰め物なし）。297 バイトは 3 の倍数なので、署名はちょうど 396 文字になる */
export function encodeSig(sig: Uint8Array): string {
  let s = "";
  let i = 0;
  for (; i + 2 < sig.length; i += 3) {
    const v = (sig[i]! << 16) | (sig[i + 1]! << 8) | sig[i + 2]!;
    s += B64[v >> 18]! + B64[(v >> 12) & 63]! + B64[(v >> 6) & 63]! + B64[v & 63]!;
  }
  const rest = sig.length - i;
  if (rest === 1) {
    const v = sig[i]! << 16;
    s += B64[v >> 18]! + B64[(v >> 12) & 63]!;
  } else if (rest === 2) {
    const v = (sig[i]! << 16) | (sig[i + 1]! << 8);
    s += B64[v >> 18]! + B64[(v >> 12) & 63]! + B64[(v >> 6) & 63]!;
  }
  return s;
}

/** 396 文字の base64url だけを受け、ほかは null（壊れた・別の版の署名を黙って読まない）。 */
export function decodeSig(s: string): Uint8Array | null {
  if (typeof s !== "string" || s.length !== SIG_B64_LENGTH) return null;
  const out = new Uint8Array(SIG_BYTES);
  for (let i = 0, o = 0; i < s.length; i += 4, o += 3) {
    let v = 0;
    for (let k = 0; k < 4; k++) {
      const c = s.charCodeAt(i + k);
      const d = c < 128 ? B64_INV[c]! : -1;
      if (d < 0) return null;
      v = (v << 6) | d;
    }
    out[o] = v >> 16;
    out[o + 1] = (v >> 8) & 255;
    out[o + 2] = v & 255;
  }
  return out;
}

export interface SigInfo {
  w: number;
  h: number;
  flags: number;
}

export function sigInfo(sig: Uint8Array): SigInfo {
  return {
    w: (sig[OFF_W]! << 8) | sig[OFF_W + 1]!,
    h: (sig[OFF_H]! << 8) | sig[OFF_H + 1]!,
    flags: sig[OFF_FLAGS]!,
  };
}

// ---------------------------------------------------------------- 署名の表（列ごとの配列）

/**
 * 5 万件の署名をオブジェクトで持つと Worker のメモリと GC が重いので、列ごとの型付き配列で持つ。
 * 64 bit のハッシュは JS でも Dart の web 版でも 1 つの数で扱えないので、上下 32 bit に分ける。
 */
export interface SigTable {
  readonly n: number;
  pHi: Uint32Array;
  pLo: Uint32Array;
  dHi: Uint32Array;
  dLo: Uint32Array;
  mHi: Uint32Array;
  mLo: Uint32Array;
  /** 1 件 256 バイトの 16x16 輝度 */
  grid: Uint8Array;
  /** 1 件 12 バイトの 2x2 RGB */
  color: Uint8Array;
  w: Uint16Array;
  h: Uint16Array;
  flags: Uint8Array;
}

export function newSigTable(n: number): SigTable {
  return {
    n,
    pHi: new Uint32Array(n),
    pLo: new Uint32Array(n),
    dHi: new Uint32Array(n),
    dLo: new Uint32Array(n),
    mHi: new Uint32Array(n),
    mLo: new Uint32Array(n),
    grid: new Uint8Array(n * 256),
    color: new Uint8Array(n * 12),
    w: new Uint16Array(n),
    h: new Uint16Array(n),
    flags: new Uint8Array(n),
  };
}

const u32At = (b: Uint8Array, o: number) =>
  ((b[o]! << 24) | (b[o + 1]! << 16) | (b[o + 2]! << 8) | b[o + 3]!) >>> 0;

export function setSig(t: SigTable, i: number, sig: Uint8Array): void {
  if (sig.length !== SIG_BYTES) throw new RangeError("vs1_bad_sig");
  t.pHi[i] = u32At(sig, OFF_P);
  t.pLo[i] = u32At(sig, OFF_P + 4);
  t.dHi[i] = u32At(sig, OFF_D);
  t.dLo[i] = u32At(sig, OFF_D + 4);
  t.mHi[i] = u32At(sig, OFF_M);
  t.mLo[i] = u32At(sig, OFF_M + 4);
  t.grid.set(sig.subarray(OFF_GRID, OFF_GRID + 256), i * 256);
  t.color.set(sig.subarray(OFF_COLOR, OFF_COLOR + 12), i * 12);
  const info = sigInfo(sig);
  t.w[i] = info.w;
  t.h[i] = info.h;
  t.flags[i] = info.flags;
}

export function sigTableOf(sigs: readonly Uint8Array[]): SigTable {
  const t = newSigTable(sigs.length);
  sigs.forEach((s, i) => setSig(t, i, s));
  return t;
}

const putU32 = (b: Uint8Array, o: number, v: number) => {
  b[o] = v >>> 24;
  b[o + 1] = (v >>> 16) & 255;
  b[o + 2] = (v >>> 8) & 255;
  b[o + 3] = v & 255;
};

/** 表の 1 行を署名のバイト列に戻す（保存し直す時と、表を経た値の確認に使う）。 */
export function sigAt(t: SigTable, i: number): Uint8Array {
  const b = new Uint8Array(SIG_BYTES);
  putU32(b, OFF_P, t.pHi[i]!);
  putU32(b, OFF_P + 4, t.pLo[i]!);
  putU32(b, OFF_D, t.dHi[i]!);
  putU32(b, OFF_D + 4, t.dLo[i]!);
  putU32(b, OFF_M, t.mHi[i]!);
  putU32(b, OFF_M + 4, t.mLo[i]!);
  b.set(t.grid.subarray(i * 256, i * 256 + 256), OFF_GRID);
  b.set(t.color.subarray(i * 12, i * 12 + 12), OFF_COLOR);
  b[OFF_W] = t.w[i]! >> 8;
  b[OFF_W + 1] = t.w[i]! & 255;
  b[OFF_H] = t.h[i]! >> 8;
  b[OFF_H + 1] = t.h[i]! & 255;
  b[OFF_FLAGS] = t.flags[i]!;
  return b;
}

// ---------------------------------------------------------------- 二枚の判定

export type Label = "identical" | "same" | "mirror" | "similar";

export interface PairResult {
  label: Label;
  ph: number;
  dh: number;
  mph: number;
  gMax: number;
  variant: boolean;
}

/** 元画像の寸法（不明は 0）と拡張子。sha256 が両方にあって等しければ、絵を見ずに identical にする */
export interface PairMeta {
  ow: number;
  oh: number;
  ext: string;
  sha256?: string | null;
}

/** jpg と jpeg は同じ形式。差分かもの判定で別形式扱いにすると、描き足しを見逃す */
export function normExt(ext: string): string {
  const e = ext.toLowerCase().replace(/^\./, "");
  return e === "jpeg" ? "jpg" : e;
}

export function extOf(key: string): string {
  const dot = key.lastIndexOf(".");
  return dot < 0 || dot < key.lastIndexOf("/") ? "" : normExt(key.slice(dot + 1));
}

interface GridDist {
  gMax: number;
  gSum: number;
  col: number;
}

/**
 * 16x16 輝度の差。全体の明るさのずれ（shift）を引いてから見るので、明るさを少し変えただけの
 * 再保存は同じと判定できる。shift の丸めは 0 から遠い側へ: a,b を入れ替えても結果が同じになるように。
 * flip は b を左右反転して比べる（反転の判定用）。
 */
function gridDist(t: SigTable, i: number, j: number, flip: boolean): GridDist {
  const g = t.grid;
  const ga = i * 256;
  const gb = j * 256;
  let s = 0;
  for (let k = 0; k < 256; k++) s += g[ga + k]! - g[gb + (flip ? (k & ~15) | (15 - (k & 15)) : k)]!;
  const shift = s >= 0 ? Math.floor((s + 128) / 256) : -Math.floor((128 - s) / 256);
  let gMax = 0;
  let gSum = 0;
  for (let k = 0; k < 256; k++) {
    const d = Math.abs(g[ga + k]! - g[gb + (flip ? (k & ~15) | (15 - (k & 15)) : k)]! - shift);
    gSum += d;
    if (d > gMax) gMax = d;
  }
  const c = t.color;
  let col = 0;
  for (let cell = 0; cell < 4; cell++) {
    const other = flip ? cell ^ 1 : cell;
    for (let ch = 0; ch < 3; ch++) {
      const d = Math.abs(c[i * 12 + cell * 3 + ch]! - c[j * 12 + other * 3 + ch]!);
      if (d > col) col = d;
    }
  }
  return { gMax, gSum, col };
}

function aspectGap(t: SigTable, i: number, j: number): number {
  const wa = t.w[i]!;
  const ha = t.h[i]!;
  const wb = t.w[j]!;
  const hb = t.h[j]!;
  if (!wa || !ha || !wb || !hb) return Infinity;
  return Math.abs(Math.log((wa * hb) / (ha * wb)));
}

interface Visual {
  label: Exclude<Label, "identical">;
  ph: number;
  dh: number;
  mph: number;
  gMax: number;
}

function hashDist(t: SigTable, i: number, j: number): { ph: number; dh: number; mph: number } {
  const ph = ham64(t.pHi[i]!, t.pLo[i]!, t.pHi[j]!, t.pLo[j]!);
  const dh = ham64(t.dHi[i]!, t.dLo[i]!, t.dHi[j]!, t.dLo[j]!);
  const mph = Math.min(
    ham64(t.mHi[i]!, t.mLo[i]!, t.pHi[j]!, t.pLo[j]!),
    ham64(t.pHi[i]!, t.pLo[i]!, t.mHi[j]!, t.mLo[j]!),
  );
  return { ph, dh, mph };
}

/** 表の 2 行を見た目だけで判定する。単色が混じれば null。a,b の順を入れ替えても同じ答えになる */
function classify(t: SigTable, i: number, j: number): Visual | null {
  if ((t.flags[i]! | t.flags[j]!) & FLAG_FLAT) return null;
  const { same, mirror, similar } = PARAMS;
  const { ph, dh, mph } = hashDist(t, i, j);
  if (ph > similar.ph && mph > mirror.mph) return null;
  const asp = aspectGap(t, i, j);
  if (ph <= same.ph && dh <= same.dh && asp <= same.asp) {
    const g = gridDist(t, i, j, false);
    if (g.gMax <= same.gMax && g.gSum <= same.gSum && g.col <= same.col)
      return { label: "same", ph, dh, mph, gMax: g.gMax };
  }
  if (mph <= mirror.mph && asp <= mirror.asp) {
    const g = gridDist(t, i, j, true);
    if (g.gMax <= mirror.gMax && g.gSum <= mirror.gSum && g.col <= mirror.col)
      return { label: "mirror", ph, dh, mph, gMax: g.gMax };
  }
  if (ph <= similar.ph && dh <= similar.dh && asp <= similar.asp) {
    const g = gridDist(t, i, j, false);
    if (g.col <= similar.col) return { label: "similar", ph, dh, mph, gMax: g.gMax };
  }
  return null;
}

/**
 * 差分かも: 元の寸法が分かっていて等しく、形式も同じなのに格子が少しでも違う物。
 * 再保存や縮小なら寸法か形式が変わるのが普通なので、同じままで中身が違うのは描き足しを疑う。
 */
function isVariant(label: Label, gMax: number, a: PairMeta, b: PairMeta): boolean {
  return (
    label === "same" &&
    a.ow > 0 &&
    a.oh > 0 &&
    a.ow === b.ow &&
    a.oh === b.oh &&
    normExt(a.ext) === normExt(b.ext) &&
    gMax > PARAMS.variantGMax
  );
}

/**
 * 二枚の判定。a,b は 297 バイトの署名（無ければ null）。
 * SHA-256 が等しければ絵に関係なく identical。それ以外で署名が欠ける・単色・どの基準にも入らなければ null。
 */
export function compareSigs(
  a: Uint8Array | null,
  b: Uint8Array | null,
  metaA: PairMeta,
  metaB: PairMeta,
): PairResult | null {
  if (metaA.sha256 && metaA.sha256 === metaB.sha256) {
    if (!a || !b) return { label: "identical", ph: 0, dh: 0, mph: 0, gMax: 0, variant: false };
    const t = sigTableOf([a, b]);
    return {
      label: "identical",
      ...hashDist(t, 0, 1),
      gMax: gridDist(t, 0, 1, false).gMax,
      variant: false,
    };
  }
  if (!a || !b) return null;
  const v = classify(sigTableOf([a, b]), 0, 1);
  if (!v) return null;
  return { ...v, variant: isVariant(v.label, v.gMax, metaA, metaB) };
}

// ---------------------------------------------------------------- 候補探し（multi-index hashing）

// 16 bit の値から 2 bit 以内で届く値を作る xor の型: 0 個 1 + 1 個 16 + 2 個 120 = 137
const PROBES = (() => {
  const m: number[] = [0];
  for (let a = 0; a < 16; a++) m.push(1 << a);
  for (let a = 0; a < 16; a++) for (let b = a + 1; b < 16; b++) m.push((1 << a) | (1 << b));
  return Int32Array.from(m);
})();

const chunkOf = (hi: number, lo: number, k: number): number =>
  k === 0 ? hi >>> 16 : k === 1 ? hi & 0xffff : k === 2 ? lo >>> 16 : lo & 0xffff;

// PROBES の先頭から何個使えば半径 r（0〜2 bit）になるか
const PROBE_COUNT = [1, 17, 137] as const;

/**
 * 距離 maxDist 以下を漏れなく拾える、区画ごとの最小の半径。Σ(r_k+1) > maxDist なら、どれかの区画は
 * r_k 以内に入る（鳩の巣原理）。束ねる時は pHash 10・反転 4 までで足りるので、一律 2 bit で引くより
 * 引く数が大きく減る（反転側は 548 回が 20 回になる）。
 */
function radiiFor(maxDist: number): number[] {
  const extra = Math.max(0, maxDist - 3);
  return [0, 1, 2, 3].map((k) => Math.floor(extra / 4) + (k < extra % 4 ? 1 : 0));
}

/** どれかの区画が半径以内か（= 相手がその半径で引いた時に見つかるか） */
function chunkNear(aHi: number, aLo: number, bHi: number, bLo: number, r: number[]): boolean {
  const xh = aHi ^ bHi;
  const xl = aLo ^ bLo;
  return (
    POP16[xh >>> 16]! <= r[0]! ||
    POP16[xh & 0xffff]! <= r[1]! ||
    POP16[xl >>> 16]! <= r[2]! ||
    POP16[xl & 0xffff]! <= r[3]!
  );
}

export interface MihIndex {
  /** 項目 i が表の何行目か。負なら署名なし */
  rows: Int32Array;
  /** 1 = 候補探しに加える（署名あり・単色でない） */
  eligible: Uint8Array;
  /** 区画ごとの計数ソート: offsets[k][v]..offsets[k][v+1] が members[k] の範囲 */
  offsets: Int32Array[];
  members: Int32Array[];
}

/**
 * pHash の 16 bit 区画ごとに表を 4 つ作る。全組み合わせ（5 万件で 12 億組）を比べないため。
 * rows を渡すと項目番号と表の行を分けられる（並べ替えた順で探したい時）。
 * mirror を true にすると、pHash の代わりに反転 pHash で表を作る（相手の反転側を引く時に使う）。
 */
export function buildIndex(t: SigTable, rows?: Int32Array, mirror = false): MihIndex {
  const r = rows ?? Int32Array.from({ length: t.n }, (_, i) => i);
  const n = r.length;
  const hiOf = mirror ? t.mHi : t.pHi;
  const loOf = mirror ? t.mLo : t.pLo;
  const eligible = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    const row = r[i]!;
    eligible[i] = row >= 0 && !(t.flags[row]! & FLAG_FLAT) ? 1 : 0;
  }
  const offsets: Int32Array[] = [];
  const members: Int32Array[] = [];
  for (let k = 0; k < 4; k++) {
    const off = new Int32Array(65537);
    let count = 0;
    for (let i = 0; i < n; i++) {
      if (!eligible[i]) continue;
      off[chunkOf(hiOf[r[i]!]!, loOf[r[i]!]!, k) + 1]!++;
      count++;
    }
    for (let v = 0; v < 65536; v++) off[v + 1]! += off[v]!;
    const fill = off.slice(0, 65536);
    const mem = new Int32Array(count);
    for (let i = 0; i < n; i++) {
      if (!eligible[i]) continue;
      const v = chunkOf(hiOf[r[i]!]!, loOf[r[i]!]!, k);
      mem[fill[v]!++] = i;
    }
    offsets.push(off);
    members.push(mem);
  }
  return { rows: r, eligible, offsets, members };
}

/**
 * pHash 距離が maxPh 以下、または反転 pHash 距離が maxMph 以下の組を、項目番号 [a0,b0,a1,b1,...]
 * （各組 a<b、重複なし）で返す。各項目は自分の p と m で引く。距離 11 までは取りこぼさない。
 */
export function candidates(
  t: SigTable,
  index: MihIndex,
  maxPh: number = PARAMS.mihMaxDist,
  maxMph: number = PARAMS.mihMaxDist,
): number[] {
  if (maxPh > PARAMS.mihMaxDist || maxMph > PARAMS.mihMaxDist) throw new RangeError("mih_radius");
  const { rows, eligible, offsets, members } = index;
  const { pHi, pLo, mHi, mLo } = t;
  const rp = radiiFor(maxPh);
  const rm = radiiFor(maxMph);
  const n = rows.length;
  const seen = new Int32Array(n).fill(-1);
  const out: number[] = [];
  for (let i = 0; i < n; i++) {
    if (!eligible[i]) continue;
    const ri = rows[i]!;
    const piH = pHi[ri]!;
    const piL = pLo[ri]!;
    const miH = mHi[ri]!;
    const miL = mLo[ri]!;
    for (let q = 0; q < 2; q++) {
      const qH = q === 0 ? piH : miH;
      const qL = q === 0 ? piL : miL;
      const radii = q === 0 ? rp : rm;
      for (let k = 0; k < 4; k++) {
        const c = chunkOf(qH, qL, k);
        const off = offsets[k]!;
        const mem = members[k]!;
        const probes = PROBE_COUNT[radii[k]!]!;
        for (let pi = 0; pi < probes; pi++) {
          const v = c ^ PROBES[pi]!;
          for (let s = off[v]!, e = off[v + 1]!; s < e; s++) {
            const j = mem[s]!;
            if (j === i || seen[j] === i) continue;
            seen[j] = i;
            const rj = rows[j]!;
            const pjH = pHi[rj]!;
            const pjL = pLo[rj]!;
            const mjH = mHi[rj]!;
            const mjL = mLo[rj]!;
            // 小さい番号の側が自分の引きで既に見つけた組は、そちらで出したので飛ばす
            if (j < i && (chunkNear(pjH, pjL, piH, piL, rp) || chunkNear(mjH, mjL, piH, piL, rm)))
              continue;
            const ph = ham64(piH, piL, pjH, pjL);
            const mph = Math.min(ham64(miH, miL, pjH, pjL), ham64(piH, piL, mjH, mjL));
            if (ph <= maxPh || mph <= maxMph) {
              if (j < i) out.push(j, i);
              else out.push(i, j);
            }
          }
        }
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------- 束ね方

export interface MemberMeta {
  key: string;
  size: number;
  uploaded: number;
  /** 元画像の寸法。分からなければ 0 */
  ow: number;
  oh: number;
  ext: string;
}

/**
 * 束ねる単位。SHA-256 が同じ物の集まりは 1 つの節にまとめる（動画もここに入る）。
 * sig は署名の表の行（無ければ -1）。同じ中身の集まりは、どの一員の署名を使ってもよい。
 */
export interface GroupNodeInput {
  members: readonly MemberMeta[];
  sig: number;
}

export type Match = "keeper" | "identical" | "same" | "mirror" | "similar";

export interface GroupItem {
  member: MemberMeta;
  match: Match;
  ph?: number;
  dh?: number;
  mph?: number;
  gMax?: number;
  variant: boolean;
}

export interface Group {
  /** 残す物の key。dup と similar の両方に同じ残す物が出ても同じ id */
  id: string;
  tier: "dup" | "similar";
  /** 先頭が残す物 */
  items: GroupItem[];
}

export interface GroupResult {
  groups: Group[];
  /** 近い相手が上限を超え、遠い方を捨てた節の数 */
  crowded: number;
}

const LABEL_CODE: Record<Exclude<Label, "identical">, number> = { same: 0, mirror: 1, similar: 2 };
const CODE_LABEL = ["same", "mirror", "similar"] as const;
const MATCH_ORDER: Record<Match, number> = {
  keeper: 0,
  identical: 1,
  same: 2,
  mirror: 3,
  similar: 4,
};

const byKey = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

const oldestFirst = (a: MemberMeta, b: MemberMeta) =>
  a.uploaded - b.uploaded || byKey(a.key, b.key);

const pixelsOf = (m: MemberMeta) => (m.ow > 0 && m.oh > 0 ? m.ow * m.oh : 0);

interface RankedNode {
  members: MemberMeta[];
  sig: number;
  pixels: number;
  png: boolean;
}

/**
 * 連鎖しない代表選び: 残す物の候補順に並べ、まだ誰にも取られていない節が代表になって、
 * 代表と直接ラベルが付く相手だけを取る。A~B, B~C でも A と C が似ていなければ C は別の束になる
 * （連鎖させると、少しずつ違う絵が 1 つの大きな束に吸い込まれ、まとめて消されかねない）。
 * 1 人の代表が取るのは、まだ取られていない相手のうち近い順に 64 件まで（crowded はそれで
 * 相手を残した節の数）。取り残された物も、既にできた組の頭と直接合えば、その組へ足す。
 */
let peakProbe: (() => void) | null = null;

/**
 * テスト用: groupNodes の一番重い所（索引を作り終え、段の取り合いを始める直前と終えた直後）で呼ぶ
 * 関数を置く（tools/similar-model-memory.test.mjs が記憶の量を測る）。null で外す
 */
export function setGroupPeakProbe(fn: (() => void) | null): void {
  peakProbe = fn;
}

export function groupNodes(nodes: readonly GroupNodeInput[], table: SigTable): GroupResult {
  const ranked: RankedNode[] = nodes.map((nd) => {
    const members = [...nd.members].sort(oldestFirst);
    const head = members[0];
    return {
      members,
      sig: nd.sig,
      // 同じ中身の集まりはどれの寸法でも同じはずなので、分かっている物を使う
      pixels: Math.max(0, ...members.map(pixelsOf)),
      png: head ? normExt(head.ext) === "png" : false,
    };
  });
  // 残す物の順: 元の画素が多い（不明は最後）→ PNG → 大きい → 古い → key
  const order = ranked
    .filter((nd) => nd.members.length > 0)
    .sort((a, b) => {
      const ha = a.members[0]!;
      const hb = b.members[0]!;
      return (
        b.pixels - a.pixels ||
        (a.png === b.png ? 0 : a.png ? -1 : 1) ||
        hb.size - ha.size ||
        ha.uploaded - hb.uploaded ||
        byKey(ha.key, hb.key)
      );
    });
  const n = order.length;
  const rows = Int32Array.from(order, (nd) => (nd.sig >= 0 && nd.sig < table.n ? nd.sig : -1));
  const near = neighbourFinder(table, rows);
  const { same, mirror, similar } = PARAMS;
  const cap = PARAMS.maxNeighbours;
  const crowdedNode = new Uint8Array(n);

  // 同じ中身の集まりは寸法も同じなので、分かっている一員の寸法を全員に使う（差分かもの判定に要る）
  const dimsOf = (nd: RankedNode, m: MemberMeta): PairMeta => {
    const d = nd.members.find((x) => pixelsOf(x) > 0) ?? m;
    return { ow: d.ow, oh: d.oh, ext: m.ext };
  };
  const itemOf = (v: Visual, leader: RankedNode, nd: RankedNode, m: MemberMeta): GroupItem => ({
    member: m,
    match: v.label,
    ph: v.ph,
    dh: v.dh,
    mph: v.mph,
    gMax: v.gMax,
    variant: isVariant(v.label, v.gMax, dimsOf(leader, leader.members[0]!), dimsOf(nd, m)),
  });
  /** 番号の小さい方を先に渡す（従来の候補の組と同じ向き。判定は向きに依らない） */
  const judge = (a: number, b: number): Visual | null =>
    a < b ? classify(table, rows[a]!, rows[b]!) : classify(table, rows[b]!, rows[a]!);
  const tidy = (list: GroupItem[]) =>
    list.sort(
      (a, b) =>
        MATCH_ORDER[a.match] - MATCH_ORDER[b.match] ||
        (a.ph ?? 0) - (b.ph ?? 0) ||
        byKey(a.member.key, b.member.key),
    );
  const head = (keeper: MemberMeta): GroupItem => ({
    member: keeper,
    match: "keeper",
    variant: false,
  });
  const groups: Group[] = [];

  /**
   * 代表 i が取る相手を決める。辺を先に全部作らず、代表ごとにその場で引くので、近い物が密集して
   * いても、作業と記憶は節の数に比例する（全部の組を持つと、数千枚の密集で 2 乗になる）。
   * 上限は「まだ取られていない相手」に掛ける。取られた相手で枠を使い切ると、残りの物がどの組にも
   * 入れなくなるため。並びは段の中の種類（ほぼ同じ → 反転）、その種類の距離（反転は反転 pHash）の順。
   * 取れる相手が無かった代表は、既にできた組の頭と直接合えば、その組へ上限の分だけ足す（連鎖はしない）。
   */
  const walk = (
    tier: "dup" | "similar",
    taken: Uint8Array,
    /** まだ取られていなくても取らない節（重複の組の頭は、似ているの段で他の頭に取らせない） */
    keepOut: Uint8Array | null,
    /** 取れる相手が無くても、他の組へ足さない節 */
    noRescue: Uint8Array | null,
    onGroup: (i: number) => void,
    onMember: (j: number) => void,
    initial: (leader: RankedNode) => GroupItem[],
  ) => {
    const groupOf = new Map<number, Group>();
    const extra = new Map<number, number>();
    for (let i = 0; i < n; i++) {
      if (taken[i]) continue;
      taken[i] = 1;
      const leader = order[i]!;
      const items = initial(leader);
      // [j, 種類, 距離, 次の距離] を 4 つずつ。取れる相手（open）と、足してもらえる組の頭（hosts）
      const open: number[] = [];
      const hosts: number[] = [];
      near(
        i,
        tier,
        (j, ph, dh, mph) => {
          const host = groupOf.has(j);
          const code = tier === "dup" ? dupCode(i, j, ph, dh, mph) : similarCode(i, j, ph, dh, mph);
          if (code < 0) return;
          (host ? hosts : open).push(j, code, code === 1 ? mph : ph, code === 1 ? ph : dh);
        },
        // 取られた物・取らない物は距離を測る前に飛ばす（密集した所では、ほとんどが取られている）。
        // near の間は taken も groupOf も変わらないので、visit の中で弾くのと同じ結果になる
        (j) => !groupOf.has(j) && (taken[j] === 1 || keepOut?.[j] === 1),
      );
      let took = 0;
      for (const at of rank(open)) {
        const j = open[at]!;
        if (took >= cap) {
          crowdedNode[i] = 1;
          break;
        }
        const v = judge(i, j);
        if (!v || CODE_LABEL[open[at + 1]!] !== v.label) continue;
        const nd = order[j]!;
        const list = nd.members.map((m) => itemOf(v, leader, nd, m));
        if (!acceptable(tier, nd, list)) continue;
        taken[j] = 1;
        onMember(j);
        items.push(...list);
        took++;
      }
      if (items.length) {
        const g: Group = {
          id: leader.members[0]!.key,
          tier,
          items: [head(leader.members[0]!), ...items],
        };
        groupOf.set(i, g);
        groups.push(g);
        onGroup(i);
        continue;
      }
      if (noRescue?.[i]) continue;
      for (const at of rank(hosts)) {
        const k = hosts[at]!;
        const used = extra.get(k) ?? 0;
        if (used >= cap) {
          crowdedNode[i] = 1;
          continue;
        }
        const v = judge(k, i);
        if (!v || CODE_LABEL[hosts[at + 1]!] !== v.label) continue;
        const host = order[k]!;
        const list = leader.members.map((m) => itemOf(v, host, leader, m));
        if (!acceptable(tier, leader, list)) continue;
        groupOf.get(k)!.items.push(...list);
        extra.set(k, used + 1);
        onMember(i);
        break;
      }
    }
  };

  /** 重複の段で同じ中身の集まりを取るのは、まとめて選べる形（ほぼ同じ・差分かもでない）の時だけ */
  const acceptable = (tier: "dup" | "similar", nd: RankedNode, list: GroupItem[]) =>
    tier === "similar" ||
    nd.members.length < 2 ||
    list.every((it) => it.match === "same" && !it.variant);

  // 段ごとの判定。classify が same / mirror / similar を返す条件と同じ物を、安い順に確かめる
  // （格子は上限を超えた所で止める。密集していても、合わない相手に格子を全部比べない）
  const sums = gridSums(table);
  peakProbe?.();
  const aspect = (i: number, j: number) => aspectGap(table, rows[i]!, rows[j]!);
  const isSame = (i: number, j: number, ph: number, dh: number) =>
    ph <= same.ph &&
    dh <= same.dh &&
    aspect(i, j) <= same.asp &&
    gridWithin(table, sums, rows[i]!, rows[j]!, false, same);
  const isMirror = (i: number, j: number, mph: number) =>
    mph <= mirror.mph &&
    aspect(i, j) <= mirror.asp &&
    gridWithin(table, sums, rows[i]!, rows[j]!, true, mirror);
  const dupCode = (i: number, j: number, ph: number, dh: number, mph: number) =>
    isSame(i, j, ph, dh) ? LABEL_CODE.same : isMirror(i, j, mph) ? LABEL_CODE.mirror : -1;
  const similarCode = (i: number, j: number, ph: number, dh: number, mph: number) =>
    ph <= similar.ph &&
    dh <= similar.dh &&
    aspect(i, j) <= similar.asp &&
    colorDist(table, rows[i]!, rows[j]!, false) <= similar.col &&
    dupCode(i, j, ph, dh, mph) < 0
      ? LABEL_CODE.similar
      : -1;

  // 段ごとに取り合う。似ているの弱い辺で先に取られると、その物は本当の「ほぼ同じ」の相手に
  // 届かず、空けられる組が黙って消える（A~似~B~同~C で B が A に取られ、B/C が出ない）
  // 1 段目: 重複（同じファイル・ほぼ同じ・反転）
  /** 重複の組の頭になった節。似ているの段では頭にはなれるが、他の頭には取られない */
  const dupKeeper = new Uint8Array(n);
  /** 重複の組に一員として取られた節 */
  const dupMember = new Uint8Array(n);
  walk(
    "dup",
    new Uint8Array(n),
    null,
    null,
    (i) => {
      dupKeeper[i] = 1;
    },
    (j) => {
      dupMember[j] = 1;
    },
    (leader) =>
      leader.members
        .slice(1)
        .map((m) => ({ member: m, match: "identical" as const, variant: false })),
  );

  // 2 段目: 似ている。重複の組の一員になった物は、そちらで消す・残すが決まるので、
  // 似ているの段では頭にも一員にもしない（同じ物を 2 つの組で別の残す物に向けて消させない）。
  // 重複の組の頭は、似ている物として別の頭に取らせない（残す物を消す対象にしない）
  walk(
    "similar",
    dupMember.slice(),
    dupKeeper,
    dupKeeper,
    () => undefined,
    () => undefined,
    () => [],
  );

  for (const g of groups) g.items = [g.items[0]!, ...tidy(g.items.slice(1))];
  peakProbe?.();
  let crowded = 0;
  for (let i = 0; i < n; i++) crowded += crowdedNode[i]!;
  return { groups, crowded };
}

/** [j, 種類, 距離, 次の距離] を 4 つずつ並べた配列の、近い順の先頭位置。同じなら番号の小さい方 */
function rank(list: number[]): number[] {
  const at = Array.from({ length: list.length / 4 }, (_, k) => k * 4);
  return at.sort(
    (a, b) =>
      list[a + 1]! - list[b + 1]! ||
      list[a + 2]! - list[b + 2]! ||
      list[a + 3]! - list[b + 3]! ||
      list[a]! - list[b]!,
  );
}

/** 行ごとの 16x16 輝度の和。gridDist の shift は和の差だけで決まる（反転しても和は同じ） */
function gridSums(t: SigTable): Float64Array {
  const out = new Float64Array(t.n);
  for (let i = 0; i < t.n; i++) {
    let s = 0;
    for (let k = i * 256, e = k + 256; k < e; k++) s += t.grid[k]!;
    out[i] = s;
  }
  return out;
}

function colorDist(t: SigTable, i: number, j: number, flip: boolean): number {
  const c = t.color;
  let col = 0;
  for (let cell = 0; cell < 4; cell++) {
    const other = flip ? cell ^ 1 : cell;
    for (let ch = 0; ch < 3; ch++) {
      const d = Math.abs(c[i * 12 + cell * 3 + ch]! - c[j * 12 + other * 3 + ch]!);
      if (d > col) col = d;
    }
  }
  return col;
}

/**
 * gridDist の gMax・gSum・col が上限以内か。gridDist と同じ値で比べ、上限を超えた所で止める
 * （束ねる時の下調べ。値そのものが要る時は gridDist を使う）。
 */
function gridWithin(
  t: SigTable,
  sums: Float64Array,
  i: number,
  j: number,
  flip: boolean,
  lim: { gMax: number; gSum: number; col: number },
): boolean {
  if (colorDist(t, i, j, flip) > lim.col) return false;
  const g = t.grid;
  const ga = i * 256;
  const gb = j * 256;
  const s = sums[i]! - sums[j]!;
  const shift = s >= 0 ? Math.floor((s + 128) / 256) : -Math.floor((128 - s) / 256);
  let gSum = 0;
  for (let k = 0; k < 256; k++) {
    const d = Math.abs(g[ga + k]! - g[gb + (flip ? (k & ~15) | (15 - (k & 15)) : k)]! - shift);
    if (d > lim.gMax) return false;
    gSum += d;
    if (gSum > lim.gSum) return false;
  }
  return true;
}

/**
 * 1 つの節の近い相手を、その場で多重索引から引く。重複の段は pHash 4・反転 4、似ているの段は
 * pHash 10 まで（どちらも段の判定に要る範囲で、取りこぼさない）。反転は「自分の反転 → 相手」と
 * 「自分 → 相手の反転」の両方を引く（相手の側から引かないので、両向きとも自分で引く）。
 * 見つけた相手ごとに visit(j, ph, dh, mph) を 1 回だけ呼ぶ。skip(j) が真の相手は、距離を測らずに飛ばす。
 */
function neighbourFinder(
  t: SigTable,
  rows: Int32Array,
): (
  i: number,
  tier: "dup" | "similar",
  visit: (j: number, ph: number, dh: number, mph: number) => void,
  skip?: (j: number) => boolean,
) => void {
  const byP = buildIndex(t, rows);
  const byM = buildIndex(t, rows, true);
  const n = rows.length;
  const seen = new Int32Array(n).fill(-1);
  let stamp = 0;
  const rDupP = radiiFor(PARAMS.same.ph);
  const rDupM = radiiFor(PARAMS.mirror.mph);
  const rSim = radiiFor(PARAMS.similar.ph);
  const { pHi, pLo, dHi, dLo, mHi, mLo } = t;
  return (i, tier, visit, skip) => {
    if (!byP.eligible[i]) return;
    const q = stamp++;
    const ri = rows[i]!;
    const probe = (index: MihIndex, qH: number, qL: number, radii: number[]) => {
      for (let k = 0; k < 4; k++) {
        const c = chunkOf(qH, qL, k);
        const off = index.offsets[k]!;
        const mem = index.members[k]!;
        const probes = PROBE_COUNT[radii[k]!]!;
        for (let pi = 0; pi < probes; pi++) {
          const v = c ^ PROBES[pi]!;
          for (let s = off[v]!, e = off[v + 1]!; s < e; s++) {
            const j = mem[s]!;
            if (j === i || seen[j] === q) continue;
            seen[j] = q;
            if (skip?.(j)) continue;
            const rj = rows[j]!;
            const ph = ham64(pHi[ri]!, pLo[ri]!, pHi[rj]!, pLo[rj]!);
            const dh = ham64(dHi[ri]!, dLo[ri]!, dHi[rj]!, dLo[rj]!);
            const mph = Math.min(
              ham64(mHi[ri]!, mLo[ri]!, pHi[rj]!, pLo[rj]!),
              ham64(pHi[ri]!, pLo[ri]!, mHi[rj]!, mLo[rj]!),
            );
            visit(j, ph, dh, mph);
          }
        }
      }
    };
    if (tier === "similar") {
      probe(byP, pHi[ri]!, pLo[ri]!, rSim);
      return;
    }
    probe(byP, pHi[ri]!, pLo[ri]!, rDupP);
    probe(byP, mHi[ri]!, mLo[ri]!, rDupM);
    probe(byM, pHi[ri]!, pLo[ri]!, rDupM);
  };
}
