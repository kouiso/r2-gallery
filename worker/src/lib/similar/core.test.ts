import { describe, expect, it } from "vitest";
import {
  COS_TABLE,
  FLAG_FLAT,
  FLAG_FROM_ORIGINAL,
  FLAG_MULTI_FRAME,
  PARAMS,
  SIG_B64_LENGTH,
  SIG_BYTES,
  buildIndex,
  candidates,
  compareSigs,
  decodeSig,
  encodeSig,
  extOf,
  groupNodes,
  newSigTable,
  popcount32,
  setSig,
  sigAt,
  sigInfo,
  sigTableOf,
  vs1FromRgba,
} from "./core";
import type { GroupNodeInput, MemberMeta, PairMeta, SigTable } from "./core";

/**
 * vs1 の正解値（golden vectors）。この 16 進が署名の仕様そのもの。
 * Dart 版（flutter/test/visual_signature_test.dart）と PC ツールのテストは、この値をそのまま写して
 * 同じ入力（下の rgbaV1..V4）から同じバイト列が出ることを確かめる。
 * 値を変えてよいのはアルゴリズムの版（alg）を上げる時だけ: 保存済みの署名が全部読めなくなるため。
 * 並びは保存形式と同じ: p(8) d(8) m(8) grid(256) color(12) w,h(4) flags(1) = 297 バイト。
 */
const GOLDEN_VS1 = {
  V1: {
    p: "80264b56ad3a755f",
    d: "0000000001030204",
    m: "d5711f43f84f3106",
    grid:
      "050b11171d232a30363c42484f555b610e151b21272d333a40464c52585f656b181e252b31373d434a50565c62686f7522282e353b41474d535a60666c72787f" +
      "2c32383e454b51575d636a70767c8288363c42484e545b61676d737a80868c923f464c52585e646b71777d838a90969c494f565c62686e747b81878d9399a0a3" +
      "53595f666c72787e848b91979da3a99a5d63696f767c82888e949ba1a7ada59c676d73797f868c92989ea4abb1b0a0a670777d83898f969ca2a8aeb4b8a6aab0" +
      "7a80878d93999fa5acb2b8beafaeb4ba848a90979da3a9afb5bcc2bab1b7bec48e949aa0a7adb3b9bfc5c4b5bbc1c7cd989ea4aab0b7bdc3c9cdbbbfc5cbd1d7",
    color: "3e3951be39b03eb199beb18d",
    wh: "00400030",
    flags: "00",
  },
  V2: {
    p: "83162d740d0ef2fb",
    d: "181c6708286328ac",
    m: "d6537801585ba76d",
    grid:
      "333d696a879cacaf895e5a8e798e97b445505469aeadbd9793606c7f829c9abc62565e51bbcaaa9a8b80648179bfc0ab7a9894b8717a685da79bb4c7a071806c" +
      "919aa4a8697d687a95abb9bda27b7f93acad80989aa2743fc0cac4a7a288802d4a458082a3bba6c9a86e81948b7ca6b1575f6c80c3c4a7bcae5d7769929bacad" +
      "67896966c7e7a1aea46c81717da3de9a837e939bb59a889cb37b917fa296ab879e9cd0ca7273719d9295d3b6bc3d8b82b6b9a2afaa69666097b4c594b2808b52" +
      "517d8a95ab9fb0ca7d5fa0838e80a2bb6c666f8ec59ea9ba9f77945982b5acae888d807cc8b3a9bf85906f6b78b2c1b88b6a8b7de793acbd8b8d4b6b8acdb5ae",
    color: "7b93539492839d9486929494",
    wh: "00250017",
    flags: "00",
  },
  V3: {
    p: "aaaaaaaaaaaaaaaa",
    d: "0000190000191900",
    m: "d515555555555555",
    grid:
      "1de61de61ee51ee51ee51ee61de61de6976c976c976c976c976c976c976c976cc142c142c142c142c142c142c142c1421de61de61ee51ee51ee51ee61de61de6" +
      "ba49ba49ba49ba49ba49ba49ba49ba499d669d669d669d669d669d669d669d661de61de61ee51ee51ee51ee61de61de6dc27dc27dc26dd26dd27dc27dc27dc27" +
      "7d867d867d867d867d867d867d867d8637cc38cb38cb38cb38cb38cb37cc37cce51ee51ee61de61de61de61ee51ee51e5aa95aa95aa95ba85aa95aa95aa95aa9" +
      "5aa95aa95aa95ba85aa95aa95aa95aa9e51ee51ee61de61de61de61ee51ee51e37cc38cb38cb38cb38cb38cb37cc37cc788b788b788a798a798b788b788b788b",
    color: "818181828282818181828282",
    wh: "0200016a",
    flags: "00",
  },
  V4: {
    p: "8000000000000000",
    d: "0000000000000000",
    m: "8000000000000000",
    grid:
      "80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080" +
      "80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080" +
      "80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080" +
      "80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080",
    color: "808080808080808080808080",
    wh: "00640064",
    flags: "01",
  },
} as const;

type Px = [number, number, number, number];

function rgbaOf(w: number, h: number, f: (x: number, y: number) => Px): Uint8Array {
  const b = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) b.set(f(x, y), (y * w + x) * 4);
  }
  return b;
}

// 仕様の表の式そのまま。Dart 側も同じ式で作る
const VECTORS: Record<keyof typeof GOLDEN_VS1, () => [number, number, Uint8Array]> = {
  V1: () => [
    64,
    48,
    rgbaOf(64, 48, (x, y) => [(4 * x) & 255, (5 * y) & 255, (3 * (x + y)) & 255, 255]),
  ],
  V2: () => [
    37,
    23,
    rgbaOf(37, 23, (x, y) => [
      (x * x + 7 * y) % 256,
      ((13 * x) ^ (29 * y)) & 255,
      (x * y) % 256,
      (x + y) % 3 === 0 ? 128 : 255,
    ]),
  ],
  V3: () => [
    512,
    362,
    rgbaOf(512, 362, (x, y) => {
      const v = (((x >> 5) + (y >> 5)) & 1) === 1 ? 230 : 30;
      const c = v + (x % 7) - 3;
      return [c, c, c, 255];
    }),
  ],
  V4: () => [100, 100, rgbaOf(100, 100, () => [128, 128, 128, 255])],
};

