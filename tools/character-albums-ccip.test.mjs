import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { describe as suite, expect, it } from "vitest";
import {
  buildCcipPlan,
  ccipInput,
  ccipMerge,
  ccipParams,
  cmykToRgbPil,
  cropBox,
  cropRgb,
  dbscan,
  decideCrop,
  decideImage,
  dropAlpha,
  eligiblePersons,
  evalMetrics,
  evaluateLoo,
  flattenWhite,
  gifTransparentColor,
  itemId,
  makeRef,
  nms,
  openSetMetrics,
  openSetSample,
  pillowAlphaRule,
  pngColorType,
  refId,
  resizePil,
  roundHalfEven,
  sampleStable,
  scoreAlbums,
  scoreImage,
  selectPersons,
  sweep,
  withThreshold,
  yoloDecode,
} from "./character-albums-ccip-core.mjs";
import { applyPlan } from "./character-albums-core.mjs";

const P = ccipParams();
const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "character-albums");

suite("ccip: 前処理", () => {
  it("同じ大きさへの resize は画素を変えない", () => {
    const src = Uint8Array.from({ length: 4 * 3 * 3 }, (_, i) => (i * 37) % 256);
    expect([...resizePil(src, 4, 3, 4, 3, "bilinear")]).toEqual([...src]);
  });

  it("一様な画像は縮小・拡大しても一様のまま（係数の和が 1）", () => {
    const src = new Uint8Array(50 * 70 * 3).fill(123);
    for (const f of ["bilinear", "bicubic"]) {
      for (const [w, h] of [
        [384, 384],
        [13, 200],
        [640, 640],
      ]) {
        const out = resizePil(src, 50, 70, w, h, f);
        expect(out.length).toBe(w * h * 3);
        expect(out.every((v) => v === 123)).toBe(true);
      }
    }
  });

  it("縮小は Pillow と同じ値になる（縮小率ぶん広げた三角窓。Pillow 13 で出した値）", () => {
    const src = Uint8Array.from([0, 0, 0, 100, 100, 100, 200, 200, 200, 50, 50, 50]);
    expect([...resizePil(src, 4, 1, 2, 1, "bilinear")]).toEqual([71, 71, 71, 121, 121, 121]);
  });

  it("縦の縮み幅が横の 2 倍を超える時は縦から先にかける（Pillow と同じ順）", () => {
    // 順序で途中の丸めが変わる画像。縦→横で 1 回ずつかけた結果と一致し、横→縦とは違う
    const w = 9;
    const h = 31;
    const src = Uint8Array.from({ length: w * h * 3 }, (_, i) => (i * 97 + (i >> 3) * 13) % 256);
    const vFirst = resizePil(resizePil(src, w, h, w, 5, "bicubic"), w, 5, 4, 5, "bicubic");
    const hFirst = resizePil(resizePil(src, w, h, 4, h, "bicubic"), 4, h, 4, 5, "bicubic");
    expect([...resizePil(src, w, h, 4, 5, "bicubic")]).toEqual([...vFirst]);
    expect([...vFirst]).not.toEqual([...hFirst]);
  });

  it("透過は白と重ね、不透明な画素はそのまま残す", () => {
    const rgba = Uint8Array.from([10, 20, 30, 255, 10, 20, 30, 0, 0, 0, 0, 128]);
    expect([...flattenWhite(rgba, 3, 1)]).toEqual([10, 20, 30, 255, 255, 255, 127, 127, 127]);
  });

  it("CCIP の入力は CHW の 3x384x384 で、白は (1-mean)/std になる", () => {
    const x = ccipInput(new Uint8Array(10 * 10 * 3).fill(255), 10, 10);
    expect(x.length).toBe(3 * 384 * 384);
    expect(x[0]).toBeCloseTo((1 - 0.48145466) / 0.26862954, 5);
    expect(x[384 * 384 * 2]).toBeCloseTo((1 - 0.40821073) / 0.27577711, 5);
  });

  it("切り出しは右端・下端を含まない矩形を取る", () => {
    const src = Uint8Array.from({ length: 4 * 4 * 3 }, (_, i) => i);
    const c = cropRgb(src, 4, { left: 1, top: 2, width: 2, height: 1 });
    expect([...c]).toEqual([...src.subarray((2 * 4 + 1) * 3, (2 * 4 + 3) * 3)]);
  });
});

