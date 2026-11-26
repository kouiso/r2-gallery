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
 * - high: 確信度 high の上限。cluster.json の dbscan_2 の eps（同キャラ同士が密に集まる距離）。
 *   閾値より緩いと high の意味が無くなるので、threshold を上書きした後で min(highCap, threshold) にする
 * - margin: 1 位と 2 位のアルバムの差がこれ未満なら要確認。似た別キャラ（髪色の近い 2 人）を
 *   勝手に寄せないための安全側の幅。eval の sweep で実データに合わせて変える前提
 * - topK: アルバムごとの近い参照何枚の平均で測るか。1 枚だけ似た参照に引っ張られないため 3
 * - detConf / detIou: imgutils の detect_person の既定（conf 0.3, iou 0.5）
 * - minPersonFrac: 画像面積に対してこれ未満の人物枠は捨てる。512px のサムネで約 51px 角未満は
 *   CCIP の入力（384px）に引き伸ばしても顔が判別できず、背景の小さな人影で複数人扱いになるため
 * - cropMargin: 人物枠の外へ広げる割合。検出枠が髪の先や頭頂を切りがちなため少しだけ広げる
 * - maxPersons: 1 枚で照合する人数の上限。これより多く写った画像は、残りを見ていないので必ず要確認にする
 */
export function ccipParams({ metrics, cluster } = {}, overrides = {}) {
  const set = Object.fromEntries(Object.entries(overrides).filter(([, v]) => v !== undefined));
  const eps = cluster?.dbscan_2?.eps ?? CCIP_FALLBACK.clusterEps;
  const { high: highOverride, ...rest } = set;
  const base = {
    threshold: metrics?.threshold ?? CCIP_FALLBACK.threshold,
    margin: 0.03,
    topK: 3,
    highCap: highOverride ?? eps,
    clusterEps: eps,
    clusterMinSamples: cluster?.dbscan_2?.min_samples ?? CCIP_FALLBACK.clusterMinSamples,
    detConf: 0.3,
    detIou: 0.5,
    minPersonFrac: 0.01,
    cropMargin: 0.05,
    maxPersons: 6,
    ...rest,
  };
  const p = withThreshold(base, base.threshold, base.margin);
  assertParams(p);
  return p;
}

/**
 * threshold と margin を差し替え、high をそれに合わせて決め直す。plan と eval の sweep が同じ規則で
 * high を決めるように、両方ここを通す（片方だけ min を取ると同じ閾値で確信度の表示が食い違う）
 */
export function withThreshold(params, threshold, margin) {
  return {
    ...params,
    threshold,
    margin,
    high: Math.min(params.highCap ?? params.high, threshold),
  };
}

/**
 * 判定の値を確かめる。NaN を通すと `差 > NaN` も `差 < NaN` も偽になり、閾値と margin の歯止めが
 * 両方外れて、どんなに遠いアルバムにも一致と出してしまう。そうなる前に止める
 */
export function assertParams(p) {
  const bad = [];
  const num = (name, ok, want) => {
    if (!(Number.isFinite(p[name]) && ok(p[name]))) bad.push(`${name}=${p[name]}（${want}）`);
  };
  num("threshold", (v) => v > 0 && v <= 1, "0 より大きく 1 以下");
  num("margin", (v) => v >= 0 && v < 1, "0 以上 1 未満");
  num("high", (v) => v > 0 && v <= p.threshold, "0 より大きく threshold 以下");
  num("topK", (v) => Number.isInteger(v) && v >= 1, "1 以上の整数");
  num("maxPersons", (v) => Number.isInteger(v) && v >= 1, "1 以上の整数");
  num("clusterEps", (v) => v > 0, "0 より大きい");
  if (bad.length) throw new RangeError(`判定の値が不正: ${bad.join(", ")}`);
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
 * 整数の DIV255 で丸める。sharp の flatten は浮動小数で合成するため ±1 ずれる。
 * maskChannel は不透明度に使うチャンネル。灰色の tRNS 画像では Pillow が画像自身（濃淡）を mask にするので 0 を渡す
 */
export function flattenWhite(rgba, width, height, maskChannel = 3) {
  const n = width * height;
  const out = new Uint8Array(n * 3);
  for (let i = 0; i < n; i++) {
    const a = rgba[i * 4 + maskChannel];
    for (let c = 0; c < 3; c++) {
      const tmp = 255 * (255 - a) + rgba[i * 4 + c] * a + 128;
      out[i * 3 + c] = ((tmp >> 8) + tmp) >> 8;
    }
  }
  return out;
}

/** RGBA の透過を捨てて RGB にする。key があれば、完全に透明な画素をその色にする（透過 GIF 用）。 */
export function dropAlpha(rgba, width, height, key = null) {
  const n = width * height;
  const out = new Uint8Array(n * 3);
  for (let i = 0; i < n; i++) {
    const clear = key && rgba[i * 4 + 3] === 0;
    for (let c = 0; c < 3; c++) out[i * 3 + c] = clear ? key[c] : rgba[i * 4 + c];
  }
  return out;
}

/** Pillow の CMYK→RGB（Convert.c の cmyk2rgb）。ICC を使わない素朴な式で、imgutils はこれを通る。 */
export function cmykToRgbPil(cmyk, width, height) {
  const n = width * height;
  const out = new Uint8Array(n * 3);
  for (let i = 0; i < n; i++) {
    const nk = 255 - cmyk[i * 4 + 3];
    for (let c = 0; c < 3; c++) {
      const tmp = cmyk[i * 4 + c] * nk + 128;
      const v = nk - (((tmp >> 8) + tmp) >> 8);
      out[i * 3 + c] = v < 0 ? 0 : v;
    }
  }
  return out;
}

/** PNG の IHDR の色の型（0 灰・2 RGB・3 パレット・4 灰+α・6 RGBA）。PNG でなければ null。 */
export function pngColorType(bytes) {
  const sig = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 26 || sig.some((b, i) => bytes[i] !== b)) return null;
  // IHDR は必ず最初のチャンク（長さ 4 + "IHDR" 4 + 幅 4 + 高さ 4 + ビット深度 1 の次）
  if (String.fromCharCode(bytes[12], bytes[13], bytes[14], bytes[15]) !== "IHDR") return null;
  return bytes[25];
}

