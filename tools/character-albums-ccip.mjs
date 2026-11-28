/**
 * CCIP とアニメ人物検出を onnxruntime-node でローカル実行する部分（#31）。
 * 画像は外部へ送らない。通信はモデルが手元に無い時の Hugging Face からの取得だけ。
 *
 * モデルの置き場所: R2G_MODEL_DIR（既定 ~/.cache/r2g-models）
 *   ccip-caformer-24-randaug-pruned/{model_feat.onnx,model_metrics.onnx,metrics.json,cluster.json}
 *     … deepghs/ccip_onnx（openrail）
 *   anime_person_detection/person_detect_v1.1_m/model.onnx
 *     … deepghs/anime_person_detection（MIT）
 */
import { createHash } from "node:crypto";
import { once } from "node:events";
import {
  createWriteStream,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
} from "node:fs";
import { availableParallelism, homedir } from "node:os";
import { dirname, join } from "node:path";
import { performance } from "node:perf_hooks";
import sharp from "sharp";
import {
  CCIP_MODEL,
  CCIP_SIZE,
  DETECTOR_NAME,
  DETECTOR_SIZE,
  ccipInput,
  ccipParams,
  cmykToRgbPil,
  cropBox,
  cropRgb,
  dropAlpha,
  eligiblePersons,
  flattenWhite,
  gifTransparentColor,
  pillowAlphaRule,
  yoloDecode,
  yoloInput,
} from "./character-albums-ccip-core.mjs";

export const FEATURE_DIM = 768;

/** 置き場所の既定。CLI の --model-dir が優先し、次に環境変数 R2G_MODEL_DIR。 */
export function defaultModelDir() {
  return process.env.R2G_MODEL_DIR || join(homedir(), ".cache", "r2g-models");
}

// 取得元は resolve/main。中身が差し替わっていたら sha256 で気付けるように、取った物を必ず照合する
const hf = (repo, path) => `https://huggingface.co/${repo}/resolve/main/${path}`;
export const MODEL_FILES = Object.freeze({
  feat: {
    local: `${CCIP_MODEL}/model_feat.onnx`,
    url: hf("deepghs/ccip_onnx", `${CCIP_MODEL}/model_feat.onnx`),
    size: 150248245,
    sha256: "4ea118d16496274f4f6e08d3afc768cc592389e8f7f32f8732ce2215c228ac5f",
  },
  metric: {
    local: `${CCIP_MODEL}/model_metrics.onnx`,
    url: hf("deepghs/ccip_onnx", `${CCIP_MODEL}/model_metrics.onnx`),
    size: 1649,
    sha256: "7e4646fdfbe369ad485b227ec47ac4092c98b8deef3af44e19fdbd8ba7bc25c1",
  },
  metrics: {
    local: `${CCIP_MODEL}/metrics.json`,
    url: hf("deepghs/ccip_onnx", `${CCIP_MODEL}/metrics.json`),
    size: 147,
    sha256: "b5535577288e22940b853192cd1661e45c7615b7d89b49a8745c2c81685552d4",
  },
  cluster: {
    local: `${CCIP_MODEL}/cluster.json`,
    url: hf("deepghs/ccip_onnx", `${CCIP_MODEL}/cluster.json`),
    size: 370,
    sha256: "21b9094f1edcd5cec6853b7d86dfed00b377ba5c3c9aa2535488833a84d3dd5a",
  },
  detector: {
    local: `anime_person_detection/${DETECTOR_NAME}/model.onnx`,
    url: hf("deepghs/anime_person_detection", `${DETECTOR_NAME}/model.onnx`),
    size: 103459671,
    sha256: "c80365a98ca8388fd2f01fd5abea0439e92265bceceb048bef38b0849303467c",
  },
});

/** テストの実行可否に使う。全部そろっている時だけ true。 */
export function modelsPresent(dir = defaultModelDir()) {
  return Object.values(MODEL_FILES).every((f) => existsSync(join(dir, f.local)));
}