suite("ccip: 画像の読み込み（imgutils の load_image と同じ透過・CMYK の扱い）", () => {
  it("PNG の色の型を IHDR から読む", () => {
    const png = readFileSync(join(FIXTURES, "decode", "p_palette_trns.png"));
    expect(pngColorType(png)).toBe(3);
    expect(pngColorType(readFileSync(join(FIXTURES, "decode", "p_rgb_trns.png")))).toBe(2);
    expect(pngColorType(readFileSync(join(FIXTURES, "decode", "p_la_real.png")))).toBe(4);
    expect(pngColorType(Buffer.from("GIF89a"))).toBeNull();
  });

  it("Pillow の mode ごとに透過の扱いを分ける", () => {
    const png = (ct) => {
      const b = Buffer.alloc(32);
      Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(b);
      b.write("IHDR", 12, "ascii");
      b[25] = ct;
      return b;
    };
    const m = (format, hasAlpha, space = "srgb") => ({ format, hasAlpha, space });
    expect(pillowAlphaRule(png(6), m("png", true))).toBe("white");
    expect(pillowAlphaRule(png(4), m("png", true))).toBe("white");
    // パレットと RGB の tRNS は paste の mask にできず、imgutils は透過を捨てて元の色を残す
    expect(pillowAlphaRule(png(3), m("png", true))).toBe("keep");
    expect(pillowAlphaRule(png(2), m("png", true))).toBe("keep");
    expect(pillowAlphaRule(png(0), m("png", true))).toBe("selfMask");
    expect(pillowAlphaRule(Buffer.from("GIF89a"), m("gif", true))).toBe("gifKey");
    expect(pillowAlphaRule(Buffer.alloc(4), m("jpeg", false, "cmyk"))).toBe("cmyk");
    expect(pillowAlphaRule(Buffer.alloc(4), m("webp", true))).toBe("white");
    expect(pillowAlphaRule(png(3), m("png", false))).toBe("white");
  });

  it("透過を捨てる時、GIF の透明な画素はパレットの透過色にする", () => {
    const rgba = Uint8Array.from([1, 2, 3, 0, 4, 5, 6, 255]);
    expect([...dropAlpha(rgba, 2, 1)]).toEqual([1, 2, 3, 4, 5, 6]);
    expect([...dropAlpha(rgba, 2, 1, [9, 9, 9])]).toEqual([9, 9, 9, 4, 5, 6]);
    expect(gifTransparentColor(readFileSync(join(FIXTURES, "decode", "g_trans.gif")))).toHaveLength(
      3,
    );
  });

  it("灰色の tRNS は画像自身の濃淡を不透明度として白へ重ねる", () => {
    // 灰 100: 255*(155) + 100*100 → 194
    const rgba = Uint8Array.from([100, 100, 100, 0]);
    expect([...flattenWhite(rgba, 1, 1, 0)]).toEqual([194, 194, 194]);
  });

  it("CMYK は Pillow の素朴な式で RGB にする", () => {
    expect([
      ...cmykToRgbPil(Uint8Array.from([0, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255]), 3, 1),
    ]).toEqual([255, 255, 255, 0, 255, 255, 0, 0, 0]);
  });

  // 期待値は imgutils 0.19.0 の load_image(mode="RGB")（wheel の関数本体をそのまま実行）と Pillow 13 で出した物
  const expected = JSON.parse(readFileSync(join(FIXTURES, "decode", "expected.json"), "utf8"));
  for (const name of readdirSync(join(FIXTURES, "decode")).filter((n) => n !== "expected.json")) {
    it(`decodeRgb は ${name}（Pillow の mode ${expected[name].pillowMode}）で imgutils と同じ画素になる`, async () => {
      const { decodeRgb } = await import("./character-albums-ccip.mjs");
      const img = await decodeRgb(readFileSync(join(FIXTURES, "decode", name)));
      const want = Buffer.from(expected[name].rgb, "base64");
      expect([img.width, img.height]).toEqual([expected[name].width, expected[name].height]);
      expect(Buffer.from(img.data).equals(want)).toBe(true);
    });
  }
});