/**
 * GIF の最初の画像の透過色（パレット上の色）を返す。透過が無ければ null。
 * Pillow は透過 GIF をパレットのまま RGB にするので、透明な画素は透過番号の色になる。
 * sharp は透明な画素の色を別の値で埋めるため、そのままでは imgutils と合わない
 */
export function gifTransparentColor(bytes) {
  const ascii = String.fromCharCode(...bytes.subarray(0, 6));
  if (ascii !== "GIF87a" && ascii !== "GIF89a") return null;
  let p = 13;
  const packed = bytes[10];
  let table = null;
  if (packed & 0x80) {
    const size = 3 * 2 ** ((packed & 7) + 1);
    table = bytes.subarray(p, p + size);
    p += size;
  }
  let trans = null;
  const skipSubBlocks = () => {
    while (p < bytes.length && bytes[p] !== 0) p += bytes[p] + 1;
    p++;
  };
  while (p < bytes.length) {
    const b = bytes[p];
    if (b === 0x21) {
      const label = bytes[p + 1];
      if (label === 0xf9 && bytes[p + 2] === 4) {
        trans = bytes[p + 3] & 1 ? bytes[p + 6] : null;
        p += 8;
      } else {
        p += 2;
        skipSubBlocks();
      }
    } else if (b === 0x2c) {
      const lp = bytes[p + 9];
      if (lp & 0x80) table = bytes.subarray(p + 10, p + 10 + 3 * 2 ** ((lp & 7) + 1));
      break;
    } else {
      return null;
    }
  }
  if (trans == null || !table || trans * 3 + 2 >= table.length) return null;
  return [table[trans * 3], table[trans * 3 + 1], table[trans * 3 + 2]];
}

/**
 * imgutils の load_image(mode="RGB") が透過をどう扱うかを、Pillow が開いた時の mode で決める。
 * add_background_for_rgba は `paste(image, mask=image)` を try し、mask にできない mode では
 * ValueError で白塗りを諦めて convert("RGB") だけする。その結果、形式によって扱いが分かれる。
 * - "white": RGBA・LA（PNG の色の型 6/4、透過 WebP など）。白へ重ねる
 * - "keep": パレット（色の型 3）と RGB（色の型 2）の tRNS。mask にできず、透過を捨てて元の色を残す
 * - "selfMask": 灰色（色の型 0）の tRNS。mode L は mask にできるので、画像自身の濃淡を不透明度として白へ重ねる
 * - "gifKey": 透過 GIF（mode P）。透過を捨て、透明な画素はパレットの透過色になる
 * - "cmyk": CMYK の JPEG。Pillow の素朴な式で RGB にする
 * meta は sharp の metadata()（format・hasAlpha・space）。
 */