const hex = (b: Uint8Array) => [...b].map((v) => v.toString(16).padStart(2, "0")).join("");
const unhex = (s: string) => Uint8Array.from(s.match(/../g) ?? [], (v) => parseInt(v, 16));
const goldenHex = (g: (typeof GOLDEN_VS1)[keyof typeof GOLDEN_VS1]) =>
  g.p + g.d + g.m + g.grid + g.color + g.wh + g.flags;

/**
 * 仕様の文をそのまま書いた遅い実装。本体の高速化（列の割り振り表など）が定義から外れていないかを見る。
 */
function definitionSig(w: number, h: number, rgba: Uint8Array): Uint8Array {
  const comp = (c: number, a: number) => Math.floor((c * a + 255 * (255 - a) + 127) / 255);
  const px = (x: number, y: number) => {
    const o = (y * w + x) * 4;
    const a = rgba[o + 3]!;
    const r = comp(rgba[o]!, a);
    const g = comp(rgba[o + 1]!, a);
    const b = comp(rgba[o + 2]!, a);
    return { r, g, b, y: (77 * r + 150 * g + 29 * b) >> 8 };
  };
  const grid = (gw: number, gh: number, pick: (p: ReturnType<typeof px>) => number) => {
    const out: number[] = [];
    for (let cy = 0; cy < gh; cy++) {
      for (let cx = 0; cx < gw; cx++) {
        let sum = 0;
        let count = 0;
        for (let y = 0; y < h; y++) {
          for (let x = 0; x < w; x++) {
            if (Math.floor((x * gw) / w) === cx && Math.floor((y * gh) / h) === cy) {
              sum += pick(px(x, y));
              count++;
            }
          }
        }
        out.push(
          count
            ? Math.floor(sum / count)
            : pick(px(Math.floor((cx * w) / gw), Math.floor((cy * h) / gh))),
        );
      }
    }
    return out;
  };
  const g32 = grid(32, 32, (p) => p.y);
  const g98 = grid(9, 8, (p) => p.y);
  const g16 = grid(16, 16, (p) => p.y);
  const cr = grid(2, 2, (p) => p.r);
  const cg = grid(2, 2, (p) => p.g);
  const cb = grid(2, 2, (p) => p.b);
  const C = (u: number, x: number) =>
    Math.round(16384 * Math.cos(((2 * x + 1) * u * Math.PI) / 64));
  const bitsToBytes = (bits: boolean[]) => {
    const out = new Uint8Array(8);
    bits.forEach((on, i) => {
      if (on) out[i >> 3] = out[i >> 3]! | (0x80 >> (i & 7));
    });
    return out;
  };
  const phash = (g: (y: number, x: number) => number) => {
    const R = (u: number, y: number) => {
      let s = 0;
      for (let x = 0; x < 32; x++) s += C(u, x) * g(y, x);
      return s;
    };
    const D: number[] = [];
    for (let v = 0; v < 8; v++) {
      for (let u = 0; u < 8; u++) {
        let s = 0;
        for (let y = 0; y < 32; y++) s += C(v, y) * R(u, y);
        D.push(s);
      }
    }
    const s = [...D].sort((a, b) => a - b);
    const m2 = s[31]! + s[32]!;
    return bitsToBytes(D.map((d) => 2 * d > m2));
  };
  const dbits: boolean[] = [];
  for (let r = 0; r < 8; r++)
    for (let c = 0; c < 8; c++) dbits.push(g98[r * 9 + c]! > g98[r * 9 + c + 1]!);
  let sum = 0;
  let sq = 0;
  for (const v of g32) {
    sum += v;
    sq += v * v;
  }
  const out = new Uint8Array(297);
  out.set(
    phash((y, x) => g32[y * 32 + x]!),
    0,
  );
  out.set(bitsToBytes(dbits), 8);
  out.set(
    phash((y, x) => g32[y * 32 + 31 - x]!),
    16,
  );
  out.set(g16, 24);
  for (let i = 0; i < 4; i++) out.set([cr[i]!, cg[i]!, cb[i]!], 280 + i * 3);
  out.set([w >> 8, w & 255, h >> 8, h & 255], 292);
  out[296] = 1024 * sq - sum * sum < 36 * 1024 * 1024 ? 1 : 0;
  return out;
}