suite("ccip: 人物検出の後処理", () => {
  it("偶数丸めは numpy の round と同じ", () => {
    expect([0.5, 1.5, 2.5, -0.5, 2.4, 2.6].map(roundHalfEven)).toEqual([0, 2, 2, -0, 2, 3]);
  });

  it("NMS は重なりの大きい低スコアの枠を消し、離れた枠は残す", () => {
    const boxes = [
      [0, 0, 10, 10],
      [1, 1, 11, 11],
      [20, 20, 30, 30],
    ];
    expect(nms(boxes, [0.9, 0.8, 0.7], 0.5)).toEqual([0, 2]);
    expect(nms(boxes, [0.7, 0.8, 0.9], 0.5)).toEqual([2, 1]);
  });

  it("YOLOv8 の出力を元画像の座標へ戻し、conf 以下を捨てる", () => {
    // 行 0..3 = cx,cy,w,h、行 4 = person のスコア。候補 3 つ
    const count = 3;
    const data = new Float32Array(5 * count);
    const set = (j, cx, cy, w, h, s) => {
      data[j] = cx;
      data[count + j] = cy;
      data[2 * count + j] = w;
      data[3 * count + j] = h;
      data[4 * count + j] = s;
    };
    set(0, 320, 320, 200, 400, 0.9);
    set(1, 322, 318, 200, 400, 0.6); // ほぼ同じ枠 → NMS で消える
    set(2, 100, 100, 50, 50, 0.2); // conf 0.3 未満
    const dets = yoloDecode(data, 5, count, {
      conf: 0.3,
      iou: 0.5,
      oldSize: [1280, 960],
      newSize: [640, 640],
    });
    expect(dets).toHaveLength(1);
    // x: (320-100)/640*1280 = 440, y: (320-200)/640*960 = 180
    expect(dets[0].box).toEqual([440, 180, 840, 780]);
    expect(dets[0].score).toBeCloseTo(0.9);
  });

  it("枠は画像の外へはみ出さない", () => {
    const data = new Float32Array([630, 5, 40, 30, 0.8]);
    const [d] = yoloDecode(data, 5, 1, {
      conf: 0.3,
      iou: 0.5,
      oldSize: [64, 64],
      newSize: [640, 640],
    });
    expect(d.box).toEqual([61, 0, 64, 2]);
  });

  it("小さすぎる人物は捨て、信頼度順に上限人数まで残す", () => {
    const dets = [
      { box: [0, 0, 5, 5], score: 0.99 },
      { box: [0, 0, 50, 50], score: 0.5 },
      { box: [50, 50, 100, 100], score: 0.7 },
    ];
    const kept = selectPersons(dets, 100, 100, { minPersonFrac: 0.01, maxPersons: 1 });
    expect(kept.map((d) => d.score)).toEqual([0.7]);
  });

  it("切り出しは枠を margin だけ広げ、画像の内側に収める", () => {
    expect(cropBox([10, 20, 110, 220], 400, 400, 0.05)).toEqual({
      left: 5,
      top: 10,
      width: 110,
      height: 220,
    });
    expect(cropBox([0, 0, 100, 100], 100, 100, 0.1)).toEqual({
      left: 0,
      top: 0,
      width: 100,
      height: 100,
    });
    // 幅 0 の枠でも 1px は残す（sharp の extract が落ちないように）
    expect(cropBox([99, 99, 99, 99], 100, 100, 0.05)).toEqual({
      left: 99,
      top: 99,
      width: 1,
      height: 1,
    });
  });
});

// 差の代わりに 1 次元の位置の距離を使う偽物。1 次元なら判定の境目を手で作れる
const pos = (x) => Float32Array.of(x);
const fakeDiff = async (feats) => (i, j) => Math.abs(feats[i][0] - feats[j][0]);
const album = (id, title, xs) => {
  const refs = xs.map((x, i) => ({ key: `${id}-${i}.png`, lib: "personal", feat: pos(x) }));
  return { id, title, refs, centroid: pos(xs.reduce((s, x) => s + x, 0) / xs.length) };
};