export function pillowAlphaRule(bytes, meta) {
  if (meta.format === "jpeg" && meta.space === "cmyk") return "cmyk";
  if (!meta.hasAlpha) return "white";
  if (meta.format === "gif") return "gifKey";
  if (meta.format === "png") {
    const ct = pngColorType(bytes);
    if (ct === 2 || ct === 3) return "keep";
    if (ct === 0) return "selfMask";
  }
  return "white";
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

/** 小さすぎる枠を捨て、信頼度の高い順に並べる（上限人数で切る前。何人写っていたかの数に使う）。 */
export function eligiblePersons(detections, width, height, { minPersonFrac }) {
  const total = width * height;
  return detections
    .filter((d) => {
      const [x0, y0, x1, y1] = d.box;
      return x1 > x0 && y1 > y0 && ((x1 - x0) * (y1 - y0)) / total >= minPersonFrac;
    })
    .sort((a, b) => b.score - a.score);
}

/** 小さすぎる枠を捨て、信頼度の高い順に上限人数まで残す。 */
export function selectPersons(detections, width, height, params) {
  return eligiblePersons(detections, width, height, params).slice(0, params.maxPersons);
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
 * 画像の id（`${lib}:${key}`）。参照を作る側（makeRef）と照合する側（selfId）が同じ式を通るよう、
 * ここだけで組み立てる。形がずれると自分自身と照合して差がほぼ 0 になり、評価が水増しされる
 */
export const itemId = (it, lib) => `${it.lib ?? lib}:${it.key}`;

/** 参照 1 枚。refId(makeRef(it, lib, f)) === itemId(it, lib) になる。 */
export const makeRef = (it, lib, feat) => ({ key: it.key, lib: it.lib ?? lib, feat });

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
  // sweep などで ccipParams を通らない値が来ても、NaN で歯止めが外れないようにここでも止める
  if (![params.threshold, params.margin, params.high].every(Number.isFinite)) {
    throw new RangeError(
      `判定の値が数ではない（threshold=${params.threshold}, margin=${params.margin}, high=${params.high}）`,
    );
  }
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
 * detected は上限人数（maxPersons）で切る前に写っていた人数。切った人物は照合していないので、
 * 照合した全員が揃っていても要確認にする（見ていない人物が別キャラかもしれない）。
 */
export function decideImage(crops, params, { detected } = {}) {
  if (!crops.length) {
    return {
      decision: "nochar",
      rationale: "人物が検出されない（キャラなし）。CCIP では照合しない",
      persons: 0,
      crops: [],
    };
  }
  const decided = crops.map((c) => decideCrop(c, params));
  const persons = decided.length;
  const total = Math.max(detected ?? persons, persons);
  if (total > persons) {
    const matched = decided.find((d) => d.decision === "match");
    return {
      decision: "review",
      albumId: matched?.albumId,
      albumTitle: matched?.albumTitle,
      score: r4(Math.min(...decided.map((d) => d.score ?? Infinity))),
      rationale: `${total} 人中 ${persons} 人だけ照合した（上限 ${params.maxPersons} 人）。残りの人物は見ていないので要確認`,
      persons,
      detected: total,
      crops: decided,
    };
  }
  if (persons === 1) return { ...decided[0], persons: 1, crops: decided };
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
  ...(r.detected ? { detected: r.detected } : {}),
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
 *   取れなかった・読めなかった画像は result: { decision: "error", rationale } で渡すと failed に入る。
 *   黙って落とすと、どのバケツにも無い画像が「判定済み」に見えてしまうため
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
  const failed = [];
  const singles = [];
  for (const t of targets) {
    if (assigned.has(`${lib}:${t.key}`)) {
      skipped.push({ key: t.key, reason: "既にアルバムに入っている" });
      continue;
    }
    const r = t.result;
    if (r.decision === "error") {
      failed.push({ key: t.key, decision: "error", persons: 0, rationale: r.rationale, crops: [] });
      continue;
    }
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
    failed,
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
 * 開いた集合（open-set）の評価。leave-one-out だけでは評価する画像が必ずどこかの参照アルバムのキャラで、
 * 「どのアルバムにもいないキャラ」（新しくアップロードされる画像で一番多い場合）を一度も試さない。
 * そこで画像ごとに自分のキャラのアルバム（truths 全部）を候補から外して採点し直し、
 * 残りのアルバムへ一致と出したら誤一致として数える。期待する答えは未マッチか要確認。
 * 外したアルバムの採点だけを消せばよく、他のアルバムの参照と代表はそのままなので推論はやり直さない。
 */
export function openSetSample(s) {
  const own = new Set(s.truths ?? [s.truth]);
  return { ...s, crops: s.crops.map((c) => c.filter((a) => !own.has(a.albumId))) };
}

/** samples を open-set で判定し、アルバムごとと全体の誤一致率を出す。 */
export function openSetMetrics(samples, albums, params) {
  const perAlbum = new Map(
    albums.map((a) => [
      a.id,
      { albumId: a.id, title: a.title, n: 0, falseMatch: 0, review: 0, unmatched: 0, nochar: 0 },
    ]),
  );
  const matchedTo = {};
  for (const s of samples) {
    const d = decideImage(openSetSample(s).crops, params, { detected: s.detected });
    const row = perAlbum.get(s.truth);
    row.n++;
    if (d.decision === "match") {
      row.falseMatch++;
      const key = `${row.title}→${d.albumTitle}`;
      matchedTo[key] = (matchedTo[key] ?? 0) + 1;
    } else if (d.decision === "review") row.review++;
    else if (d.decision === "nochar") row.nochar++;
    else row.unmatched++;
  }
  const ratio = (a, b) => (b ? Math.round((a / b) * 1000) / 1000 : null);
  const rows = [...perAlbum.values()].map((r) => ({
    ...r,
    falseMatchRate: ratio(r.falseMatch, r.n),
  }));
  const n = rows.reduce((s, r) => s + r.n, 0);
  const fm = rows.reduce((s, r) => s + r.falseMatch, 0);
  const rates = rows.map((r) => r.falseMatchRate).filter((x) => x != null);
  return {
    perAlbum: rows,
    matchedTo,
    n,
    falseMatch: fm,
    falseMatchRate: ratio(fm, n),
    macroFalseMatchRate: rates.length
      ? Math.round((rates.reduce((s, x) => s + x, 0) / rates.length) * 1000) / 1000
      : null,
  };
}

/**
 * 保存した採点結果を閾値・margin の組合せごとに判定し直す（推論はやり直さない）。
 * samples: [{ truth, truths, crops: scoreAlbums の配列, detected }]
 * 各行に閉じた集合（leave-one-out）の precision / recall と、open-set の誤一致率を並べる。
 * 閾値を緩めると recall は上がるが、知らないキャラを既存アルバムへ寄せる誤一致も増えるので、両方を見て決める。
 */
export function sweep(samples, albums, params, { thresholds, margins }) {
  const out = [];
  for (const threshold of thresholds) {
    for (const margin of margins) {
      const p = withThreshold(params, threshold, margin);
      const records = samples.map((s) => ({
        ...s,
        ...pick(decideImage(s.crops, p, { detected: s.detected })),
      }));
      const m = evalMetrics(records, albums);
      const o = openSetMetrics(samples, albums, p);
      out.push({
        threshold: r4(threshold),
        margin: r4(margin),
        micro: m.micro,
        macro: m.macro,
        openSet: { falseMatchRate: o.falseMatchRate, macroFalseMatchRate: o.macroFalseMatchRate },
      });
    }
  }
  return out;
}

const pick = (d) => ({ decision: d.decision, albumId: d.albumId });

/**
 * eval の本体（推論済みの結果から leave-one-out の判定を作る）。I/O は持たない。
 * refAlbums: [{ id, title }]、evalSets: Map<albumId, items[]>、profiles: buildProfiles の結果、
 * analyses: Map<itemId, { persons, detected }>（取れなかった画像は入っていない）、
 * membership: Map<itemId, albumId[]>（その画像が入っている参照アルバム）。
 * - 自分自身は参照からも代表からも外す（selfId は itemId で作り、参照の id と同じ式にする）
 * - 2 つの参照アルバムに入っている画像は 1 回だけ評価する（正解は最初のアルバム、truths は両方）。
 *   2 回数えると micro の件数と取り違え表が水増しされる
 */
export async function evaluateLoo({
  lib,
  refAlbums,
  evalSets,
  profiles,
  analyses,
  membership,
  differences,
  params,
}) {
  const profileIds = new Set(profiles.map((p) => p.id));
  const seen = new Set();
  const records = [];
  const samples = [];
  const failed = [];
  const duplicates = [];
  for (const a of refAlbums) {
    for (const it of evalSets.get(a.id) ?? []) {
      const id = itemId(it, lib);
      if (seen.has(id)) {
        duplicates.push({ key: it.key, albumId: a.id });
        continue;
      }
      seen.add(id);
      const an = analyses.get(id);
      if (!an) {
        failed.push({ key: it.key, albumId: a.id });
        continue;
      }
      const crops = await scoreImage({
        persons: an.persons,
        albums: profiles,
        selfId: id,
        differences,
        topK: params.topK,
      });
      const truths = (membership.get(id) ?? [a.id]).filter((x) => profileIds.has(x));
      const detected = an.detected ?? an.persons.length;
      const r = decideImage(crops, params, { detected });
      records.push({
        key: it.key,
        truth: a.id,
        truths,
        decision: r.decision,
        albumId: r.decision === "match" ? r.albumId : null,
        albumTitle: r.albumTitle ?? null,
        score: r.score ?? null,
        second: r.second ?? null,
        persons: r.persons,
        ...(r.detected ? { detected: r.detected } : {}),
      });
      samples.push({ truth: a.id, truths, crops, detected });
    }
  }
  return { records, samples, failed, duplicates };
}
