/**
 * CCIP（deepghs のアニメキャラ識別モデル）でキャラ別アルバムを仕分ける純粋ロジック。
 * ONNX の実行やファイル・通信は character-albums-ccip.mjs が受け持ち、ここは数値の処理だけにする。
 * こうしておくと、モデルの無い CI でも前処理・検出の後処理・判定・束ね・評価を単体テストできる。
 *
 * 前処理と後処理は dghs-imgutils 0.19.0（imgutils/metrics/ccip.py, imgutils/generic/yolo.py）に合わせる。
 * 学習時と違う縮小や正規化をすると、閾値（metrics.json）がそのままでは使えなくなるため。
 */
import { createHash, randomUUID } from "node:crypto";

export const CCIP_MODEL = "ccip-caformer-24-randaug-pruned";
export const CCIP_SIZE = 384;
export const CCIP_MEAN = [0.48145466, 0.4578275, 0.40821073];
export const CCIP_STD = [0.26862954, 0.26130258, 0.27577711];
export const DETECTOR_NAME = "person_detect_v1.1_m";
export const DETECTOR_SIZE = 640;

// metrics.json / cluster.json が読めない時の控え。値は deepghs/ccip_onnx の同モデルの物
export const CCIP_FALLBACK = Object.freeze({
  threshold: 0.17847511429108218,
  clusterEps: 0.12921094122454668,
  clusterMinSamples: 2,
});

/**
 * 判定に使う値をまとめる。既定値はモデル付属の評価値から取り、勘で決めた数は理由を添える。
 * - threshold: 同キャラとみなす差の上限。deepghs の評価で F1 が最大（0.917）になった値
 * - high: 確信度 high の上限。cluster.json の dbscan_2 の eps（同キャラ同士が密に集まる距離）
 * - margin: 1 位と 2 位のアルバムの差がこれ未満なら要確認。似た別キャラ（髪色の近い 2 人）を
 *   勝手に寄せないための安全側の幅。eval の sweep で実データに合わせて変える前提
 * - topK: アルバムごとの近い参照何枚の平均で測るか。1 枚だけ似た参照に引っ張られないため 3
 * - detConf / detIou: imgutils の detect_person の既定（conf 0.3, iou 0.5）
 * - minPersonFrac: 画像面積に対してこれ未満の人物枠は捨てる。512px のサムネで約 51px 角未満は
 *   CCIP の入力（384px）に引き伸ばしても顔が判別できず、背景の小さな人影で複数人扱いになるため
 * - cropMargin: 人物枠の外へ広げる割合。検出枠が髪の先や頭頂を切りがちなため少しだけ広げる
 * - maxPersons: 1 枚で照合する人数の上限。群衆画は要確認に回るので全員を測る意味が薄い
 */
export function ccipParams({ metrics, cluster } = {}, overrides = {}) {
  const threshold = metrics?.threshold ?? CCIP_FALLBACK.threshold;
  const eps = cluster?.dbscan_2?.eps ?? CCIP_FALLBACK.clusterEps;
  return {
    threshold,
    high: Math.min(eps, threshold),
    margin: 0.03,
    topK: 3,
    clusterEps: eps,
    clusterMinSamples: cluster?.dbscan_2?.min_samples ?? CCIP_FALLBACK.clusterMinSamples,
    detConf: 0.3,
    detIou: 0.5,
    minPersonFrac: 0.01,
    cropMargin: 0.05,
    maxPersons: 6,
    ...Object.fromEntries(Object.entries(overrides).filter(([, v]) => v !== undefined)),
  };
}

// ---------------------------------------------------------------------------
// 画素の前処理（Pillow の Image.resize と同じ整数演算）
// ---------------------------------------------------------------------------