suite("ccip: 判定", () => {
  const params = { ...P, threshold: 0.18, high: 0.13, margin: 0.03, topK: 3 };

  it("既定の閾値は metrics.json / cluster.json から取る", () => {
    const p = ccipParams({
      metrics: { threshold: 0.2 },
      cluster: { dbscan_2: { eps: 0.1, min_samples: 3 } },
    });
    expect(p.threshold).toBe(0.2);
    expect(p.high).toBe(0.1);
    expect(p.clusterEps).toBe(0.1);
    expect(p.clusterMinSamples).toBe(3);
    expect(ccipParams({}, { margin: 0.05, threshold: undefined }).margin).toBe(0.05);
    expect(P.threshold).toBeCloseTo(0.17847511429108218, 12);
  });

  it("--threshold を下げたら high も閾値以下に決め直し、sweep の同じ閾値と確信度が揃う", () => {
    const files = {
      metrics: { threshold: 0.1785 },
      cluster: { dbscan_2: { eps: 0.1292, min_samples: 2 } },
    };
    const p = ccipParams(files, { threshold: 0.1 });
    expect(p.threshold).toBe(0.1);
    expect(p.high).toBe(0.1);
    const scoredLow = [
      { albumId: "a", albumTitle: "A", score: 0.099, centroid: 0.09 },
      { albumId: "b", albumTitle: "B", score: 0.3, centroid: 0.3 },
    ];
    expect(decideCrop(scoredLow, p).rationale).toMatch(/high の上限 0\.1 以下/);
    // 閾値を上げた時は eps（0.1292）のまま
    expect(ccipParams(files, { threshold: 0.2 }).high).toBe(0.1292);
    // sweep は withThreshold で同じ規則を使う
    const base = ccipParams(files);
    expect(withThreshold(base, 0.1, 0.03).high).toBe(p.high);
    expect(withThreshold(base, 0.2, 0.03).high).toBe(0.1292);
  });

  it("NaN や範囲外の値は通さない（通すと閾値と margin の歯止めが外れる）", () => {
    expect(() => ccipParams({}, { threshold: Number("0.18x") })).toThrow(/threshold/);
    expect(() => ccipParams({}, { margin: Number("abc") })).toThrow(/margin/);
    expect(() => ccipParams({}, { threshold: 0 })).toThrow(/threshold/);
    expect(() => ccipParams({}, { threshold: 1.5 })).toThrow(/threshold/);
    expect(() => ccipParams({}, { margin: -0.01 })).toThrow(/margin/);
    const far = [
      { albumId: "a", albumTitle: "A", score: 0.45, centroid: 0.45 },
      { albumId: "b", albumTitle: "B", score: 0.9, centroid: 0.9 },
    ];
    expect(() => decideCrop(far, { ...P, threshold: Number.NaN })).toThrow(RangeError);
    expect(() => decideCrop(far, { ...P, margin: Number.NaN })).toThrow(RangeError);
  });

  it("近い参照 topK 枚の平均で採点し、差の小さい順に並べる", () => {
    const s = scoreAlbums(
      [
        { id: "a", title: "A" },
        { id: "b", title: "B" },
      ],
      [
        [0.5, 0.1, 0.2, 0.3],
        [0.05, 0.9, 0.9],
      ],
      [0.2, 0.4],
      3,
    );
    expect(s.map((x) => x.albumId)).toEqual(["a", "b"]);
    expect(s[0].score).toBeCloseTo(0.2);
    expect(s[0].nearest).toBeCloseTo(0.1);
  });

  const scored = (best, second, centroid = best) => [
    { albumId: "a", albumTitle: "さくら", score: best, centroid },
    ...(second == null
      ? []
      : [{ albumId: "b", albumTitle: "ひなた", score: second, centroid: second }]),
  ];

  it("差が high 以下で代表も近ければ high、閾値以下なら medium", () => {
    expect(decideCrop(scored(0.1, 0.4), params)).toMatchObject({
      decision: "match",
      confidence: "high",
      albumId: "a",
    });
    expect(decideCrop(scored(0.16, 0.4), params)).toMatchObject({
      decision: "match",
      confidence: "medium",
    });
    // 近い 3 枚は似ていても代表から遠い（アルバムの一部だけ似ている）なら high にしない
    expect(decideCrop(scored(0.1, 0.4, 0.25), params).confidence).toBe("medium");
  });

  it("閾値を超えたら未マッチ、1 位と 2 位が margin 以内なら要確認", () => {
    expect(decideCrop(scored(0.19, 0.5), params).decision).toBe("unmatched");
    const r = decideCrop(scored(0.12, 0.14), params);
    expect(r.decision).toBe("review");
    expect(r.rationale).toMatch(/似た別キャラ/);
    expect(decideCrop([], params).decision).toBe("unmatched");
  });

  it("人物 0 はキャラなしにし、照合しない", () => {
    expect(decideImage([], params)).toMatchObject({ decision: "nochar", persons: 0 });
  });

  it("複数人は全員が同じアルバムの時だけ match、揃わなければ要確認", () => {
    const same = decideImage([scored(0.1, 0.4), scored(0.12, 0.4)], params);
    expect(same).toMatchObject({ decision: "match", albumId: "a", persons: 2, confidence: "high" });
    const other = [{ albumId: "b", albumTitle: "ひなた", score: 0.1, centroid: 0.1 }];
    const mixed = decideImage([scored(0.1, 0.4), other], params);
    expect(mixed.decision).toBe("review");
    expect(mixed.rationale).toMatch(/複数人/);
    // 1 人は一致、もう 1 人は知らないキャラ → 勝手に寄せない
    expect(decideImage([scored(0.1, 0.4), scored(0.5, 0.6)], params).decision).toBe("review");
    expect(decideImage([scored(0.5, 0.6), scored(0.4, 0.6)], params)).toMatchObject({
      decision: "unmatched",
      multi: true,
    });
  });

  it("上限人数で切った人物がいたら、照合した全員が揃っていても要確認", () => {
    const six = Array.from({ length: 6 }, () => scored(0.1, 0.4));
    expect(decideImage(six, params, { detected: 6 }).decision).toBe("match");
    const r = decideImage(six, params, { detected: 8 });
    expect(r).toMatchObject({ decision: "review", persons: 6, detected: 8 });
    expect(r.rationale).toMatch(/8 人中 6 人だけ照合/);
    // 1 人だけ照合した場合も同じ（maxPersons 1 で 2 人写っていた）
    expect(decideImage([scored(0.1, 0.4)], params, { detected: 2 }).decision).toBe("review");
    // 枠の数は eligiblePersons（切る前）で数える
    const dets = Array.from({ length: 8 }, (_, i) => ({
      box: [i * 10, 0, i * 10 + 9, 50],
      score: 0.5 + i / 100,
    }));
    expect(eligiblePersons(dets, 100, 100, { minPersonFrac: 0.01 })).toHaveLength(8);
    expect(selectPersons(dets, 100, 100, { minPersonFrac: 0.01, maxPersons: 6 })).toHaveLength(6);
  });

  it("対象自身は参照からも代表からも外して照合する（leave-one-out）", async () => {
    const a = album("a", "A", [0.0, 0.5, 0.6, 0.7]);
    const self = { feat: pos(0.0) };
    const withSelf = await scoreImage({
      persons: [self],
      albums: [a],
      differences: fakeDiff,
      topK: 1,
    });
    expect(withSelf[0][0].score).toBe(0);
    const loo = await scoreImage({
      persons: [self],
      albums: [a],
      selfId: "personal:a-0.png",
      differences: fakeDiff,
      topK: 1,
    });
    expect(loo[0][0].score).toBeCloseTo(0.5);
    // 代表も自分抜き（0.5,0.6,0.7 の平均に向かう）で作り直す
    expect(loo[0][0].centroid).toBeGreaterThan(0.5);
  });

  it("参照の id（makeRef）と照合する側の id（itemId）は同じ形になる", () => {
    const it = { key: "x/a.png" };
    expect(refId(makeRef(it, "personal", pos(0)))).toBe(itemId(it, "personal"));
    const other = { key: "x/a.png", lib: "shared" };
    expect(refId(makeRef(other, "personal", pos(0)))).toBe(itemId(other, "personal"));
  });

  it("ccip_merge は向きを平均して長さを元の平均に戻す", () => {
    const m = ccipMerge([Float32Array.of(2, 0), Float32Array.of(0, 4)]);
    expect(m[0]).toBeCloseTo(m[1], 6);
    expect(Math.hypot(m[0], m[1])).toBeCloseTo(3, 5);
    expect(ccipMerge([])).toBeNull();
  });
});