describe("vs1 signature", () => {
  for (const name of Object.keys(GOLDEN_VS1) as (keyof typeof GOLDEN_VS1)[]) {
    it(`${name} matches the golden bytes`, () => {
      const [w, h, rgba] = VECTORS[name]();
      const sig = vs1FromRgba(w, h, rgba);
      expect(sig.length).toBe(SIG_BYTES);
      expect(hex(sig)).toBe(goldenHex(GOLDEN_VS1[name]));
    });
  }

  it("follows the written definition (V1, V2: alpha and grids larger than the source)", () => {
    for (const name of ["V1", "V2"] as const) {
      const [w, h, rgba] = VECTORS[name]();
      expect(hex(vs1FromRgba(w, h, rgba))).toBe(hex(definitionSig(w, h, rgba)));
    }
  });

  it("marks only the uniform image as flat", () => {
    expect(sigInfo(unhex(goldenHex(GOLDEN_VS1.V4))).flags & FLAG_FLAT).toBe(FLAG_FLAT);
    for (const name of ["V1", "V2", "V3"] as const) {
      expect(sigInfo(unhex(goldenHex(GOLDEN_VS1[name]))).flags & FLAG_FLAT).toBe(0);
    }
  });

  it("ORs only the caller flags it owns", () => {
    const [w, h, rgba] = VECTORS.V1();
    const sig = vs1FromRgba(w, h, rgba, FLAG_FROM_ORIGINAL | FLAG_MULTI_FRAME | FLAG_FLAT | 0xf0);
    expect(sig[296]).toBe(FLAG_FROM_ORIGINAL | FLAG_MULTI_FRAME);
    expect(hex(sig.subarray(0, 296))).toBe(goldenHex(GOLDEN_VS1.V1).slice(0, 592));
  });

  it("rejects bad sizes and short buffers", () => {
    expect(() => vs1FromRgba(0, 10, new Uint8Array(0))).toThrow("vs1_bad_size");
    expect(() => vs1FromRgba(65536, 1, new Uint8Array(65536 * 4))).toThrow("vs1_bad_size");
    expect(() => vs1FromRgba(2.5, 2, new Uint8Array(40))).toThrow("vs1_bad_size");
    expect(() => vs1FromRgba(4, 4, new Uint8Array(63))).toThrow("vs1_short_rgba");
  });

  it("COS_TABLE equals round(16384*cos((2x+1)uπ/64))", () => {
    expect(COS_TABLE.length).toBe(256);
    for (let u = 0; u < 8; u++) {
      for (let x = 0; x < 32; x++) {
        expect(COS_TABLE[u * 32 + x]).toBe(
          Math.round(16384 * Math.cos(((2 * x + 1) * u * Math.PI) / 64)),
        );
      }
    }
  });

  it("encodes to 396 base64url chars and decodes strictly", () => {
    for (const name of Object.keys(GOLDEN_VS1) as (keyof typeof GOLDEN_VS1)[]) {
      const sig = unhex(goldenHex(GOLDEN_VS1[name]));
      const b64 = encodeSig(sig);
      expect(b64.length).toBe(SIG_B64_LENGTH);
      expect(b64).toMatch(/^[A-Za-z0-9_-]+$/);
      expect(hex(decodeSig(b64)!)).toBe(hex(sig));
    }
    const ok = encodeSig(unhex(goldenHex(GOLDEN_VS1.V1)));
    expect(decodeSig(ok.slice(1))).toBeNull();
    expect(decodeSig(ok + "A")).toBeNull();
    expect(decodeSig(ok.slice(0, -1) + "=")).toBeNull();
    expect(decodeSig(ok.slice(0, -1) + "+")).toBeNull();
    expect(decodeSig(ok.slice(0, -1) + "é")).toBeNull();
  });

  it("round-trips through the column table", () => {
    const sigs = (Object.keys(GOLDEN_VS1) as (keyof typeof GOLDEN_VS1)[]).map((k) =>
      unhex(goldenHex(GOLDEN_VS1[k])),
    );
    const t = sigTableOf(sigs);
    sigs.forEach((s, i) => expect(hex(sigAt(t, i))).toBe(hex(s)));
    expect(t.w[2]).toBe(512);
    expect(t.h[2]).toBe(362);
    expect(t.pHi[0]).toBe(0x80264b56);
    expect(t.pLo[0]).toBe(0xad3a755f);
    expect(() => setSig(t, 0, new Uint8Array(296))).toThrow("vs1_bad_sig");
  });

  it("popcount32 counts bits of signed and unsigned 32-bit values", () => {
    expect(popcount32(0)).toBe(0);
    expect(popcount32(0xffffffff)).toBe(32);
    expect(popcount32(-1)).toBe(32);
    expect(popcount32(0x80000001)).toBe(2);
    expect(popcount32(0x12345678)).toBe(13);
  });

  it("normalises extensions from keys", () => {
    expect(extOf("a/b/C.JPEG")).toBe("jpg");
    expect(extOf("x.png")).toBe("png");
    expect(extOf("dir.v2/noext")).toBe("");
  });
});

// ---------------------------------------------------------------- 判定のしきい値

const P0 = "5a3c96e1f00f33cc";
const D0 = "0f0f33cc5a5aa5a5";
const M0 = "c3a5e1960ff03c3c";

/** hex の先頭から k bit を反転する（MSB から） */
function flip(h: string, k: number, from = 0): string {
  const b = unhex(h);
  for (let i = from; i < from + k; i++) b[i >> 3] = b[i >> 3]! ^ (0x80 >> (i & 7));
  return hex(b);
}

interface Craft {
  p?: string;
  d?: string;
  m?: string;
  grid?: ArrayLike<number>;
  color?: ArrayLike<number>;
  w?: number;
  h?: number;
  flags?: number;
}

const flatGrid = (v: number) => new Array<number>(256).fill(v);
// 左右で値が違う格子（反転の判定で、反転しないと合わないようにする）
const rampGrid = () => Array.from({ length: 256 }, (_, k) => 40 + (k & 15) * 10);
const flipGrid = (g: ArrayLike<number>) =>
  Array.from({ length: 256 }, (_, k) => g[(k & ~15) | (15 - (k & 15))]!);
const RAMP_COLOR = [10, 20, 30, 200, 210, 220, 60, 70, 80, 150, 160, 170];
const swapColor = (c: ArrayLike<number>) =>
  Array.from({ length: 12 }, (_, i) => c[((Math.floor(i / 3) ^ 1) * 3 + (i % 3)) as number]!);

function craft(o: Craft = {}): Uint8Array {
  const s = new Uint8Array(297);
  s.set(unhex(o.p ?? P0), 0);
  s.set(unhex(o.d ?? D0), 8);
  s.set(unhex(o.m ?? M0), 16);
  s.set(o.grid ?? flatGrid(100), 24);
  s.set(o.color ?? new Array<number>(12).fill(100), 280);
  const w = o.w ?? 100;
  const h = o.h ?? 100;
  s.set([w >> 8, w & 255, h >> 8, h & 255], 292);
  s[296] = o.flags ?? 0;
  return s;
}

const META: PairMeta = { ow: 0, oh: 0, ext: "jpg" };
const label = (a: Uint8Array, b: Uint8Array, ma: PairMeta = META, mb: PairMeta = META) =>
  compareSigs(a, b, ma, mb)?.label ?? null;

const hamHex = (a: string, b: string) => {
  let n = 0;
  const x = unhex(a);
  const y = unhex(b);
  for (let i = 0; i < 8; i++) n += popcount32(x[i]! ^ y[i]!);
  return n;
};