const FILTERS = {
  bilinear: {
    support: 1,
    fn: (x) => {
      const a = Math.abs(x);
      return a < 1 ? 1 - a : 0;
    },
  },
  bicubic: {
    support: 2,
    fn: (x) => {
      const a = -0.5;
      const v = Math.abs(x);
      if (v < 1) return ((a + 2) * v - (a + 3)) * v * v + 1;
      if (v < 2) return (((v - 5) * v + 8) * v - 4) * a;
      return 0;
    },
  },
};
// Pillow の 8bit 縮小は係数を 22bit の固定小数点にして丸める。ここを浮動小数で済ませると
// 画素が ±1 ずれ、特徴量の一致検証（max abs diff < 1e-3）が通らない
const PRECISION_BITS = 32 - 8 - 2;
const ONE = 2 ** PRECISION_BITS;
const HALF = 2 ** (PRECISION_BITS - 1);

function coefficients(inSize, outSize, filter) {
  const scale = inSize / outSize;
  const filterscale = Math.max(scale, 1);
  const support = filter.support * filterscale;
  const ksize = Math.ceil(support) * 2 + 1;
  const bounds = new Int32Array(outSize * 2);
  const kk = new Int32Array(outSize * ksize);
  const w = new Float64Array(ksize);
  for (let xx = 0; xx < outSize; xx++) {
    const center = (xx + 0.5) * scale;
    const ss = 1 / filterscale;
    let xmin = Math.trunc(center - support + 0.5);
    if (xmin < 0) xmin = 0;
    let xmax = Math.trunc(center + support + 0.5);
    if (xmax > inSize) xmax = inSize;
    xmax -= xmin;
    let ww = 0;
    for (let x = 0; x < xmax; x++) {
      w[x] = filter.fn((x + xmin - center + 0.5) * ss);
      ww += w[x];
    }
    for (let x = 0; x < xmax; x++) {
      const v = ww !== 0 ? w[x] / ww : w[x];
      kk[xx * ksize + x] = v < 0 ? Math.trunc(-0.5 + v * ONE) : Math.trunc(0.5 + v * ONE);
    }
    bounds[xx * 2] = xmin;
    bounds[xx * 2 + 1] = xmax;
  }
  return { ksize, bounds, kk };
}

const clip8 = (ss) => {
  const v = ss >> PRECISION_BITS;
  return v < 0 ? 0 : v > 255 ? 255 : v;
};

/**
 * RGB（3 チャンネル詰め）の画素を Pillow の resize と同じ結果になるよう縮小・拡大する。
 * filter は "bilinear"（CCIP）か "bicubic"（YOLO。Pillow の既定）。
 */
export function resizePil(src, width, height, outW, outH, filterName) {
  const filter = FILTERS[filterName];
  if (!filter) throw new Error(`unknown filter ${filterName}`);
  // Pillow（11 以降の Resample.c）は、縦の縮み幅が横の 2 倍を超える時だけ縦から先にかける。
  // 順序で途中の丸めが変わり画素が ±1 ずれるので、同じ規則にする
  const verticalFirst = height - outH > 0 && height - outH > (width - outW) * 2;
  if (verticalFirst && outW !== width) {
    const v = resizePil(src, width, height, width, outH, filterName);
    return resizePil(v, width, outH, outW, outH, filterName);
  }
  let cur = src;
  let curW = width;
  if (outW !== width) {
    const { ksize, bounds, kk } = coefficients(width, outW, filter);
    const out = new Uint8Array(outW * height * 3);
    for (let y = 0; y < height; y++) {
      const row = y * width * 3;
      for (let xx = 0; xx < outW; xx++) {
        const xmin = bounds[xx * 2];
        const xmax = bounds[xx * 2 + 1];
        const k = xx * ksize;
        let s0 = HALF;
        let s1 = HALF;
        let s2 = HALF;
        for (let x = 0; x < xmax; x++) {
          const p = row + (x + xmin) * 3;
          const c = kk[k + x];
          s0 += cur[p] * c;
          s1 += cur[p + 1] * c;
          s2 += cur[p + 2] * c;
        }
        const o = (y * outW + xx) * 3;
        out[o] = clip8(s0);
        out[o + 1] = clip8(s1);
        out[o + 2] = clip8(s2);
      }
    }
    cur = out;
    curW = outW;
  }
  if (outH !== height) {
    const { ksize, bounds, kk } = coefficients(height, outH, filter);
    const out = new Uint8Array(curW * outH * 3);
    for (let yy = 0; yy < outH; yy++) {
      const ymin = bounds[yy * 2];
      const ymax = bounds[yy * 2 + 1];
      const k = yy * ksize;
      for (let xx = 0; xx < curW; xx++) {
        let s0 = HALF;
        let s1 = HALF;
        let s2 = HALF;
        for (let y = 0; y < ymax; y++) {
          const p = ((y + ymin) * curW + xx) * 3;
          const c = kk[k + y];
          s0 += cur[p] * c;
          s1 += cur[p + 1] * c;
          s2 += cur[p + 2] * c;
        }
        const o = (yy * curW + xx) * 3;
        out[o] = clip8(s0);
        out[o + 1] = clip8(s1);
        out[o + 2] = clip8(s2);
      }
    }
    cur = out;
  }
  return cur === src ? new Uint8Array(src) : cur;
}