suite("ccip: DBSCAN と標本", () => {
  it("sklearn と同じく核から広げ、届かない点は外れ値（-1）にする", () => {
    const xs = [0, 0.05, 0.1, 1, 1.04, 5];
    const labels = dbscan(xs.length, (i, j) => Math.abs(xs[i] - xs[j]), 0.06, 2);
    expect(labels).toEqual([0, 0, 0, 1, 1, -1]);
  });

  it("min_samples を満たさない点だけの集まりは塊にしない", () => {
    const m = [
      [0, 0.1, 0.9],
      [0.1, 0, 0.9],
      [0.9, 0.9, 0],
    ];
    expect(dbscan(3, (i, j) => m[i][j], 0.12, 3)).toEqual([-1, -1, -1]);
    expect(dbscan(3, (i, j) => m[i][j], 0.12, 2)).toEqual([0, 0, -1]);
  });

  it("ハッシュ順の標本は決まっていて、枚数を増やすと先頭が保たれる", () => {
    const list = Array.from({ length: 1560 }, (_, i) => ({ key: `k${i}.png` }));
    const a = sampleStable(list, 24);
    expect(sampleStable(list, 24)).toEqual(a);
    expect(sampleStable(list, 100).slice(0, 24)).toEqual(a);
    expect(sampleStable(list.slice(0, 27), 100)).toHaveLength(27);
    // 並び順が変わっても同じ物を選ぶ
    expect(sampleStable([...list].reverse(), 24)).toEqual(a);
  });
});