describe("pair labels", () => {
  it("uses hash constants that do not accidentally look mirrored", () => {
    expect(hamHex(P0, M0)).toBeGreaterThan(12);
  });

  const base = craft();
  const gridWith = (cells: Record<number, number>) => {
    const g = flatGrid(100);
    for (const [k, v] of Object.entries(cells)) g[Number(k)] = v;
    return g;
  };
  // 32 マス +12、32 マス -12: 明るさのずれは 0 のまま、gSum がちょうど 768
  const sum768 = () => {
    const g = flatGrid(100);
    for (let k = 0; k < 32; k++) g[k] = 88;
    for (let k = 32; k < 64; k++) g[k] = 112;
    return g;
  };

  it("same holds at every boundary at once", () => {
    const b = craft({
      p: flip(P0, 4),
      d: flip(D0, 6),
      w: 102,
      grid: sum768(),
      color: [120, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 80],
    });
    const r = compareSigs(base, b, META, META)!;
    expect(r).toMatchObject({ label: "same", ph: 4, dh: 6, gMax: 12, variant: false });
  });

  it.each([
    ["ph 5", { p: flip(P0, 5) }],
    ["dh 7", { d: flip(D0, 7) }],
    ["aspect 103:100", { w: 103 }],
    ["gMax 13", { grid: gridWith({ 0: 113 }) }],
    ["gSum 769", { grid: [...sum768().slice(0, 255), 101] }],
    ["col 21", { color: [121, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100] }],
  ] as [string, Craft][])("same fails one step past the boundary: %s → similar", (_, over) => {
    expect(label(base, craft(over))).toBe("similar");
  });

  it("brightness drift is removed before the grid check", () => {
    expect(compareSigs(base, craft({ grid: flatGrid(108) }), META, META)).toMatchObject({
      label: "same",
      gMax: 0,
    });
  });

  it("similar holds at every boundary at once", () => {
    const b = craft({
      p: flip(P0, 10),
      d: flip(D0, 12),
      w: 110,
      color: [148, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 52],
      grid: gridWith({ 5: 200 }),
    });
    expect(compareSigs(base, b, META, META)).toMatchObject({
      label: "similar",
      ph: 10,
      dh: 12,
      gMax: 100,
    });
  });

  it.each([
    ["ph 11", { p: flip(P0, 11) }],
    ["dh 13", { p: flip(P0, 5), d: flip(D0, 13) }],
    ["aspect 112:100", { p: flip(P0, 5), w: 112 }],
    ["col 49", { p: flip(P0, 5), color: [149, ...new Array<number>(11).fill(100)] }],
  ] as [string, Craft][])("similar fails one step past the boundary: %s → null", (_, over) => {
    expect(label(base, craft(over))).toBeNull();
  });

  describe("mirror", () => {
    const a = craft({ grid: rampGrid(), color: RAMP_COLOR });
    // 左右反転した絵: p と m が入れ替わり、格子と色の左右も入れ替わる
    const mirrored = (o: Craft = {}) =>
      craft({ p: M0, m: P0, grid: flipGrid(rampGrid()), color: swapColor(RAMP_COLOR), ...o });

    it("detects a horizontal flip", () => {
      expect(compareSigs(a, mirrored(), META, META)).toMatchObject({
        label: "mirror",
        mph: 0,
        gMax: 0,
        variant: false,
      });
      expect(label(mirrored(), a)).toBe("mirror");
    });

    it("holds at mph 4 / gMax 12 / col 20 / aspect 102:100", () => {
      const g = flipGrid(rampGrid());
      g[17] = g[17]! + 12;
      const c = swapColor(RAMP_COLOR);
      c[0] = c[0]! + 20;
      const b = mirrored({ p: flip(M0, 4), m: flip(P0, 4), grid: g, color: c, w: 102 });
      expect(compareSigs(a, b, META, META)).toMatchObject({ label: "mirror", mph: 4, gMax: 12 });
    });

    it.each([
      ["mph 5", { p: flip(M0, 5), m: flip(P0, 5) }],
      ["aspect 103:100", { w: 103 }],
      [
        "gMax 13",
        {
          grid: (() => {
            const g = flipGrid(rampGrid());
            g[17] = g[17]! + 13;
            return g;
          })(),
        },
      ],
      [
        "col 21",
        {
          color: (() => {
            const c = swapColor(RAMP_COLOR);
            c[0] = c[0]! + 21;
            return c;
          })(),
        },
      ],
      ["unflipped grid", { grid: rampGrid(), color: RAMP_COLOR }],
    ] as [string, Craft][])("fails past the boundary: %s", (_, over) => {
      expect(label(a, mirrored(over))).toBeNull();
    });
  });

  it("is symmetric at the half-step brightness rounding", () => {
    // 差の和がちょうど +128（shift 0.5）: 0 から遠い側へ丸めると、どちら向きでも gSum 768 で same
    const g = flatGrid(100);
    let k = 0;
    for (let i = 0; i < 62; i++) g[k++] = 96;
    for (let i = 0; i < 67; i++) g[k++] = 97;
    for (let i = 0; i < 67; i++) g[k++] = 103;
    for (let i = 0; i < 60; i++) g[k++] = 102;
    const b = craft({ grid: g });
    const ab = compareSigs(base, b, META, META);
    const ba = compareSigs(b, base, META, META);
    expect(ab).toEqual(ba);
    expect(ab?.label).toBe("same");
  });

  it("gives flat images no visual label but keeps SHA identity", () => {
    const flat = craft({ flags: FLAG_FLAT });
    expect(label(base, flat)).toBeNull();
    expect(label(flat, flat)).toBeNull();
    expect(
      compareSigs(flat, flat, { ...META, sha256: "aa" }, { ...META, sha256: "aa" }),
    ).toMatchObject({ label: "identical", ph: 0, variant: false });
  });

  it("labels equal SHA-256 identical even without signatures", () => {
    expect(compareSigs(null, null, { ...META, sha256: "x" }, { ...META, sha256: "x" })).toEqual({
      label: "identical",
      ph: 0,
      dh: 0,
      mph: 0,
      gMax: 0,
      variant: false,
    });
    expect(compareSigs(null, base, { ...META, sha256: "x" }, { ...META, sha256: "y" })).toBeNull();
    expect(compareSigs(base, base, { ...META, sha256: "" }, { ...META, sha256: "" })?.label).toBe(
      "same",
    );
  });

  describe("variant (差分かも)", () => {
    const known = (ext: string, ow = 4000, oh = 3000): PairMeta => ({ ow, oh, ext });
    const edited = (d: number) => craft({ grid: gridWith({ 40: 100 + d }) });

    it("flags same-size same-format pairs whose grid moved more than 3", () => {
      expect(compareSigs(base, edited(4), known("png"), known("png"))).toMatchObject({
        label: "same",
        gMax: 4,
        variant: true,
      });
      expect(compareSigs(base, edited(4), known("jpg"), known("JPEG"))?.variant).toBe(true);
    });

    it.each([
      ["gMax 3", 3, known("png"), known("png")],
      ["different size", 6, known("png"), known("png", 4000, 2999)],
      ["unknown size", 6, known("png", 0, 0), known("png", 0, 0)],
      ["different format", 6, known("png"), known("jpg")],
    ] as [string, number, PairMeta, PairMeta][])("is not flagged for %s", (_, d, ma, mb) => {
      expect(compareSigs(base, edited(d), ma, mb)).toMatchObject({ label: "same", variant: false });
    });

    it("never applies to similar", () => {
      const b = craft({ p: flip(P0, 6), grid: gridWith({ 40: 110 }) });
      expect(compareSigs(base, b, known("png"), known("png"))).toMatchObject({
        label: "similar",
        variant: false,
      });
    });
  });
});