/**
 * RGBA を白背景に重ねて RGB にする。imgutils の add_background_for_rgba（Pillow の paste）と同じく
 * 整数の DIV255 で丸める。sharp の flatten は浮動小数で合成するため ±1 ずれる
 */
export function flattenWhite(rgba, width, height) {
  const n = width * height;
  const out = new Uint8Array(n * 3);
  for (let i = 0; i < n; i++) {
    const a = rgba[i * 4 + 3];
    for (let c = 0; c < 3; c++) {
      const tmp = 255 * (255 - a) + rgba[i * 4 + c] * a + 128;
      out[i * 3 + c] = ((tmp >> 8) + tmp) >> 8;
    }
  }
  return out;
}

/** RGB 画素の矩形を切り出す（Pillow の crop と同じく右端・下端は含まない）。 */
export function cropRgb(src, width, { left, top, width: w, height: h }) {
  const out = new Uint8Array(w * h * 3);
  for (let y = 0; y < h; y++) {
    const from = ((top + y) * width + left) * 3;
    out.set(src.subarray(from, from + w * 3), y * w * 3);
  }
  return out;
}

/** CCIP の入力: 384x384 BILINEAR → CHW → /255 → CLIP の mean/std で正規化。 */
export function ccipInput(rgb, width, height) {
  const px = resizePil(rgb, width, height, CCIP_SIZE, CCIP_SIZE, "bilinear");
  const n = CCIP_SIZE * CCIP_SIZE;
  const out = new Float32Array(3 * n);
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < 3; c++) {
      // imgutils は float32 で /255 してから float64 の mean/std で割り、最後に float32 へ戻す
      const v = Math.fround(px[i * 3 + c] / 255);
      out[c * n + i] = (v - CCIP_MEAN[c]) / CCIP_STD[c];
    }
  }
  return out;
}