async function ensureFile(dir, spec, { offline, log }) {
  const path = join(dir, spec.local);
  if (existsSync(path)) {
    // 毎回 150MB を hash し直すと起動が遅いので、手元の物は大きさだけ見る
    if (statSync(path).size !== spec.size) {
      throw new Error(`${path} の大きさが ${spec.size} バイトではない。消して取り直す`);
    }
    return path;
  }
  if (offline) throw new Error(`${path} が無い（--offline）。${spec.url} から置く`);
  mkdirSync(dirname(path), { recursive: true });
  log(`download: ${spec.url} (${(spec.size / 1e6).toFixed(1)} MB) -> ${path}`);
  const res = await fetch(spec.url, { redirect: "follow" });
  if (!res.ok || !res.body) throw new Error(`HTTP ${res.status} ${spec.url}`);
  const tmp = `${path}.part`;
  const hash = createHash("sha256");
  const out = createWriteStream(tmp);
  let size = 0;
  try {
    for await (const chunk of res.body) {
      hash.update(chunk);
      size += chunk.length;
      if (!out.write(chunk)) await once(out, "drain");
    }
    await new Promise((ok, ng) => out.end((e) => (e ? ng(e) : ok())));
    const digest = hash.digest("hex");
    if (size !== spec.size || digest !== spec.sha256) {
      throw new Error(`${spec.url} の中身が想定と違う（${size} バイト, sha256 ${digest}）`);
    }
    // 書き終えてから名前を変える。途中で止まっても壊れたモデルを読まない
    renameSync(tmp, path);
  } catch (e) {
    out.destroy();
    rmSync(tmp, { force: true });
    throw e;
  }
  return path;
}

/**
 * 画像バイト列を RGB 画素にする。imgutils の load_image(mode="RGB") に合わせる。
 * ICC は無視し（Pillow は色変換しない）、EXIF の回転もかけない。透過の扱いは形式で変わる
 * （RGBA は白へ重ね、パレットや RGB の tRNS は透過を捨てる等。pillowAlphaRule を参照）。
 * CMYK の JPEG も ICC を使わず Pillow と同じ素朴な式で RGB にする。
 */
export async function decodeRgb(bytes) {
  const meta = await sharp(bytes).metadata();
  const rule = pillowAlphaRule(bytes, meta);
  if (rule === "cmyk") {
    // pipelineColourspace を cmyk にしないと sharp が途中で sRGB へ変換してしまい、元の CMYK 値が取れない
    const { data, info } = await sharp(bytes, { ignoreIcc: true })
      .pipelineColourspace("cmyk")
      .toColourspace("cmyk")
      .raw({ depth: "uchar" })
      .toBuffer({ resolveWithObject: true });
    if (info.channels !== 4) throw new Error(`CMYK として読めない画像（${info.channels} ch）`);
    const cmyk = new Uint8Array(data.buffer, data.byteOffset, data.length);
    return {
      data: cmykToRgbPil(cmyk, info.width, info.height),
      width: info.width,
      height: info.height,
      rule,
    };
  }
  const { data, info } = await sharp(bytes, { ignoreIcc: true })
    .toColourspace("srgb")
    .ensureAlpha()
    .raw({ depth: "uchar" })
    .toBuffer({ resolveWithObject: true });
  if (info.channels !== 4) throw new Error(`RGB にできない画像（${info.channels} ch）`);
  const rgba = new Uint8Array(data.buffer, data.byteOffset, data.length);
  const { width, height } = info;
  let rgb;
  if (rule === "keep") rgb = dropAlpha(rgba, width, height);
  else if (rule === "gifKey") rgb = dropAlpha(rgba, width, height, gifTransparentColor(bytes));
  else if (rule === "selfMask") rgb = flattenWhite(rgba, width, height, 0);
  // 不透明な画素は白と重ねても値が変わらないので、透過の無い画像も同じ式を通す
  else rgb = flattenWhite(rgba, width, height);
  return { data: rgb, width, height, rule };
}

/**
 * モデルを開き、検出・特徴量・差の計算をまとめた物を返す。
 * overrides は ccipParams の上書き（--threshold など）。
 */