suite("ccip: plan", () => {
  const params = {
    ...P,
    threshold: 0.18,
    high: 0.13,
    margin: 0.03,
    clusterEps: 0.13,
    clusterMinSamples: 2,
  };
  const result = (decision, extra = {}) => ({
    decision,
    rationale: decision,
    persons: 1,
    crops: [],
    ...extra,
  });
  const person = (x) => ({
    box: [0, 0, 10, 10],
    crop: { left: 0, top: 0, width: 10, height: 10 },
    feat: pos(x),
  });

  it("一致はアルバムへ、キャラなしは別枠、未マッチ同士の塊は仮アルバム候補、配属済みは触らない", async () => {
    const plan = await buildCcipPlan({
      lib: "personal",
      planId: "run1",
      params,
      differences: fakeDiff,
      assigned: new Set(["personal:done.png"]),
      targets: [
        {
          key: "s1.png",
          result: result("match", {
            albumId: "a1",
            albumTitle: "さくら",
            confidence: "high",
            score: 0.1,
          }),
          persons: [person(0)],
        },
        {
          key: "done.png",
          result: result("match", { albumId: "a1", albumTitle: "さくら" }),
          persons: [person(0)],
        },
        { key: "bg.png", result: result("nochar", { persons: 0 }), persons: [] },
        { key: "r.png", result: result("review"), persons: [person(0.3)] },
        { key: "n1.png", result: result("unmatched", { score: 0.5 }), persons: [person(5)] },
        { key: "n2.png", result: result("unmatched", { score: 0.5 }), persons: [person(5.05)] },
        { key: "n3.png", result: result("unmatched", { score: 0.5 }), persons: [person(9)] },
        {
          key: "m.png",
          result: result("unmatched", { multi: true }),
          persons: [person(5), person(5.01)],
        },
      ],
    });
    expect(plan.version).toBe(1);
    expect(plan.skipped.map((s) => s.key)).toEqual(["done.png"]);
    const add = plan.groups.find((g) => g.action === "add");
    expect(add).toMatchObject({ albumId: "a1", approved: false });
    expect(add.items.map((i) => i.key)).toEqual(["s1.png"]);
    const create = plan.groups.find((g) => g.action === "create");
    expect(create.title).toBe("キャラクターA（仮・run1）");
    expect(create.items.map((i) => i.key)).toEqual(["n1.png", "n2.png"]);
    expect(create.items.every((i) => i.confidence === "low")).toBe(true);
    expect(plan.nochar.map((i) => i.key)).toEqual(["bg.png"]);
    // 複数人の未マッチは束ねに混ぜない（どの人物が新キャラか分からない）
    expect(plan.unclassified.map((i) => i.key).sort()).toEqual(["m.png", "n3.png", "r.png"]);
    expect(plan.groups.every((g) => g.approved === false)).toBe(true);
    expect(JSON.stringify(plan)).not.toMatch(/"feat"/);
  });

  it("取れない・読めない画像は failed に残し、どのグループにも入れない", async () => {
    const plan = await buildCcipPlan({
      lib: "personal",
      planId: "run3",
      params,
      differences: fakeDiff,
      assigned: new Set(),
      targets: [
        { key: "broken.png", result: { decision: "error", rationale: "画像を読めない（x）" } },
        { key: "bg.png", result: result("nochar"), persons: [] },
      ],
    });
    expect(plan.failed).toEqual([
      expect.objectContaining({
        key: "broken.png",
        decision: "error",
        rationale: "画像を読めない（x）",
      }),
    ]);
    const all = [
      ...plan.groups.flatMap((g) => g.items),
      ...plan.unclassified,
      ...plan.nochar,
      ...plan.failed,
      ...plan.skipped,
    ];
    // 渡した全件がどこかのバケツにちょうど 1 回だけ入る
    expect(all.map((i) => i.key).sort()).toEqual(["bg.png", "broken.png"]);
    expect(plan.groups).toEqual([]);
  });

  it("CCIP の plan も既存の apply で承認分だけ反映でき、キャラなしは書き込まない", async () => {
    const plan = await buildCcipPlan({
      lib: "personal",
      planId: "run2",
      params,
      differences: fakeDiff,
      assigned: new Set(),
      targets: [
        {
          key: "s1.png",
          result: result("match", { albumId: "a1", albumTitle: "さくら", confidence: "high" }),
          persons: [person(0)],
        },
        { key: "bg.png", result: result("nochar"), persons: [] },
      ],
    });
    plan.groups[0].approved = true;
    const added = [];
    const api = {
      listAlbums: async () => [{ id: "a1", title: "さくら", readOnly: false }],
      createAlbum: async () => {
        throw new Error("作らない");
      },
      addItems: async (_lib, id, keys) => (
        added.push([id, keys]),
        { added: keys.length, count: keys.length }
      ),
    };
    const r = await applyPlan(plan, api);
    expect(r.map((x) => x.status)).toEqual(["applied"]);
    expect(added).toEqual([["a1", ["s1.png"]]]);
  });
});