/** YOLO の入力: imgutils は letterbox せず正方形へそのまま引き伸ばす（Pillow 既定の BICUBIC）。 */
export function yoloInput(rgb, width, height, size = DETECTOR_SIZE) {
  const px = resizePil(rgb, width, height, size, size, "bicubic");
  const n = size * size;
  const out = new Float32Array(3 * n);
  for (let i = 0; i < n; i++) {
    out[i] = px[i * 3] / 255;
    out[n + i] = px[i * 3 + 1] / 255;
    out[2 * n + i] = px[i * 3 + 2] / 255;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 人物検出の後処理（YOLOv8 の [4+クラス数, 候補数] 出力）
// ---------------------------------------------------------------------------

/** numpy の round と同じ偶数丸め。0.5 ちょうどの座標で imgutils と 1px ずれないように。 */
export function roundHalfEven(x) {
  const r = Math.round(x);
  return Math.abs(x % 1) === 0.5 && r % 2 !== 0 ? r - 1 : r;
}

/** imgutils の _yolo_nms と同じ。面積に +1 する古い流儀もそのまま真似る。 */
export function nms(boxes, scores, iouThreshold) {
  const order = scores
    .map((s, i) => [s, i])
    .sort((a, b) => b[0] - a[0] || b[1] - a[1])
    .map((p) => p[1]);
  const area = (b) => (b[2] - b[0] + 1) * (b[3] - b[1] + 1);
  const keep = [];
  let rest = order;
  while (rest.length) {
    const i = rest[0];
    keep.push(i);
    const bi = boxes[i];
    rest = rest.slice(1).filter((j) => {
      const bj = boxes[j];
      const w = Math.max(0, Math.min(bi[2], bj[2]) - Math.max(bi[0], bj[0]) + 1);
      const h = Math.max(0, Math.min(bi[3], bj[3]) - Math.max(bi[1], bj[1]) + 1);
      const inter = w * h;
      return inter / (area(bi) + area(bj) - inter) <= iouThreshold;
    });
  }
  return keep;
}

/**
 * YOLOv8 の出力（行 0..3 が中心 xywh、行 4.. がクラス別スコア）を元画像の座標の枠にする。
 * data は [rows, count] の行優先。
 */
export function yoloDecode(data, rows, count, { conf, iou, oldSize, newSize }) {
  const boxes = [];
  const scores = [];
  const labels = [];
  for (let j = 0; j < count; j++) {
    let best = -Infinity;
    let label = 0;
    for (let r = 4; r < rows; r++) {
      const s = data[r * count + j];
      if (s > best) {
        best = s;
        label = r - 4;
      }
    }
    if (!(best > conf)) continue;
    const cx = data[j];
    const cy = data[count + j];
    const w = data[2 * count + j];
    const h = data[3 * count + j];
    boxes.push([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2]);
    scores.push(best);
    labels.push(label);
  }
  const [oldW, oldH] = oldSize;
  const [newW, newH] = newSize;
  const fix = (v, newLen, oldLen) =>
    roundHalfEven(Math.min(Math.max((v / newLen) * oldLen, 0), oldLen));
  return nms(boxes, scores, iou).map((i) => ({
    box: [
      fix(boxes[i][0], newW, oldW),
      fix(boxes[i][1], newH, oldH),
      fix(boxes[i][2], newW, oldW),
      fix(boxes[i][3], newH, oldH),
    ],
    label: labels[i],
    score: scores[i],
  }));
}

/** 小さすぎる枠を捨て、信頼度の高い順に上限人数まで残す。 */
export function selectPersons(detections, width, height, { minPersonFrac, maxPersons }) {
  const total = width * height;
  return detections
    .filter((d) => {
      const [x0, y0, x1, y1] = d.box;
      return x1 > x0 && y1 > y0 && ((x1 - x0) * (y1 - y0)) / total >= minPersonFrac;
    })
    .sort((a, b) => b.score - a.score)
    .slice(0, maxPersons);
}

/** 人物枠を margin の割合だけ広げ、画像の内側に収めた切り出し矩形にする。 */
export function cropBox([x0, y0, x1, y1], width, height, margin) {
  const mx = Math.round((x1 - x0) * margin);
  const my = Math.round((y1 - y0) * margin);
  const left = Math.min(Math.max(0, x0 - mx), width - 1);
  const top = Math.min(Math.max(0, y0 - my), height - 1);
  const right = Math.max(Math.min(width, x1 + mx), left + 1);
  const bottom = Math.max(Math.min(height, y1 + my), top + 1);
  return { left, top, width: right - left, height: bottom - top };
}

// ---------------------------------------------------------------------------
// 参照アルバムの輪郭と照合
// ---------------------------------------------------------------------------

/** imgutils の ccip_merge と同じ。長さを揃えて平均し、元の長さの平均へ戻す。 */
export function ccipMerge(feats) {
  if (!feats.length) return null;
  const dim = feats[0].length;
  const sum = new Float64Array(dim);
  let lenSum = 0;
  for (const f of feats) {
    let n = 0;
    for (let i = 0; i < dim; i++) n += f[i] * f[i];
    n = Math.sqrt(n) || 1;
    lenSum += n;
    for (let i = 0; i < dim; i++) sum[i] += f[i] / n;
  }
  let m = 0;
  for (let i = 0; i < dim; i++) m += (sum[i] / feats.length) ** 2;
  m = Math.sqrt(m) || 1;
  const scale = lenSum / feats.length / m;
  const out = new Float32Array(dim);
  for (let i = 0; i < dim; i++) out[i] = (sum[i] / feats.length) * scale;
  return out;
}

export const refId = (r) => `${r.lib ?? ""}:${r.key}`;

/**
 * 1 人分の切り出しを、各アルバムの参照との差で採点する。差は小さいほど同キャラに近い。
 * diffs: (refIndexInAlbum, album) => number、centroidDiff: (album) => number を渡す。
 * score は近い topK 枚の平均。centroid は ccip_merge した代表との差（1 枚だけ似ている時の歯止め）。
 */
export function scoreAlbums(albums, refDiffs, centroidDiffs, topK) {
  return albums
    .map((a, ai) => {
      const ds = [...refDiffs[ai]].sort((x, y) => x - y);
      if (!ds.length) return null;
      const top = ds.slice(0, topK);
      return {
        albumId: a.id,
        albumTitle: a.title,
        score: top.reduce((s, x) => s + x, 0) / top.length,
        nearest: ds[0],
        centroid: centroidDiffs[ai],
      };
    })
    .filter(Boolean)
    .sort((x, y) => x.score - y.score);
}

/**
 * 1 枚の画像（人物ごとの特徴量）を全参照アルバムと照合する。
 * selfId（`${lib}:${key}`）と同じ参照は外し、代表（centroid）もその参照抜きで作り直す。
 * 対象自身と照合すると差がほぼ 0 になり、評価でも本番でも確信度が水増しされるため。
 * differences: async (feats) => (i, j) => number（CCIP の metric モデル）
 */
export async function scoreImage({ persons, albums, selfId = null, differences, topK }) {
  if (!persons.length) return [];
  const vectors = persons.map((p) => p.feat);
  const refIdx = [];
  const centIdx = [];
  for (const a of albums) {
    const refs = selfId ? a.refs.filter((r) => refId(r) !== selfId) : a.refs;
    refIdx.push(refs.map((r) => vectors.push(r.feat) - 1));
    const centroid =
      refs.length === a.refs.length ? a.centroid : ccipMerge(refs.map((r) => r.feat));
    centIdx.push(centroid ? vectors.push(centroid) - 1 : -1);
  }
  const d = await differences(vectors);
  return persons.map((_, ci) =>
    scoreAlbums(
      albums,
      refIdx.map((rs) => rs.map((ri) => d(ci, ri))),
      centIdx.map((k) => (k < 0 ? null : d(ci, k))),
      topK,
    ),
  );
}

const r4 = (x) => (x == null ? null : Math.round(x * 10000) / 10000);

/** 1 人分の採点結果から判定する。ここで決めるのは「どのアルバムか／保留か」だけ。 */
export function decideCrop(scored, params) {
  const [best, second] = scored;
  if (!best) return { decision: "unmatched", rationale: "照合できる参照アルバムがない" };
  const base = {
    albumId: best.albumId,
    albumTitle: best.albumTitle,
    score: r4(best.score),
    centroid: r4(best.centroid),
    second: second ? { albumTitle: second.albumTitle, score: r4(second.score) } : null,
  };
  if (best.score > params.threshold) {
    return {
      ...base,
      decision: "unmatched",
      rationale: `どの参照アルバムとも差が閾値 ${r4(params.threshold)} より大きい（最小は「${best.albumTitle}」の ${r4(best.score)}）。新キャラまたは判別不能`,
    };
  }
  if (second && second.score - best.score < params.margin) {
    return {
      ...base,
      decision: "review",
      rationale: `「${best.albumTitle}」${r4(best.score)} と「${second.albumTitle}」${r4(second.score)} の差が ${r4(params.margin)} 未満。似た別キャラの可能性`,
    };
  }
  if (best.score <= params.high && best.centroid != null && best.centroid <= params.threshold) {
    return {
      ...base,
      decision: "match",
      confidence: "high",
      rationale: `CCIP の差 ${r4(best.score)}（近い ${params.topK} 枚の平均）が high の上限 ${r4(params.high)} 以下で、代表との差 ${r4(best.centroid)} も閾値以下`,
    };
  }
  return {
    ...base,
    decision: "match",
    confidence: "medium",
    rationale: `CCIP の差 ${r4(best.score)} は閾値 ${r4(params.threshold)} 以下だが high の上限 ${r4(params.high)} を超えるか代表から遠い。目視で確認する`,
  };
}

/**
 * 画像 1 枚の判定。crops は切り出しごとの採点結果（scoreAlbums の戻り値）の配列。
 * 人物 0 → キャラなし（照合しない）。CCIP はキャラの写っていない絵同士をほぼ同一とみなすので、
 * ここで止めないと背景画やテキスト画像が 1 つのキャラにまとまってしまう。
 * 複数人 → 全員が同じアルバムに match した時だけ match、それ以外は要確認。
 */
export function decideImage(crops, params) {
  if (!crops.length) {
    return {
      decision: "nochar",
      rationale: "人物が検出されない（キャラなし）。CCIP では照合しない",
      persons: 0,
      crops: [],
    };
  }
  const decided = crops.map((c) => decideCrop(c, params));
  if (decided.length === 1) return { ...decided[0], persons: 1, crops: decided };
  const persons = decided.length;
  const matched = decided.filter((d) => d.decision === "match");
  const albumIds = new Set(matched.map((d) => d.albumId));
  if (matched.length === persons && albumIds.size === 1) {
    const worst = matched.reduce((w, d) => (d.score > w.score ? d : w));
    return {
      ...worst,
      confidence: matched.every((d) => d.confidence === "high") ? "high" : "medium",
      rationale: `${persons} 人とも「${worst.albumTitle}」に近い（最大の差 ${worst.score}）。同じキャラの複数ポーズか確認する`,
      persons,
      crops: decided,
    };
  }
  if (!matched.length && decided.every((d) => d.decision === "unmatched")) {
    return {
      decision: "unmatched",
      multi: true,
      score: Math.min(...decided.map((d) => d.score ?? Infinity)),
      rationale: `${persons} 人写っているが、どの参照アルバムにも近くない`,
      persons,
      crops: decided,
    };
  }
  const names = decided.map((d) =>
    d.decision === "match"
      ? `「${d.albumTitle}」`
      : d.decision === "review"
        ? `要確認(${d.albumTitle})`
        : "未知",
  );
  return {
    decision: "review",
    albumId: matched[0]?.albumId,
    albumTitle: matched[0]?.albumTitle,
    score: r4(Math.min(...decided.map((d) => d.score ?? Infinity))),
    rationale: `複数人（${persons} 人: ${names.join(" / ")}）で判定が揃わない`,
    persons,
    crops: decided,
  };
}

// ---------------------------------------------------------------------------
// 束ね（DBSCAN）と標本の取り方
// ---------------------------------------------------------------------------

/**
 * sklearn の DBSCAN（metric=precomputed 相当）と同じ規則。dist(i, j) は差。
 * 近傍は自分を含めて eps 以下、min_samples 以上の近傍を持つ点が核になる。戻り値 -1 は外れ値。
 */
export function dbscan(n, dist, eps, minSamples) {
  const neighbors = [];
  for (let i = 0; i < n; i++) {
    const a = [];
    for (let j = 0; j < n; j++) if (i === j || dist(i, j) <= eps) a.push(j);
    neighbors.push(a);
  }
  const core = neighbors.map((a) => a.length >= minSamples);
  const labels = new Array(n).fill(-1);
  let label = 0;
  for (let i = 0; i < n; i++) {
    if (labels[i] !== -1 || !core[i]) continue;
    const stack = [i];
    while (stack.length) {
      const p = stack.pop();
      if (labels[p] !== -1) continue;
      labels[p] = label;
      if (core[p]) for (const q of neighbors[p]) if (labels[q] === -1) stack.push(q);
    }
    label++;
  }
  return labels;
}

/**
 * キーのハッシュ順に並べて先頭 n 件を取る。アルバムに画像が足されても既存の標本が入れ替わらず、
 * 大きいアルバム（千枚超）と小さいアルバム（数十枚）を同じ規則で再現よく間引ける。
 * n を増やした結果は、少ない時の結果をそのまま先頭に含む。
 */
export function sampleStable(list, n, keyOf = (x) => x.key, seed = "r2g-ccip") {
  return list
    .map((x) => [
      createHash("sha1")
        .update(`${seed}:${keyOf(x)}`)
        .digest("hex"),
      x,
    ])
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .slice(0, n)
    .map((p) => p[1]);
}

// ---------------------------------------------------------------------------
// plan の組み立て
// ---------------------------------------------------------------------------

const PROVISIONAL = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

const planEntry = (key, r) => ({
  key,
  decision: r.decision,
  score: r.score ?? null,
  centroid: r.centroid ?? null,
  second: r.second ?? null,
  persons: r.persons ?? 0,
  rationale: r.rationale,
  crops: (r.crops ?? []).map((c, i) => ({
    index: i,
    decision: c.decision,
    albumTitle: c.albumTitle ?? null,
    score: c.score ?? null,
  })),
});

/**
 * 判定済みの対象から plan（version 1）を作る。apply の形は色の判定と同じなので apply はそのまま使える。
 * targets: [{ key, result: decideImage の戻り値, persons: [{ box, crop, feat }] }]
 * differences: async (feats) => (i, j) => number（未マッチ同士の束ねに使う）
 */
export async function buildCcipPlan({
  lib,
  targets,
  assigned,
  params,
  planId,
  differences,
  engine = "ccip",
}) {
  // 仮タイトルに実行ごとの id を入れる理由は色の判定（character-albums-core.mjs）と同じ
  const runId = planId ?? randomUUID().slice(0, 8);
  const groups = new Map();
  const unclassified = [];
  const nochar = [];
  const skipped = [];
  const singles = [];
  for (const t of targets) {
    if (assigned.has(`${lib}:${t.key}`)) {
      skipped.push({ key: t.key, reason: "既にアルバムに入っている" });
      continue;
    }
    const r = t.result;
    const entry = { ...planEntry(t.key, r), persons: t.persons?.length ?? r.persons ?? 0 };
    entry.crops = entry.crops.map((c) => ({ ...c, box: t.persons?.[c.index]?.box ?? null }));
    if (r.decision === "nochar") {
      nochar.push(entry);
    } else if (r.decision === "match") {
      const g = groups.get(r.albumId) ?? {
        id: `add:${r.albumId}`,
        action: "add",
        albumId: r.albumId,
        title: r.albumTitle,
        approved: false,
        items: [],
      };
      g.items.push({ ...entry, confidence: r.confidence });
      groups.set(r.albumId, g);
    } else if (r.decision === "unmatched" && !r.multi && t.persons?.length === 1) {
      singles.push({ entry, feat: t.persons[0].feat });
    } else {
      unclassified.push(entry);
    }
  }
  const created = [];
  if (singles.length) {
    const dist = singles.length > 1 ? await differences(singles.map((s) => s.feat)) : () => 0;
    const labels = dbscan(singles.length, dist, params.clusterEps, params.clusterMinSamples);
    const clusters = new Map();
    labels.forEach((l, i) => {
      if (l < 0) unclassified.push(singles[i].entry);
      else clusters.set(l, [...(clusters.get(l) ?? []), singles[i].entry]);
    });
    let n = 0;
    for (const members of clusters.values()) {
      if (members.length < 2) {
        unclassified.push(...members);
        continue;
      }
      const label = `キャラクター${PROVISIONAL[n % PROVISIONAL.length]}${n >= PROVISIONAL.length ? Math.floor(n / PROVISIONAL.length) : ""}（仮・${runId}）`;
      n++;
      created.push({
        id: `create:${label}`,
        action: "create",
        title: label,
        approved: false,
        items: members.map((i) => ({
          ...i,
          confidence: "low",
          rationale: `${i.rationale}。未分類同士で CCIP の差が ${r4(params.clusterEps)} 以内に集まった（DBSCAN）`,
        })),
      });
    }
  }
  return {
    version: 1,
    engine,
    lib,
    planId: runId,
    createdAt: new Date().toISOString(),
    params,
    groups: [...groups.values(), ...created],
    unclassified,
    nochar,
    skipped,
  };
}

// ---------------------------------------------------------------------------
// 精度評価
// ---------------------------------------------------------------------------

/**
 * records: [{ truth: albumId, truths?: albumId[], decision, albumId }]
 * truths は対象が複数の参照アルバムに入っている時の正解集合（どれに入れても正しい）。
 * precision = そのアルバムへ match と出した内の正解率、recall = そのアルバムの画像の内の正解 match 率、
 * abstain = 要確認・未マッチ・キャラなしで保留した率。
 */
export function evalMetrics(records, albums) {
  const perAlbum = {};
  const confusion = {};
  for (const a of albums) {
    perAlbum[a.id] = { title: a.title, n: 0, correct: 0, wrong: 0, abstain: 0, predicted: 0 };
    confusion[a.title] = {};
  }
  const titleOf = new Map(albums.map((a) => [a.id, a.title]));
  for (const r of records) {
    const truths = r.truths ?? [r.truth];
    const row = perAlbum[r.truth];
    row.n++;
    const col = r.decision === "match" ? titleOf.get(r.albumId) : `(${r.decision})`;
    confusion[titleOf.get(r.truth)][col] = (confusion[titleOf.get(r.truth)][col] ?? 0) + 1;
    if (r.decision === "match") {
      if (perAlbum[r.albumId]) perAlbum[r.albumId].predicted++;
      if (truths.includes(r.albumId)) row.correct++;
      else row.wrong++;
    } else {
      row.abstain++;
    }
  }
  const ratio = (a, b) => (b ? Math.round((a / b) * 1000) / 1000 : null);
  const rows = Object.entries(perAlbum).map(([id, v]) => {
    // precision の分子は「そのアルバムへ出した match のうち正しかった数」。
    // 複数アルバムに入っている画像があるので、行の correct ではなく予測側から数え直す
    const tpPred = records.filter(
      (r) => r.decision === "match" && r.albumId === id && (r.truths ?? [r.truth]).includes(id),
    ).length;
    return {
      albumId: id,
      ...v,
      precision: ratio(tpPred, v.predicted),
      recall: ratio(v.correct, v.n),
      abstainRate: ratio(v.abstain, v.n),
      errorRate: ratio(v.wrong, v.n),
    };
  });
  const total = records.length;
  const matched = records.filter((r) => r.decision === "match");
  const correct = matched.filter((r) => (r.truths ?? [r.truth]).includes(r.albumId)).length;
  const mean = (xs) => {
    const v = xs.filter((x) => x != null);
    return v.length ? Math.round((v.reduce((s, x) => s + x, 0) / v.length) * 1000) / 1000 : null;
  };
  return {
    perAlbum: rows,
    confusion,
    micro: {
      n: total,
      precision: ratio(correct, matched.length),
      recall: ratio(correct, total),
      abstainRate: ratio(total - matched.length, total),
      errorRate: ratio(matched.length - correct, total),
    },
    // 画像数の偏り（千枚超と数十枚）で大きいアルバムだけの成績にならないよう、アルバム平均も出す
    macro: {
      precision: mean(rows.map((r) => r.precision)),
      recall: mean(rows.map((r) => r.recall)),
      abstainRate: mean(rows.map((r) => r.abstainRate)),
    },
  };
}

/**
 * 保存した採点結果を閾値・margin の組合せごとに判定し直す（推論はやり直さない）。
 * samples: [{ truth, truths, crops: scoreAlbums の配列 }]
 */
export function sweep(samples, albums, params, { thresholds, margins }) {
  const out = [];
  for (const threshold of thresholds) {
    for (const margin of margins) {
      const p = { ...params, threshold, margin, high: Math.min(params.high, threshold) };
      const records = samples.map((s) => ({ ...s, ...pick(decideImage(s.crops, p)) }));
      const m = evalMetrics(records, albums);
      out.push({ threshold: r4(threshold), margin: r4(margin), micro: m.micro, macro: m.macro });
    }
  }
  return out;
}

const pick = (d) => ({ decision: d.decision, albumId: d.albumId });