export async function openCcip({
  modelDir = defaultModelDir(),
  threads,
  offline = false,
  log = () => {},
  overrides = {},
} = {}) {
  // onnxruntime はここで初めて読む。decodeRgb だけを使う単体テストや --engine color でネイティブの実行系を載せないため
  const { default: ort } = await import("onnxruntime-node");
  const files = {};
  for (const [name, spec] of Object.entries(MODEL_FILES)) {
    files[name] = await ensureFile(modelDir, spec, { offline, log });
  }
  const metrics = JSON.parse(readFileSync(files.metrics, "utf8"));
  const cluster = JSON.parse(readFileSync(files.cluster, "utf8"));
  const params = ccipParams({ metrics, cluster }, overrides);
  // onnxruntime の既定は論理コア数ぶんのスレッドを立てる。SMT の兄弟同士が演算器を取り合い、
  // 手元（12 コア 24 スレッド）では 24 本だと 12 本の倍以上遅かったので、既定は論理コアの半分にする
  const intraOpNumThreads = Number(threads) || Math.max(1, Math.floor(availableParallelism() / 2));
  const options = { executionProviders: ["cpu"], graphOptimizationLevel: "all", intraOpNumThreads };
  const [feat, metric, det] = await Promise.all([
    ort.InferenceSession.create(files.feat, options),
    ort.InferenceSession.create(files.metric, options),
    ort.InferenceSession.create(files.detector, options),
  ]);

  async function embed(inputs) {
    if (!inputs.length) return [];
    const n = CCIP_SIZE * CCIP_SIZE * 3;
    const batch = new Float32Array(inputs.length * n);
    inputs.forEach((x, i) => batch.set(x, i * n));
    const out = await feat.run({
      [feat.inputNames[0]]: new ort.Tensor("float32", batch, [
        inputs.length,
        3,
        CCIP_SIZE,
        CCIP_SIZE,
      ]),
    });
    const data = out[feat.outputNames[0]].data;
    return inputs.map((_, i) => data.slice(i * FEATURE_DIM, (i + 1) * FEATURE_DIM));
  }

  /** 特徴量の総当たりの差（metric モデル）。小さいほど同じキャラ。 */
  async function differences(feats) {
    const n = feats.length;
    if (!n) return () => Number.NaN;
    const batch = new Float32Array(n * FEATURE_DIM);
    feats.forEach((f, i) => batch.set(f, i * FEATURE_DIM));
    const out = await metric.run({
      [metric.inputNames[0]]: new ort.Tensor("float32", batch, [n, FEATURE_DIM]),
    });
    const data = out[metric.outputNames[0]].data;
    return (i, j) => data[i * n + j];
  }

  async function detect(img) {
    const input = yoloInput(img.data, img.width, img.height, DETECTOR_SIZE);
    const out = await det.run({
      [det.inputNames[0]]: new ort.Tensor("float32", input, [1, 3, DETECTOR_SIZE, DETECTOR_SIZE]),
    });
    const o = out[det.outputNames[0]];
    const [, rows, count] = o.dims;
    return yoloDecode(o.data, rows, count, {
      conf: params.detConf,
      iou: params.detIou,
      oldSize: [img.width, img.height],
      newSize: [DETECTOR_SIZE, DETECTOR_SIZE],
    });
  }

  /**
   * 1 枚を「人物の枠・切り出し・特徴量」にする。人物がいなければ persons は空。
   * detected は上限人数で切る前の人数。切った人物を判定で無かったことにしないために残す。
   */
  async function analyze(bytes) {
    const t0 = performance.now();
    const img = await decodeRgb(bytes);
    const t1 = performance.now();
    const eligible = eligiblePersons(await detect(img), img.width, img.height, params);
    const persons = eligible.slice(0, params.maxPersons).map((d) => ({
      box: d.box,
      score: Math.round(d.score * 1000) / 1000,
      crop: cropBox(d.box, img.width, img.height, params.cropMargin),
    }));
    const t2 = performance.now();
    const feats = await embed(
      persons.map((p) =>
        ccipInput(cropRgb(img.data, img.width, p.crop), p.crop.width, p.crop.height),
      ),
    );
    persons.forEach((p, i) => (p.feat = feats[i]));
    const t3 = performance.now();
    return {
      width: img.width,
      height: img.height,
      rgb: img.data,
      persons,
      detected: eligible.length,
      decodeRule: img.rule,
      timings: { decode: t1 - t0, detect: t2 - t1, embed: t3 - t2, total: t3 - t0 },
    };
  }

  return {
    params,
    files,
    info: {
      ccip: { repo: "deepghs/ccip_onnx", model: CCIP_MODEL, license: "openrail", metrics, cluster },
      detector: {
        repo: "deepghs/anime_person_detection",
        model: DETECTOR_NAME,
        license: "MIT",
        size: MODEL_FILES.detector.size,
        sha256: MODEL_FILES.detector.sha256,
      },
      onnxruntime: { ...ort.env.versions, intraOpNumThreads },
    },
    analyze,
    embed,
    detect,
    differences,
  };
}

/** preview 用に、人物の切り出しを小さな data URI にする。 */
export async function cropDataUri(analysis, crop, edge = 160) {
  const buf = await sharp(
    Buffer.from(analysis.rgb.buffer, analysis.rgb.byteOffset, analysis.rgb.length),
    {
      raw: { width: analysis.width, height: analysis.height, channels: 3 },
    },
  )
    .extract(crop)
    .resize(edge, edge, { fit: "contain", background: "#ffffff" })
    .webp({ quality: 70 })
    .toBuffer();
  return `data:image/webp;base64,${buf.toString("base64")}`;
}