// ---------------------------------------------------------------- 候補探し

function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const u32 = (rnd: () => number) => Math.floor(rnd() * 4294967296) >>> 0;

/** 64 bit（上下 32 bit）の k 個の bit を反転する。同じ bit を二度選ばない */
function flipRandom(rnd: () => number, hi: number, lo: number, k: number): [number, number] {
  const picked = new Set<number>();
  while (picked.size < k) picked.add(Math.floor(rnd() * 64));
  for (const b of picked) {
    if (b < 32) hi = (hi ^ (1 << b)) >>> 0;
    else lo = (lo ^ (1 << (b - 32))) >>> 0;
  }
  return [hi, lo];
}

describe("multi-index hashing", () => {
  it("returns exactly the brute-force pairs within distance 11 (3000 random + 3000 clustered)", () => {
    const rnd = mulberry32(20261127);
    const n = 6000;
    const t = newSigTable(n);
    const centers = Array.from({ length: 120 }, () => [u32(rnd), u32(rnd)] as [number, number]);
    for (let i = 0; i < n; i++) {
      if (i < 3000) {
        t.pHi[i] = u32(rnd);
        t.pLo[i] = u32(rnd);
        t.mHi[i] = u32(rnd);
        t.mLo[i] = u32(rnd);
        continue;
      }
      // 0〜14 bit ずらす: 11 の内と外の両方を作る。m は別の中心の近くに置き、反転の組も作る
      const c = centers[Math.floor(rnd() * centers.length)]!;
      const c2 = centers[Math.floor(rnd() * centers.length)]!;
      [t.pHi[i], t.pLo[i]] = flipRandom(rnd, c[0], c[1], Math.floor(rnd() * 15));
      [t.mHi[i], t.mLo[i]] = flipRandom(rnd, c2[0], c2[1], Math.floor(rnd() * 15));
    }
    const ham = (aH: number, aL: number, bH: number, bL: number) =>
      popcount32(aH ^ bH) + popcount32(aL ^ bL);
    const near: [key: number, ph: number, mph: number][] = [];
    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        const ph = ham(t.pHi[i]!, t.pLo[i]!, t.pHi[j]!, t.pLo[j]!);
        const mph = Math.min(
          ham(t.mHi[i]!, t.mLo[i]!, t.pHi[j]!, t.pLo[j]!),
          ham(t.pHi[i]!, t.pLo[i]!, t.mHi[j]!, t.mLo[j]!),
        );
        if (ph <= 11 || mph <= 11) near.push([i * n + j, ph, mph]);
      }
    }
    const index = buildIndex(t);
    // 既定（11/11）に加え、束ねる時の 10/4 と、向きの違う半径の組も確かめる（重複を消す規則が半径に依る）
    for (const [maxPh, maxMph] of [
      [11, 11],
      [10, 4],
      [3, 7],
      [0, 0],
    ] as const) {
      const brute = near
        .filter(([, ph, mph]) => ph <= maxPh || mph <= maxMph)
        .map(([k]) => k)
        .sort((a, b) => a - b);
      const got = candidates(t, index, maxPh, maxMph);
      const keys: number[] = [];
      let unordered = 0;
      for (let p = 0; p < got.length; p += 2) {
        if (got[p]! >= got[p + 1]!) unordered++;
        keys.push(got[p]! * n + got[p + 1]!);
      }
      expect(unordered).toBe(0);
      expect(new Set(keys).size).toBe(keys.length);
      expect(keys.sort((a, b) => a - b)).toEqual(brute);
      if (maxPh === 11) expect(brute.length).toBeGreaterThan(5000);
      else expect(brute.length).toBeGreaterThan(0);
    }
  });

  it("skips flat and unsigned rows", () => {
    const t = sigTableOf([craft(), craft(), craft({ flags: FLAG_FLAT })]);
    expect(candidates(t, buildIndex(t))).toEqual([0, 1]);
    expect(candidates(t, buildIndex(t, Int32Array.from([0, -1, 2, 1])))).toEqual([0, 3]);
  });

  it("refuses radii it cannot answer exactly", () => {
    const t = sigTableOf([craft()]);
    expect(() => candidates(t, buildIndex(t), 12, 4)).toThrow("mih_radius");
  });
});

// ---------------------------------------------------------------- 束ね方

const member = (key: string, o: Partial<MemberMeta> = {}): MemberMeta => ({
  key,
  size: 1000,
  uploaded: 1,
  ow: 0,
  oh: 0,
  ext: extOf(key),
  ...o,
});

function nodesOf(list: [MemberMeta[], Uint8Array | null][]): {
  nodes: GroupNodeInput[];
  table: SigTable;
} {
  const sigs = list.map(([, s]) => s).filter((s): s is Uint8Array => !!s);
  const table = sigTableOf(sigs);
  let row = 0;
  return {
    nodes: list.map(([members, s]) => ({ members, sig: s ? row++ : -1 })),
    table,
  };
}

const keysOf = (g: { items: { member: MemberMeta }[] }) => g.items.map((i) => i.member.key);