suite("ccip: 精度評価", () => {
  const albums = [
    { id: "a", title: "さくら" },
    { id: "b", title: "ひなた" },
  ];

  it("precision / recall / 保留率と取り違え表を出す", () => {
    const records = [
      { truth: "a", decision: "match", albumId: "a" },
      { truth: "a", decision: "match", albumId: "a" },
      { truth: "a", decision: "match", albumId: "b" },
      { truth: "a", decision: "review" },
      { truth: "b", decision: "match", albumId: "b" },
      { truth: "b", decision: "nochar" },
    ];
    const m = evalMetrics(records, albums);
    const a = m.perAlbum.find((r) => r.albumId === "a");
    const b = m.perAlbum.find((r) => r.albumId === "b");
    expect(a).toMatchObject({
      n: 4,
      correct: 2,
      wrong: 1,
      abstain: 1,
      precision: 1,
      recall: 0.5,
      abstainRate: 0.25,
    });
    expect(b).toMatchObject({ n: 2, precision: 0.5, recall: 0.5, abstainRate: 0.5 });
    expect(m.confusion["さくら"]).toEqual({ さくら: 2, ひなた: 1, "(review)": 1 });
    expect(m.confusion["ひなた"]).toEqual({ ひなた: 1, "(nochar)": 1 });
    expect(m.micro).toMatchObject({ n: 6, precision: 0.75, recall: 0.5, abstainRate: 0.333 });
    // 大きいアルバムに引っ張られないアルバム平均
    expect(m.macro).toMatchObject({ precision: 0.75, recall: 0.5 });
  });

  it("両方のアルバムに入っている画像は、どちらに入れても正解", () => {
    const m = evalMetrics(
      [{ truth: "a", truths: ["a", "b"], decision: "match", albumId: "b" }],
      albums,
    );
    expect(m.micro.precision).toBe(1);
    expect(m.perAlbum.find((r) => r.albumId === "b").precision).toBe(1);
  });

  it("sweep は保存した採点から閾値・margin ごとに判定し直す", () => {
    const crop = (sa, sb) => [
      { albumId: "a", albumTitle: "さくら", score: sa, centroid: sa },
      { albumId: "b", albumTitle: "ひなた", score: sb, centroid: sb },
    ];
    const samples = [
      { truth: "a", crops: [crop(0.15, 0.3)] },
      { truth: "b", crops: [crop(0.2, 0.21)] },
    ];
    const t = sweep(
      samples,
      albums,
      { ...P, high: 0.13 },
      { thresholds: [0.1, 0.16], margins: [0, 0.05] },
    );
    expect(t).toHaveLength(4);
    const at = (th, mg) => t.find((x) => x.threshold === th && x.margin === mg);
    expect(at(0.1, 0).micro.abstainRate).toBe(1);
    expect(at(0.16, 0).micro).toMatchObject({ recall: 0.5, precision: 1 });
    expect(at(0.16, 0).openSet).toHaveProperty("falseMatchRate");
  });

  it("open-set: 自分のアルバムを候補から外し、残りへ一致と出したら誤一致として数える", () => {
    const crop = (sa, sb) =>
      [
        { albumId: "a", albumTitle: "さくら", score: sa, centroid: sa },
        { albumId: "b", albumTitle: "ひなた", score: sb, centroid: sb },
      ].sort((x, y) => x.score - y.score);
    const samples = [
      // さくら。自分を外すとひなた 0.3 → 未マッチ（正しい）
      { truth: "a", crops: [crop(0.05, 0.3)] },
      // さくら。自分を外すとひなた 0.15 → 閾値 0.18 以下で誤一致
      { truth: "a", crops: [crop(0.05, 0.15)] },
      // ひなた。自分を外すとさくら 0.4 → 未マッチ
      { truth: "b", crops: [crop(0.4, 0.06)] },
    ];
    expect(openSetSample(samples[1]).crops[0].map((x) => x.albumId)).toEqual(["b"]);
    const o = openSetMetrics(samples, albums, { ...P, threshold: 0.18, high: 0.13 });
    expect(o).toMatchObject({ n: 3, falseMatch: 1, falseMatchRate: 0.333 });
    expect(o.perAlbum.find((r) => r.albumId === "a")).toMatchObject({
      n: 2,
      falseMatch: 1,
      unmatched: 1,
    });
    expect(o.matchedTo).toEqual({ "さくら→ひなた": 1 });
    // 両方のアルバムに入っている画像は両方を外す（残りが無いので未マッチ）
    const both = openSetMetrics(
      [{ truth: "a", truths: ["a", "b"], crops: [crop(0.05, 0.06)] }],
      albums,
      P,
    );
    expect(both.falseMatch).toBe(0);
    // 閾値を緩めると誤一致が増える（sweep の open-set 列で見える）
    const t = sweep(samples, albums, P, { thresholds: [0.1, 0.35], margins: [0.03] });
    expect(t[0].openSet.falseMatchRate).toBe(0);
    expect(t[1].openSet.falseMatchRate).toBe(0.667);
  });

  // 1 次元の偽の特徴量。各画像は自分自身と差 0 になる（自分と照合したら必ず一番近い）
  const evalFixture = () => {
    const lib = "personal";
    const itemsA = [0, 0.02, 0.04, 0.06].map((x, i) => ({ key: `a${i}.png`, x }));
    const itemsB = [1, 1.02, 1.04].map((x, i) => ({ key: `b${i}.png`, x }));
    // 両方のアルバムに入っている画像（B の 1.06）
    const shared = { key: "s.png", x: 1.06 };
    itemsB.push(shared);
    const analyses = new Map(
      [...itemsA, ...itemsB].map((it) => [
        itemId(it, lib),
        { persons: [{ feat: pos(it.x) }], detected: 1 },
      ]),
    );
    const profile = (id, title, items) => {
      const refs = items.map((it) => makeRef(it, lib, pos(it.x)));
      return { id, title, refs, centroid: ccipMerge(refs.map((r) => r.feat)) };
    };
    const membership = new Map();
    for (const [id, items] of [
      ["a", [...itemsA, shared]],
      ["b", itemsB],
    ]) {
      for (const it of items) {
        const k = itemId(it, lib);
        membership.set(k, [...(membership.get(k) ?? []), id]);
      }
    }
    return {
      lib,
      refAlbums: [
        { id: "a", title: "さくら" },
        { id: "b", title: "ひなた" },
      ],
      evalSets: new Map([
        ["a", [...itemsA, shared]],
        ["b", itemsB],
      ]),
      profiles: [profile("a", "さくら", [...itemsA, shared]), profile("b", "ひなた", itemsB)],
      analyses,
      membership,
    };
  };

  it("eval の本体は自分自身と照合しない（参照と照合側の id が揃っている）", async () => {
    const f = evalFixture();
    // topK 1 なので、自分自身を外し損ねると score が必ず 0 になる
    const params = { ...P, topK: 1, threshold: 0.5, high: 0.3, margin: 0 };
    const { records, samples } = await evaluateLoo({ ...f, differences: fakeDiff, params });
    for (const s of samples) {
      for (const c of s.crops) expect(c.every((a) => a.score > 0)).toBe(true);
    }
    expect(records.every((r) => r.score > 0)).toBe(true);
    expect(records.filter((r) => r.decision === "match").length).toBeGreaterThan(0);
  });

  it("2 つの参照アルバムに入っている画像は 1 回だけ評価し、取れなかった画像は failed に出す", async () => {
    const f = evalFixture();
    f.analyses.delete(itemId({ key: "b1.png" }, f.lib));
    const params = { ...P, topK: 1, threshold: 0.5, high: 0.3, margin: 0 };
    const { records, duplicates, failed } = await evaluateLoo({
      ...f,
      differences: fakeDiff,
      params,
    });
    expect(records.filter((r) => r.key === "s.png")).toHaveLength(1);
    expect(records.find((r) => r.key === "s.png")).toMatchObject({
      truth: "a",
      truths: ["a", "b"],
    });
    expect(duplicates).toEqual([{ key: "s.png", albumId: "b" }]);
    expect(failed).toEqual([{ key: "b1.png", albumId: "b" }]);
    const m = evalMetrics(records, f.refAlbums);
    // a は 4 枚 + 共有 1 枚、b は共有を除いた 3 枚から取れなかった 1 枚を引いた 2 枚
    expect(m.perAlbum.find((r) => r.albumId === "a").n).toBe(5);
    expect(m.perAlbum.find((r) => r.albumId === "b").n).toBe(2);
    expect(m.micro.n).toBe(7);
  });
});