describe("groupNodes", () => {
  it("does not chain: A~B and B~C but A≁C gives {A,B} and leaves C alone", () => {
    const { nodes, table } = nodesOf([
      [[member("c.jpg", { ow: 500, oh: 500 })], craft({ p: flip(P0, 12) })],
      [[member("a.jpg", { ow: 2000, oh: 2000 })], craft()],
      [[member("b.jpg", { ow: 1000, oh: 1000 })], craft({ p: flip(P0, 6) })],
    ]);
    const { groups } = groupNodes(nodes, table);
    expect(groups).toHaveLength(1);
    expect(groups[0]).toMatchObject({ id: "a.jpg", tier: "similar" });
    expect(keysOf(groups[0]!)).toEqual(["a.jpg", "b.jpg"]);
    expect(groups[0]!.items.map((i) => i.match)).toEqual(["keeper", "similar"]);
  });

  it.each([
    [
      "known pixels beat unknown, even when bigger",
      [member("big.jpg", { size: 9e6 }), member("small.jpg", { ow: 100, oh: 100, size: 10 })],
      "small.jpg",
    ],
    [
      "more pixels first",
      [member("a.jpg", { ow: 100, oh: 100 }), member("b.jpg", { ow: 100, oh: 101 })],
      "b.jpg",
    ],
    [
      "PNG first at equal pixels",
      [
        member("a.jpg", { ow: 40, oh: 30, size: 9e6 }),
        member("b.png", { ow: 40, oh: 30, size: 1 }),
      ],
      "b.png",
    ],
    ["bigger file next", [member("a.jpg", { size: 10 }), member("b.jpg", { size: 11 })], "b.jpg"],
    [
      "older upload next",
      [member("a.jpg", { uploaded: 5 }), member("b.jpg", { uploaded: 4 })],
      "b.jpg",
    ],
    ["key last", [member("b.jpg"), member("a.jpg")], "a.jpg"],
  ] as [string, MemberMeta[], string][])("keeper order: %s", (_, members, keeper) => {
    const { nodes, table } = nodesOf(members.map((m) => [[m], craft()]));
    const { groups } = groupNodes(nodes, table);
    expect(groups).toHaveLength(1);
    expect(groups[0]).toMatchObject({ id: keeper, tier: "dup" });
    expect(groups[0]!.items[0]).toMatchObject({ match: "keeper", member: { key: keeper } });
    expect(groups[0]!.items.slice(1).map((i) => i.match)).toEqual(["same"]);
  });

  it("keeps the oldest member of an exact node and labels the rest identical", () => {
    const { nodes, table } = nodesOf([
      [
        [
          member("x/3.jpg", { uploaded: 3 }),
          member("x/1.jpg", { uploaded: 1 }),
          member("x/2.jpg", { uploaded: 2 }),
        ],
        craft(),
      ],
      [[member("y.jpg", { uploaded: 0, size: 10 })], craft({ p: flip(P0, 2) })],
    ]);
    const { groups } = groupNodes(nodes, table);
    expect(groups).toHaveLength(1);
    expect(keysOf(groups[0]!)).toEqual(["x/1.jpg", "x/2.jpg", "x/3.jpg", "y.jpg"]);
    expect(groups[0]!.items.map((i) => i.match)).toEqual([
      "keeper",
      "identical",
      "identical",
      "same",
    ]);
    expect(groups[0]!.items[3]).toMatchObject({ ph: 2, dh: 0 });
  });

  it("gives flat nodes no edges, but still groups their exact copies", () => {
    const flat = craft({ flags: FLAG_FLAT });
    const { nodes, table } = nodesOf([
      [[member("f1.png")], flat],
      [[member("f2.png")], flat],
      [[member("e1.png", { uploaded: 1 }), member("e2.png", { uploaded: 2 })], flat],
    ]);
    const { groups } = groupNodes(nodes, table);
    expect(groups).toHaveLength(1);
    expect(keysOf(groups[0]!)).toEqual(["e1.png", "e2.png"]);
    expect(groups[0]!.items[1]!.match).toBe("identical");
  });

  it("includes exact video nodes, which never get visual edges", () => {
    const { nodes, table } = nodesOf([
      [[member("v/b.mp4", { uploaded: 9 }), member("v/a.mp4", { uploaded: 2 })], null],
      [[member("v/lonely.mp4")], null],
      [[member("p.jpg")], craft()],
    ]);
    const { groups } = groupNodes(nodes, table);
    expect(groups).toEqual([
      {
        id: "v/a.mp4",
        tier: "dup",
        items: [
          { member: nodes[0]!.members[1], match: "keeper", variant: false },
          { member: nodes[0]!.members[0], match: "identical", variant: false },
        ],
      },
    ]);
  });

  it("marks variants per member against the keeper and splits tiers under one id", () => {
    const keeper = member("k.png", { ow: 800, oh: 600, size: 1e6 });
    const { nodes, table } = nodesOf([
      [[keeper], craft()],
      [[member("edit.png", { ow: 800, oh: 600 })], craft({ grid: flatGrid(100).fill(95, 0, 1) })],
      [[member("small.png", { ow: 400, oh: 300 })], craft({ grid: flatGrid(100).fill(95, 0, 1) })],
      [[member("mir.png", { ow: 800, oh: 600 })], craft({ p: M0, m: P0 })],
      [[member("near.png", { ow: 800, oh: 600 })], craft({ p: flip(P0, 8) })],
    ]);
    const { groups } = groupNodes(nodes, table);
    expect(groups.map((g) => [g.id, g.tier])).toEqual([
      ["k.png", "dup"],
      ["k.png", "similar"],
    ]);
    const dup = Object.fromEntries(groups[0]!.items.map((i) => [i.member.key, i]));
    expect(dup["edit.png"]).toMatchObject({ match: "same", gMax: 5, variant: true });
    expect(dup["small.png"]).toMatchObject({ match: "same", variant: false });
    expect(dup["mir.png"]).toMatchObject({ match: "mirror", variant: false });
    expect(keysOf(groups[1]!)).toEqual(["k.png", "near.png"]);
  });

  it.each([
    ["similar", craft({ p: flip(P0, 8) })],
    ["mirror", craft({ p: M0, m: P0 })],
    ["variant", craft({ grid: flatGrid(100).fill(95, 0, 1) })],
  ] as [string, Uint8Array][])(
    "keeps an exact node whole as identical when a better leader would take it as %s",
    (_, sig) => {
      // 古い方の写しは寸法が分からない（サムネの無い古い物）。同じ中身なので新しい方の寸法を使う
      const { nodes, table } = nodesOf([
        [[member("a.png", { ow: 800, oh: 600, size: 2e6 })], craft()],
        [
          [
            member("x/1.png", { uploaded: 1 }),
            member("x/2.png", { uploaded: 2, ow: 800, oh: 600 }),
          ],
          sig,
        ],
      ]);
      const { groups } = groupNodes(nodes, table);
      expect(groups.map((g) => [g.id, g.tier, keysOf(g), g.items.map((i) => i.match)])).toEqual([
        ["x/1.png", "dup", ["x/1.png", "x/2.png"], ["keeper", "identical"]],
      ]);
    },
  );

  it("lets a better leader take an exact node as plain same, every copy selectable", () => {
    const { nodes, table } = nodesOf([
      [[member("a.png", { ow: 1600, oh: 1200 })], craft()],
      [
        [member("x/1.png", { uploaded: 1 }), member("x/2.png", { uploaded: 2 })],
        craft({ p: flip(P0, 2) }),
      ],
    ]);
    const { groups } = groupNodes(nodes, table);
    expect(groups).toHaveLength(1);
    expect(keysOf(groups[0]!)).toEqual(["a.png", "x/1.png", "x/2.png"]);
    expect(groups[0]!.items.map((i) => [i.match, i.variant])).toEqual([
      ["keeper", false],
      ["same", false],
      ["same", false],
    ]);
  });

  it("does not let a weak similar edge use up a node that has a same partner (A~sim~B~same~C)", () => {
    const { nodes, table } = nodesOf([
      [[member("b.jpg", { ow: 1000, oh: 1000 })], craft({ p: flip(P0, 7) })],
      [[member("a.jpg", { ow: 3000, oh: 3000 })], craft()],
      [[member("c.jpg", { ow: 2000, oh: 2000 })], craft({ p: flip(P0, 11) })],
    ]);
    expect(label(craft(), craft({ p: flip(P0, 7) }))).toBe("similar");
    expect(label(craft({ p: flip(P0, 7) }), craft({ p: flip(P0, 11) }))).toBe("same");
    expect(label(craft(), craft({ p: flip(P0, 11) }))).toBeNull();
    const { groups } = groupNodes(nodes, table);
    // B は C の「ほぼ同じ」として重複の段に出る。似ているの段では同じ B を別の残す物に向けない
    expect(groups.map((g) => [g.id, g.tier, keysOf(g)])).toEqual([
      ["c.jpg", "dup", ["c.jpg", "b.jpg"]],
    ]);
  });

  it("caps a leader at 64 untaken partners and counts the leader as crowded", () => {
    const list: [MemberMeta[], Uint8Array][] = Array.from({ length: 70 }, (_, i) => [
      [member(`c/${String(i).padStart(2, "0")}.jpg`, { size: 1000 - i })],
      craft(),
    ]);
    const { nodes, table } = nodesOf(list);
    const { groups, crowded } = groupNodes(nodes, table);
    // 先頭の代表だけが相手を残した。残りの 5 枚は次の代表の組になる
    expect(crowded).toBe(1);
    expect(groups.map((g) => [g.id, g.tier, g.items.length])).toEqual([
      ["c/00.jpg", "dup", PARAMS.maxNeighbours + 1],
      ["c/65.jpg", "dup", 5],
    ]);
  });

  // 連写や再保存で、見た目が同じ物が 64 枚を超えて並ぶ。どの 1 枚もどこかの重複の組に入ること
  it.each([66, 100, 200])("puts every frame of a %i-shot identical burst in one dup group", (n) => {
    const list: [MemberMeta[], Uint8Array][] = Array.from({ length: n }, (_, i) => [
      [member(`b/${String(i).padStart(3, "0")}.jpg`, { size: 10_000 - i })],
      craft({ grid: rampGrid(), color: RAMP_COLOR }),
    ]);
    const { nodes, table } = nodesOf(list);
    const { groups } = groupNodes(nodes, table);
    expect(groups.every((g) => g.tier === "dup")).toBe(true);
    const seen = groups.flatMap(keysOf);
    expect(seen.length).toBe(n);
    expect(new Set(seen).size).toBe(n);
    // 組は上限で切っても、取り残しは上限の分までしか足さない
    for (const g of groups)
      expect(g.items.length).toBeLessThanOrEqual(2 * PARAMS.maxNeighbours + 1);
    for (const g of groups) {
      expect(g.items.slice(1).every((i) => i.match === "same")).toBe(true);
    }
  });

  it.each([40, 63, 80])(
    "keeps same and mirror partners when %i cheaper similar edges crowd the leader",
    (ns) => {
      const leader = member("x.png", { ow: 4000, oh: 4000 });
      const list: [MemberMeta[], Uint8Array][] = [
        [[leader], craft()],
        // pHash 4 で格子も同じ: ほぼ同じ
        [[member("s.png", { ow: 1000, oh: 1000 })], craft({ p: flip(P0, 4) })],
        // 反転: 反転 pHash で合う。pHash は大きく離れている
        [[member("m.png", { ow: 1000, oh: 1000 })], craft({ p: M0, m: P0 })],
      ];
      // pHash 1 だが格子の 1 マスが大きく違う: 似ている（ほぼ同じではない）。違うマスは 1 枚ごとに
      // 変え、似ている物同士も「ほぼ同じ」にはしない
      const nearGrid = (cell: number) => {
        const g = flatGrid(100);
        g[cell] = 200;
        return g;
      };
      const near = nearGrid(0);
      for (let i = 0; i < ns; i++) {
        list.push([
          [member(`n/${String(i).padStart(2, "0")}.png`, { ow: 500, oh: 500 })],
          craft({ p: flip(P0, 1), grid: nearGrid(i) }),
        ]);
      }
      expect(label(craft(), craft({ p: flip(P0, 4) }))).toBe("same");
      expect(label(craft(), craft({ p: M0, m: P0 }))).toBe("mirror");
      expect(label(craft(), craft({ p: flip(P0, 1), grid: near }))).toBe("similar");
      const { nodes, table } = nodesOf(list);
      const { groups } = groupNodes(nodes, table);
      const dup = groups.find((g) => g.id === "x.png" && g.tier === "dup");
      expect(dup && dup.items.map((i) => [i.member.key, i.match])).toEqual([
        ["x.png", "keeper"],
        ["s.png", "same"],
        ["m.png", "mirror"],
      ]);
      // 似ている物は似ているの段に、上限の分だけ出る
      const sim = groups.find((g) => g.id === "x.png" && g.tier === "similar");
      expect(sim!.items.length - 1).toBe(Math.min(ns, PARAMS.maxNeighbours));
    },
  );

  it("labels every pair exactly as compareSigs does (fast pre-checks agree with classify)", () => {
    const rnd = mulberry32(777);
    const base = rampGrid();
    const pick = (k: number) => Math.floor(rnd() * k);
    let checked = 0;
    const seen = new Set<string>();
    for (let n = 0; n < 4000; n++) {
      const grid = base.map((v) => Math.max(0, Math.min(255, v + pick(9) - 4)));
      // 格子の数マスを大きく動かす・全体の明るさをずらす・色を変える・縦横比を変える
      for (let c = pick(4); c > 0; c--) grid[pick(256)] = pick(256);
      const shift = pick(7) - 3;
      const flipped = rnd() < 0.3;
      const g2 = (flipped ? flipGrid(grid) : grid).map((v) =>
        Math.max(0, Math.min(255, v + shift)),
      );
      const color = RAMP_COLOR.map((v) => Math.max(0, Math.min(255, v + pick(61) - 30)));
      const a = craft({ grid: base, color: RAMP_COLOR });
      const b = craft({
        p: flipped ? flip(M0, pick(7)) : flip(P0, pick(13)),
        d: flip(D0, pick(15), 20),
        m: flipped ? flip(P0, pick(7)) : flip(M0, pick(5)),
        grid: g2,
        color: flipped ? swapColor(color) : color,
        w: 100 + pick(14) - 2,
        h: 100,
      });
      const want = compareSigs(a, b, META, META);
      const { nodes, table } = nodesOf([
        [[member("a.jpg", { ow: 2000, oh: 2000 })], a],
        [[member("b.jpg", { ow: 1000, oh: 1000 })], b],
      ]);
      const { groups } = groupNodes(nodes, table);
      expect(groups.length).toBeLessThanOrEqual(1);
      const got = groups[0]?.items[1];
      if (!want) {
        expect(got).toBeUndefined();
        continue;
      }
      expect(groups[0]!.tier).toBe(want.label === "similar" ? "similar" : "dup");
      expect(got).toMatchObject({
        match: want.label,
        ph: want.ph,
        dh: want.dh,
        mph: want.mph,
        gMax: want.gMax,
      });
      seen.add(want.label);
      checked++;
    }
    expect([...seen].sort()).toEqual(["mirror", "same", "similar"]);
    expect(checked).toBeGreaterThan(500);
  });

  it("groups 50 000 random signatures plus 500 planted groups in under 5 s", () => {
    const rnd = mulberry32(42);
    const randomCount = 50_000;
    const groupCount = 500;
    const perGroup = 5;
    const n = randomCount + groupCount * perGroup;
    const t = newSigTable(n);
    const fillRow = (i: number, base: number | null) => {
      if (base === null) {
        t.pHi[i] = u32(rnd);
        t.pLo[i] = u32(rnd);
        t.dHi[i] = u32(rnd);
        t.dLo[i] = u32(rnd);
        t.mHi[i] = u32(rnd);
        t.mLo[i] = u32(rnd);
        for (let k = 0; k < 256; k++) t.grid[i * 256 + k] = Math.floor(rnd() * 256);
        for (let k = 0; k < 12; k++) t.color[i * 12 + k] = Math.floor(rnd() * 256);
      } else {
        const k = () => Math.floor(rnd() * 3);
        [t.pHi[i], t.pLo[i]] = flipRandom(rnd, t.pHi[base]!, t.pLo[base]!, k());
        [t.dHi[i], t.dLo[i]] = flipRandom(rnd, t.dHi[base]!, t.dLo[base]!, k());
        [t.mHi[i], t.mLo[i]] = flipRandom(rnd, t.mHi[base]!, t.mLo[base]!, k());
        for (let c = 0; c < 256; c++) {
          const v = t.grid[base * 256 + c]! + Math.floor(rnd() * 5) - 2;
          t.grid[i * 256 + c] = Math.min(255, Math.max(0, v));
        }
        t.color.copyWithin(i * 12, base * 12, base * 12 + 12);
      }
      // 縦横比はすべて同じ: 縦横比で候補が減らない、いちばん重い場合を測る
      t.w[i] = 512;
      t.h[i] = 384;
    };
    const nodes: GroupNodeInput[] = [];
    for (let i = 0; i < randomCount; i++) {
      fillRow(i, null);
      nodes.push({ members: [member(`r/${i}.jpg`, { size: Math.floor(rnd() * 1e7) })], sig: i });
    }
    const planted: string[][] = [];
    let row = randomCount;
    for (let g = 0; g < groupCount; g++) {
      const base = row;
      const keys: string[] = [];
      for (let m = 0; m < perGroup; m++, row++) {
        fillRow(row, m === 0 ? null : base);
        const key = `g/${g}/${m}.jpg`;
        keys.push(key);
        nodes.push({ members: [member(key, { size: 2e7 - m })], sig: row });
      }
      planted.push(keys);
    }

    const started = performance.now();
    const startedWall = Date.now();
    const { groups, crowded } = groupNodes(nodes, t);
    const ms = Math.max(performance.now() - started, Date.now() - startedWall);
    console.log(`groupNodes: ${n} nodes, ${groups.length} groups, crowded ${crowded}, ${ms} ms`);

    expect(crowded).toBe(0);
    const dupByKeeper = new Map(groups.filter((g) => g.tier === "dup").map((g) => [g.id, g]));
    for (const keys of planted) {
      const g = dupByKeeper.get(keys[0]!);
      expect(g?.items[0]?.member.key).toBe(keys[0]);
      expect(g && keysOf(g).sort()).toEqual(keys);
    }
    expect(ms).toBeLessThan(5000);
  });
});