// モデルが手元にある時だけ走る。CI にはモデルが無いので飛ばす（150MB を CI で落とさない）
const MODEL_DIR = process.env.R2G_MODEL_DIR || join(homedir(), ".cache", "r2g-models");
const hasModels = [
  "ccip-caformer-24-randaug-pruned/model_feat.onnx",
  "ccip-caformer-24-randaug-pruned/model_metrics.onnx",
  "ccip-caformer-24-randaug-pruned/metrics.json",
  "ccip-caformer-24-randaug-pruned/cluster.json",
  "anime_person_detection/person_detect_v1.1_m/model.onnx",
].every((f) => existsSync(join(MODEL_DIR, f)));

suite.skipIf(!hasModels)("ccip: 実モデル", () => {
  // reference.json は imgutils 0.19.0 の関数本体（wheel から取り出した物）と Python の onnxruntime で出した値。
  // 検出の後処理や前処理が崩れると、枠か特徴量のどちらかがここでずれる
  it("人物の写った画像で、検出の枠・切り出し・特徴量・差が imgutils の値と合う", async () => {
    const { openCcip } = await import("./character-albums-ccip.mjs");
    const engine = await openCcip({ modelDir: MODEL_DIR, offline: true });
    const ref = JSON.parse(readFileSync(join(FIXTURES, "reference.json"), "utf8"));
    const a = await engine.analyze(readFileSync(join(FIXTURES, "person.webp")));
    expect([a.width, a.height]).toEqual(ref.size);
    expect(a.persons.map((p) => p.box)).toEqual(ref.boxes);
    expect(a.detected).toBe(ref.boxes.length);
    expect(a.persons[0].score).toBeCloseTo(ref.scores[0], 2);
    expect(a.persons[0].crop).toEqual(ref.crop);
    const crop = a.persons[0].feat;
    ref.cropFeatHead.forEach((v, i) => expect(Math.abs(crop[i] - v)).toBeLessThan(1e-3));
    expect(Math.abs(Math.hypot(...crop) - ref.cropFeatNorm)).toBeLessThan(1e-2);
    const [full] = await engine.embed([ccipInput(a.rgb, a.width, a.height)]);
    ref.fullFeatHead.forEach((v, i) => expect(Math.abs(full[i] - v)).toBeLessThan(1e-3));
    const d = await engine.differences([crop, full]);
    expect(Math.abs(d(0, 1) - ref.diffCropFull)).toBeLessThan(1e-3);
  }, 60_000);

  it("キャラのいない合成画像は人物 0（キャラなし）で、特徴量は 768 次元", async () => {
    const { openCcip } = await import("./character-albums-ccip.mjs");
    const engine = await openCcip({ modelDir: MODEL_DIR, offline: true });
    const raw = Buffer.alloc(320 * 240 * 3);
    for (let i = 0; i < raw.length; i++) raw[i] = (i * 7) % 251;
    const png = await sharp(raw, { raw: { width: 320, height: 240, channels: 3 } })
      .png()
      .toBuffer();
    const a = await engine.analyze(png);
    expect(a.persons).toEqual([]);
    const [f] = await engine.embed([ccipInput(a.rgb, a.width, a.height)]);
    expect(f.length).toBe(768);
    const d = await engine.differences([f, f]);
    expect(d(0, 1)).toBeLessThan(1e-4);
  }, 60_000);
});
