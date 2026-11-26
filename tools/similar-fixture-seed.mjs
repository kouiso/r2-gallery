#!/usr/bin/env node
/**
 * 見た目の照合 (vs1) を手元で通しで確かめるための、合成画像だけの種まき。
 * 手元の wrangler dev（worker/wrangler.test.toml）にだけ送る。127.0.0.1 / localhost 以外の宛先は通信前に断る
 * （本番の Worker に試験用の画像やアルバムを混ぜないため）。
 *
 * 作る物（すべて sharp で描いた図形とグラデーション。実在の絵は使わない）:
 *   - 約 30 枚の元絵（無圧縮 PNG）と、それぞれの別版:
 *     別フォルダの完全な写し / JPEG q40 / 半分の大きさ / WebP / PNG の再保存 / 明るさ +8 /
 *     40px の描き足し / 同じ寸法の小さな描き足し / 左右反転 / 幅 10% の切り抜き
 *   - どれとも似ていない絵、単色の絵、中身が同じ .mp4 の組（乱数のバイト列）
 *   - 画像の約半分に 512px JPEG q82、約 1/4 に WebP のサムネを PUT する（残りはサムネ無し）
 *   - ライブラリにアルバムを 1 つ作り、別版を入れる（消した時に残す物へ置き換わるかを見るため）
 *   - .work/similar-e2e/expected.json に期待（tools/similar-signatures.mjs --check-expected の形）を書く
 *
 * Usage:
 *   node tools/similar-fixture-seed.mjs --endpoint http://127.0.0.1:8787 --token test-access-token --lib a \
 *     [--seed 1] [--out .work/similar-e2e/expected.json] [--scan]
 *   --scan  種まきの後に POST /duplicates/scan を pending が 0 になるまで回す（既定は回さない:
 *           アプリ側の確認では画面の「中身を確認中」から通すため）
 *   --seed  既定の 1 だけが、期待がしきい値から十分離れていることを similar-fixture-seed.test.mjs で
 *           確かめてある。他の seed は描き足しの pHash が上限 10 の際に乗る組が出ることがある
 *
 * トークンは表示も保存もしない（--token か R2G_TOKEN で受け取る）。
 */
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import sharp from "sharp";

export const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
export const DEFAULT_OUT = join(".work", "similar-e2e", "expected.json");
export const ROOT = "similar-e2e";
export const SET_COUNT = 30;
export const DISTINCT_COUNT = 6;

// アプリの makeImageThumb と同じ寸法と画質。サーバーの署名がアプリと同じ入力から作られる状態を再現する
const THUMB_EDGE = 512;
const THUMB_JPEG_QUALITY = 82;
// tools/index-upload.mjs が作る WebP サムネと同じ画質（PC で作られたサムネが混じる状態を再現する）
const THUMB_WEBP_QUALITY = 78;
const VARIANT_JPEG_QUALITY = 90;
const VIDEO_BYTES = 48 * 1024;

// 元絵の寸法。16x16 の格子の 1 マスが 40px 前後になる大きさにして、40px の描き足しが 1 マスをほぼ覆うようにする
const BASE_SIZES = [
  [640, 480],
  [600, 600],
  [480, 640],
  [720, 480],
  [640, 512],
  [512, 640],
];

// ---------------------------------------------------------------- 宛先の確認

/**
 * 手元の Worker だけを許す。ホスト名は URL として読んでから完全一致で比べる
 * （"127.0.0.1.example.com" や "localhost@example.com" のような紛らわしい書き方を通さないため）。
 */
export function assertLocalEndpoint(raw) {
  let u;
  try {
    u = new URL(String(raw ?? ""));
  } catch {
    throw new Error("--endpoint は http://127.0.0.1:<port> か http://localhost:<port> で渡す");
  }
  if (u.protocol !== "http:" && u.protocol !== "https:")
    throw new Error("--endpoint は http(s) だけを受ける");
  if (u.username || u.password) throw new Error("--endpoint に認証情報を書かない");
  if (u.hostname !== "127.0.0.1" && u.hostname !== "localhost")
    throw new Error("手元の wrangler dev (127.0.0.1 / localhost) 以外には種をまかない");
  return u.origin;
}

// ---------------------------------------------------------------- 乱数と描画

/** 再現できる乱数（mulberry32）。同じ seed なら同じバイト列になるように、Math.random は使わない */
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const int = (rand, lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));
// 明るさ +8 で 255 に張り付かないよう、色は 30〜215 に収める（張り付くと格子の差が増えて別物に見える）
const colour = (rand) => `rgb(${int(rand, 30, 215)},${int(rand, 30, 215)},${int(rand, 30, 215)})`;

/**
 * 図形とグラデーションだけの絵。図形の数・位置・大きさを乱数で散らし、左右対称にならないようにする
 * （対称だと反転が「ほぼ同じ」に入ってしまい、反転の判定を確かめられない）。
 */
export function illustrationSvg(seed, w, h) {
  const rand = rng(seed);
  const defs = [];
  const body = [];
  // 地は横向きに暗→明（または明→暗）のはっきりした傾きにする。dHash は横に隣り合うマスの大小を見るので、
  // 縦向きや緩い傾きだと隣のマスがほぼ同じ明るさになり、再保存の揺れだけで bit が裏返る
  const dark = `rgb(${int(rand, 30, 90)},${int(rand, 30, 90)},${int(rand, 30, 90)})`;
  const light = `rgb(${int(rand, 160, 215)},${int(rand, 160, 215)},${int(rand, 160, 215)})`;
  const [left, right] = rand() < 0.5 ? [dark, light] : [light, dark];
  const y1 = int(rand, 0, 30);
  defs.push(
    `<linearGradient id="bg" x1="0%" y1="${y1}%" x2="100%" y2="${100 - y1}%">` +
      `<stop offset="0" stop-color="${left}"/><stop offset="1" stop-color="${right}"/></linearGradient>`,
  );
  body.push(`<rect width="${w}" height="${h}" fill="url(#bg)"/>`);
  const m = Math.min(w, h);
  const shapes = int(rand, 8, 12);
  for (let i = 0; i < shapes; i++) {
    const cx = int(rand, 0, w);
    const cy = int(rand, 0, h);
    const s = int(rand, Math.round(m * 0.08), Math.round(m * 0.36));
    // 塗りは多くをグラデーションにし、半透明にして地の傾きを透かす。一色の大きな面が隣のマスに
    // またがると、そのマスどうしの明るさが同じになり、dHash が再保存の揺れで裏返りやすくなる
    let fill = colour(rand);
    const g = rand();
    if (g < 0.4) {
      defs.push(
        `<radialGradient id="g${i}"><stop offset="0" stop-color="${colour(rand)}"/>` +
          `<stop offset="1" stop-color="${colour(rand)}"/></radialGradient>`,
      );
      fill = `url(#g${i})`;
    } else if (g < 0.7) {
      defs.push(
        `<linearGradient id="g${i}"><stop offset="0" stop-color="${colour(rand)}"/>` +
          `<stop offset="1" stop-color="${colour(rand)}"/></linearGradient>`,
      );
      fill = `url(#g${i})`;
    }
    const op = (0.55 + rand() * 0.3).toFixed(2);
    const kind = int(rand, 0, 3);
    if (kind === 0)
      body.push(`<circle cx="${cx}" cy="${cy}" r="${s}" fill="${fill}" opacity="${op}"/>`);
    else if (kind === 1)
      body.push(
        `<rect x="${cx - s}" y="${cy - Math.round(s / 2)}" width="${2 * s}" height="${s}" ` +
          `transform="rotate(${int(rand, 0, 89)} ${cx} ${cy})" fill="${fill}" opacity="${op}"/>`,
      );
    else if (kind === 2) {
      const pts = Array.from(
        { length: 3 },
        () => `${cx + int(rand, -s, s)},${cy + int(rand, -s, s)}`,
      ).join(" ");
      body.push(`<polygon points="${pts}" fill="${fill}" opacity="${op}"/>`);
    } else
      body.push(
        `<ellipse cx="${cx}" cy="${cy}" rx="${s}" ry="${Math.max(4, Math.round(s / 3))}" ` +
          `transform="rotate(${int(rand, 0, 179)} ${cx} ${cy})" fill="${fill}" opacity="${op}"/>`,
      );
  }
  // 細い線を数本。平らな面ばかりだと pHash の中央値付近に係数が集まり、再保存だけで bit が揺れやすい
  for (let i = 0; i < 4; i++) {
    body.push(
      `<line x1="${int(rand, 0, w)}" y1="${int(rand, 0, h)}" x2="${int(rand, 0, w)}" y2="${int(rand, 0, h)}" ` +
        `stroke="${colour(rand)}" stroke-width="${int(rand, 3, 9)}"/>`,
    );
  }
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">` +
    `<defs>${defs.join("")}</defs>${body.join("")}</svg>`
  );
}

/** SVG を 8bit RGB の画素にする。以降の別版はすべてこの画素から作る */
async function rasterize(svg) {
  const { data, info } = await sharp(Buffer.from(svg))
    .flatten({ background: "#ffffff" })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  return { data, w: info.width, h: info.height };
}

const fromRaw = ({ data, w, h }) => sharp(data, { raw: { width: w, height: h, channels: 3 } });

// 40px の描き足しの明るさの差。格子の差（12 を大きく超える）は保ちつつ、pHash の動きを似ているの
// 上限 10 より十分内側に収める（白黒の四角だと pHash が 10 を超えて束から外れることがある）
const PATCH_DELTA = 50;
// 小さな描き足しの明るさの差。覆う面積と掛けて格子の差が 3 を確実に超えるように、こちらは強めにする
const SMALL_PATCH_DELTA = 80;

/**
 * 16x16 格子の (cx,cy) のマスの中心に、周りと逆の明るさの四角を描く。
 * 格子のマスに合わせるのは、描き足しがどのマスにどれだけ効くかを寸法によらず揃えるため。
 */
function paintPatch(img, cx, cy, side, delta) {
  const { data, w, h } = img;
  const out = Buffer.from(data);
  const mx = Math.round(((cx + 0.5) * w) / 16);
  const my = Math.round(((cy + 0.5) * h) / 16);
  const x0 = Math.max(0, mx - Math.floor(side / 2));
  const y0 = Math.max(0, my - Math.floor(side / 2));
  const x1 = Math.min(w, x0 + side);
  const y1 = Math.min(h, y0 + side);
  let sum = 0;
  let n = 0;
  for (let y = y0; y < y1; y++)
    for (let x = x0; x < x1; x++) {
      const i = (y * w + x) * 3;
      sum += (77 * data[i] + 150 * data[i + 1] + 29 * data[i + 2]) >> 8;
      n++;
    }
  const mean = n ? sum / n : 128;
  const v = Math.round(mean < 128 ? Math.min(235, mean + delta) : Math.max(20, mean - delta));
  for (let y = y0; y < y1; y++)
    for (let x = x0; x < x1; x++) {
      const i = (y * w + x) * 3;
      out[i] = v;
      out[i + 1] = v;
      out[i + 2] = v;
    }
  return { data: out, w, h };
}

// ---------------------------------------------------------------- サムネ

/** アプリの makeImageThumb と同じ形（長辺 512・拡大しない・透過は黒・JPEG q82） */
export async function jpegThumb(bytes) {
  return sharp(bytes)
    .rotate()
    .resize(THUMB_EDGE, THUMB_EDGE, { fit: "inside", withoutEnlargement: true })
    .flatten({ background: "#000000" })
    .jpeg({ quality: THUMB_JPEG_QUALITY })
    .toBuffer();
}

export async function webpThumb(bytes) {
  return sharp(bytes)
    .rotate()
    .resize(THUMB_EDGE, THUMB_EDGE, { fit: "inside", withoutEnlargement: true })
    .webp({ quality: THUMB_WEBP_QUALITY })
    .toBuffer();
}

// 別版のサムネの種類の回り順。基の 3 枚（元絵・写し・再保存）以外の 8 枚に、ずらしながら当てる
const THUMB_CYCLE = ["jpeg", null, "webp", "jpeg", null, "jpeg", "webp", null];

// ---------------------------------------------------------------- 生成

const CONTENT_TYPE = {
  png: "image/png",
  jpg: "image/jpeg",
  webp: "image/webp",
  mp4: "video/mp4",
};

const pad = (n) => String(n).padStart(2, "0");
const sha256 = (b) => createHash("sha256").update(b).digest("hex");

/**
 * 種まきする物を全部メモリ上に作る（通信しない）。同じ seed なら同じバイト列・同じ期待になる。
 * 返す files はアップロードの順。元絵を写しより先に置くのは、同じ中身の組で古い方が残す物になるため。
 */
export async function generateFixture({ seed = 1 } = {}) {
  const files = [];
  const checks = [];
  const album = [];
  const top = rng(seed);
  const add = (f) => {
    files.push({
      ...f,
      contentType: CONTENT_TYPE[f.key.slice(f.key.lastIndexOf(".") + 1)],
      sha256: sha256(f.bytes),
    });
    return f.key;
  };

  for (let s = 0; s < SET_COUNT; s++) {
    const id = `s${pad(s + 1)}`;
    const [w, h] = BASE_SIZES[int(top, 0, BASE_SIZES.length - 1)];
    const art = await rasterize(illustrationSvg(Math.floor(top() * 2 ** 31), w, h));
    // 元絵には必ずサムネを付ける。Web はサムネのある物しか照合できないので、元絵が抜けると束の基準が変わる
    const baseThumb = s % 4 === 3 ? "webp" : "jpeg";
    const cell = () => [int(top, 3, 12), int(top, 3, 12)];
    const [px, py] = cell();
    let [qx, qy] = cell();
    if (qx === px && qy === py) qx = px < 12 ? px + 1 : px - 1;
    // 小さな描き足しはマスの約 11% を覆う大きさ。明るさの差 80 と掛けて格子の差が 9 前後になり、
    // 3 を超えて（差分かも）、12 前後に収まるように
    const small = Math.max(6, Math.round(Math.sqrt((0.11 * w * h) / 256)));

    // 元絵は無圧縮 PNG にする。同じ寸法の PNG の中で一番大きいファイルになり、残す物に決まるようにするため
    const base = await fromRaw(art).png({ compressionLevel: 0 }).toBuffer();
    const variants = [
      // [名前, 拡張子, バイト列, 元絵に対する期待]
      ["q40", "jpg", await fromRaw(art).jpeg({ quality: 40 }).toBuffer(), ["same"]],
      [
        "half",
        "jpg",
        await fromRaw(art)
          .resize(Math.round(w / 2), Math.round(h / 2))
          .jpeg({ quality: VARIANT_JPEG_QUALITY })
          .toBuffer(),
        ["same"],
      ],
      ["webp", "webp", await fromRaw(art).webp({ quality: 80 }).toBuffer(), ["same"]],
      [
        "bright",
        "jpg",
        await fromRaw(art).linear(1, 8).jpeg({ quality: VARIANT_JPEG_QUALITY }).toBuffer(),
        ["same"],
      ],
      [
        "patch40",
        "jpg",
        await fromRaw(paintPatch(art, px, py, 40, PATCH_DELTA))
          .jpeg({ quality: VARIANT_JPEG_QUALITY })
          .toBuffer(),
        ["similar"],
      ],
      // 同じ寸法・同じ形式（PNG）の小さな描き足し。差分かもの印が付くか、似ているに落ちるかのどちらか
      [
        "patch-small",
        "png",
        await fromRaw(paintPatch(art, qx, qy, small, SMALL_PATCH_DELTA))
          .png({ compressionLevel: 9 })
          .toBuffer(),
        ["variant", "similar"],
      ],
      [
        "hflip",
        "jpg",
        await fromRaw(art).flop().jpeg({ quality: VARIANT_JPEG_QUALITY }).toBuffer(),
        ["mirror"],
      ],
      // 片側の辺を 10% 削ると縦横比が ln(1/0.9) ≈ 0.105 ずれ、似ているの上限 0.10 を超えるので束にならない
      [
        "crop",
        "jpg",
        await fromRaw(art)
          .extract({ left: 0, top: 0, width: Math.round(w * 0.9), height: h })
          .jpeg({ quality: VARIANT_JPEG_QUALITY })
          .toBuffer(),
        ["none"],
      ],
    ];

    const baseKey = add({
      key: `${ROOT}/originals/${id}.png`,
      bytes: base,
      thumb: baseThumb,
      set: id,
      role: "base",
      width: w,
      height: h,
    });
    checks.push({ key: baseKey, with: baseKey, expect: ["keeper"], set: id, role: "base" });
    // 画素が同じ PNG の再保存。サムネは元絵と同じ種類にする（作り方が違うと格子が 3 を超えてずれ、差分かもに見える）
    const resaveKey = add({
      key: `${ROOT}/variants/${id}-resave.png`,
      bytes: await fromRaw(art).png({ compressionLevel: 9, adaptiveFiltering: true }).toBuffer(),
      thumb: baseThumb,
      set: id,
      role: "png",
      width: w,
      height: h,
    });
    checks.push({ key: resaveKey, with: baseKey, expect: ["same"], set: id, role: "png" });
    variants.forEach(([name, ext, bytes, expect], i) => {
      const thumb = THUMB_CYCLE[(i + s) % THUMB_CYCLE.length];
      const key = add({
        key: `${ROOT}/variants/${id}-${name}.${ext}`,
        bytes,
        thumb,
        set: id,
        role: name,
      });
      // 切り抜きはどの束にも入らないことを見たいので、束を絞らずに全体で確かめる
      checks.push(
        name === "crop"
          ? { key, expect, set: id, role: name }
          : { key, with: baseKey, expect, set: id, role: name },
      );
    });
    // 別フォルダの完全な写し。元絵より後に上げるので、古い方（元絵）が残る
    const copyKey = add({
      key: `${ROOT}/x-copies/${id}.png`,
      bytes: base,
      thumb: baseThumb,
      set: id,
      role: "copy",
      width: w,
      height: h,
    });
    checks.push({ key: copyKey, with: baseKey, expect: ["identical"], set: id, role: "copy" });

    // アルバム: 写し（同じファイル）・再保存（ほぼ同じ）・元絵と別版が両方入っている場合・反転・描き足し
    if (s === 0) album.push(copyKey, `${ROOT}/variants/${id}-q40.jpg`);
    if (s === 1) album.push(baseKey, `${ROOT}/variants/${id}-webp.webp`);
    if (s === 2)
      album.push(`${ROOT}/variants/${id}-hflip.jpg`, `${ROOT}/variants/${id}-patch40.jpg`);
    if (s === 3) album.push(`${ROOT}/variants/${id}-patch-small.png`, resaveKey);
  }

  for (let d = 0; d < DISTINCT_COUNT; d++) {
    const [w, h] = BASE_SIZES[d % BASE_SIZES.length];
    const art = await rasterize(illustrationSvg(Math.floor(top() * 2 ** 31), w, h));
    const png = d % 2 === 0;
    const key = add({
      key: `${ROOT}/distinct/d${pad(d + 1)}.${png ? "png" : "jpg"}`,
      bytes: png
        ? await fromRaw(art).png({ compressionLevel: 9 }).toBuffer()
        : await fromRaw(art).jpeg({ quality: VARIANT_JPEG_QUALITY }).toBuffer(),
      thumb: THUMB_CYCLE[d % THUMB_CYCLE.length],
      set: null,
      role: "distinct",
    });
    checks.push({ key, expect: ["none"], set: null, role: "distinct" });
    if (d === 0) album.splice(2, 0, key);
  }

  // 単色: 単色の印が付き、比べる対象から外れる（status.flat に数えられる）
  const flatKey = add({
    key: `${ROOT}/flat/gray.png`,
    bytes: await sharp({
      create: { width: 400, height: 300, channels: 3, background: { r: 150, g: 152, b: 149 } },
    })
      .png()
      .toBuffer(),
    thumb: "jpeg",
    set: null,
    role: "flat",
  });
  checks.push({ key: flatKey, expect: ["none"], set: null, role: "flat" });

  // 中身が同じ動画の組。見た目の署名は作らず、SHA-256 だけで同じファイルになる
  const vr = rng(seed ^ 0x5eed);
  const video = Buffer.alloc(VIDEO_BYTES);
  for (let i = 0; i < video.length; i++) video[i] = Math.floor(vr() * 256);
  const clipKey = add({
    key: `${ROOT}/video/clip.mp4`,
    bytes: video,
    thumb: null,
    set: null,
    role: "video",
  });
  const clipCopyKey = add({
    key: `${ROOT}/x-copies/clip.mp4`,
    bytes: Buffer.from(video),
    thumb: null,
    set: null,
    role: "video-copy",
  });
  checks.push({ key: clipKey, with: clipKey, expect: ["keeper"], set: null, role: "video" });
  checks.push({
    key: clipCopyKey,
    with: clipKey,
    expect: ["identical"],
    set: null,
    role: "video-copy",
  });

  // サムネのバイト列はここで作る（どの物に何を付けるかが決まってから）
  for (const f of files) {
    if (f.thumb === "jpeg") f.thumbBytes = await jpegThumb(f.bytes);
    else if (f.thumb === "webp") f.thumbBytes = await webpThumb(f.bytes);
    else f.thumbBytes = null;
  }
  const thumbOf = new Map(files.map((f) => [f.key, f.thumb]));
  for (const c of checks) c.thumb = thumbOf.get(c.key) ?? null;

  return { seed, files, checks, albumKeys: album };
}

/**
 * 上げた時刻（Worker が返す createdAt = R2 の uploaded）に合わせて、同じ中身の 2 枚（元絵と別フォルダの写し）の
 * どちらが残す物かの期待を直す。Worker の決まりは「古い順 → キー」で、種まきは元絵を先に上げるが、
 * R2 の uploaded は手元の時計で付くので、時計が戻ると（WSL の時刻合わせなど）写しの方が古くなる。
 * その時に期待を元絵のままにすると、Worker が決まりどおりに動いていても食い違いになる（#F5 のゆれ）。
 * 返す swapped は入れ替えた組と時刻（記録に残すため）。
 */
export function alignKeepers(fx, uploadedAt) {
  const checks = fx.checks.map((c) => ({ ...c, expect: [...c.expect] }));
  const bySet = new Map();
  for (const c of checks) {
    if (c.role !== "base" && c.role !== "copy") continue;
    if (!bySet.has(c.set)) bySet.set(c.set, {});
    bySet.get(c.set)[c.role] = c;
  }
  const swapped = [];
  for (const [set, { base, copy }] of bySet) {
    if (!base || !copy) continue;
    const tb = uploadedAt.get(base.key);
    const tc = uploadedAt.get(copy.key);
    if (tb === undefined || tc === undefined) continue;
    const copyFirst = tc < tb || (tc === tb && copy.key < base.key);
    if (!copyFirst) continue;
    swapped.push({ set, base: tb, copy: tc });
    for (const c of checks) if (c.set === set && c.with === base.key) c.with = copy.key;
    base.expect = ["identical"];
    copy.expect = ["keeper"];
  }
  return { fx: { ...fx, checks }, swapped };
}

/** 上げた順に並べた時刻のうち、前の物より古い物の数と、最も大きな戻り（ms） */
export function clockSteps(files, uploadedAt) {
  let max = -Infinity;
  let back = 0;
  let worst = 0;
  for (const f of files) {
    const t = uploadedAt.get(f.key);
    if (t === undefined) continue;
    if (t < max) {
      back++;
      worst = Math.max(worst, max - t);
    }
    max = Math.max(max, t);
  }
  return { back, worst };
}

async function uploadedTimes(api, lib) {
  const out = new Map();
  let cursor = "";
  for (let page = 0; page < 1000; page++) {
    const listed = await api.get(
      `${libPath(lib)}/folders?prefix=${encodeURIComponent(`${ROOT}/`)}&recursive=1&fresh=1` +
        (cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""),
    );
    for (const it of listed.items ?? []) {
      if (typeof it.createdAt === "number") out.set(it.key, it.createdAt);
    }
    cursor = listed.cursor ?? "";
    if (!cursor) break;
  }
  return out;
}

/** 生成した物から期待ファイルを作る。albumId は種まきの後にしか分からない */
export function expectedOf(fx, { lib, albumId = null, albumTitle = null }) {
  const images = fx.files.filter((f) => !f.contentType.startsWith("video/"));
  return {
    version: 1,
    lib,
    seed: fx.seed,
    root: `${ROOT}/`,
    flatAtLeast: fx.files.filter((f) => f.role === "flat").length,
    counts: {
      files: fx.files.length,
      images: images.length,
      videos: fx.files.length - images.length,
      thumbJpeg: images.filter((f) => f.thumb === "jpeg").length,
      thumbWebp: images.filter((f) => f.thumb === "webp").length,
      thumbNone: images.filter((f) => !f.thumb).length,
    },
    // thumb は key のサムネの種類（null はサムネ無し）。Web は thumb のある物しか照合できない
    checks: fx.checks,
    album: { id: albumId, title: albumTitle, keys: fx.albumKeys },
    items: fx.files.map((f) => ({
      key: f.key,
      set: f.set,
      role: f.role,
      size: f.bytes.length,
      sha256: f.sha256,
      thumb: f.thumb,
    })),
  };
}

// ---------------------------------------------------------------- 通信

function makeApi(origin, token, fetchImpl) {
  async function call(method, path, { body, headers = {}, json = true } = {}) {
    let res;
    try {
      res = await fetchImpl(origin + path, {
        method,
        headers: { authorization: `Bearer ${token}`, ...headers },
        body,
      });
    } catch (e) {
      // 例外の文言は宛先を含み得るので、経路と種類だけにする
      throw new Error(
        `network ${e?.cause?.code ?? e?.name ?? "error"} ${method} ${path.split("?")[0]}`,
      );
    }
    if (!res.ok) {
      let code = "";
      try {
        code = (await res.json())?.error ?? "";
      } catch {
        code = "";
      }
      const err = new Error(`HTTP ${res.status} ${code} ${method} ${path.split("?")[0]}`.trim());
      err.status = res.status;
      err.code = code;
      throw err;
    }
    return json ? res.json() : res;
  }
  return {
    get: (path) => call("GET", path),
    post: (path, data) =>
      call("POST", path, {
        body: JSON.stringify(data),
        headers: { "content-type": "application/json" },
      }),
    put: (path, bytes, contentType) =>
      call("PUT", path, { body: bytes, headers: { "content-type": contentType } }),
  };
}

const libPath = (lib) => `/v1/${encodeURIComponent(lib)}`;

/** 前の種が残っていると、上げ直しが 409 になり、残す物の古さの順も崩れる。空の状態からだけ始める */
async function assertFresh(api, lib) {
  const listed = await api.get(
    `${libPath(lib)}/folders?prefix=${encodeURIComponent(`${ROOT}/`)}&recursive=1&fresh=1`,
  );
  if ((listed.items ?? []).length) {
    throw new Error(
      `${ROOT}/ に既に物がある。wrangler dev の --persist-to の場所を消してから起動し直す`,
    );
  }
}

async function seed(api, lib, fx, log) {
  let i = 0;
  // 上げる順が「古さ」になるので、1 件ずつ順に送る
  for (const f of fx.files) {
    await api.put(
      `${libPath(lib)}/objects?key=${encodeURIComponent(f.key)}`,
      f.bytes,
      f.contentType,
    );
    if (++i % 50 === 0) log(`上げた ${i} / ${fx.files.length}`);
  }
  let thumbs = 0;
  for (const f of fx.files) {
    if (!f.thumbBytes) continue;
    await api.put(
      `${libPath(lib)}/thumb?key=${encodeURIComponent(f.key)}`,
      f.thumbBytes,
      f.thumb === "webp" ? "image/webp" : "image/jpeg",
    );
    thumbs++;
  }
  const title = `similar-e2e (seed ${fx.seed})`;
  const created = await api.post(`${libPath(lib)}/albums`, { title });
  await api.post(`${libPath(lib)}/albums/${encodeURIComponent(created.id)}/items`, {
    keys: fx.albumKeys,
  });
  log(
    `上げた ${fx.files.length} 件・サムネ ${thumbs} 枚・アルバム 1 つ (${fx.albumKeys.length} 件)`,
  );
  return { albumId: created.id, albumTitle: title };
}

async function scanHashes(api, lib, log) {
  for (let round = 0; round < 200; round++) {
    const r = await api.post(`${libPath(lib)}/duplicates/scan`, {});
    if (!r.pending) {
      log(`中身の確認が終わった（skipped ${r.skipped ?? 0}）`);
      return;
    }
    if (!r.hashed) throw new Error(`duplicates/scan が進まない (pending ${r.pending})`);
  }
  throw new Error("duplicates/scan が 200 回で終わらない");
}

/** CLI の本体。戻り値は終了コード。テストから fetch と出力先を差し替えられる */
export async function main(
  argv,
  {
    env = process.env,
    root = REPO_ROOT,
    fetchImpl = fetch,
    log = (m) => console.log(m),
    warn = (m) => console.error(m),
  } = {},
) {
  let args;
  try {
    ({ values: args } = parseArgs({
      args: argv,
      options: {
        endpoint: { type: "string" },
        token: { type: "string" },
        lib: { type: "string", default: "a" },
        seed: { type: "string", default: "1" },
        out: { type: "string" },
        scan: { type: "boolean", default: false },
      },
    }));
  } catch (e) {
    warn(`error: ${e instanceof Error ? e.message : String(e)}`);
    return 1;
  }
  let origin;
  try {
    // 宛先の確認は何よりも先に行う。手元以外へは 1 回も要求を出さない
    origin = assertLocalEndpoint(args.endpoint ?? env.R2G_ENDPOINT);
  } catch (e) {
    warn(`error: ${e.message}`);
    return 1;
  }
  const token = String(args.token ?? env.R2G_TOKEN ?? "").trim();
  if (!token) {
    warn("error: --token（または R2G_TOKEN）を渡す");
    return 1;
  }
  if (!/^[A-Za-z0-9_-]+$/.test(args.lib)) {
    warn("error: --lib は英数字・_・- だけの名前で渡す");
    return 1;
  }
  const seedValue = Number(args.seed);
  if (!Number.isInteger(seedValue) || seedValue < 0) {
    warn("error: --seed は 0 以上の整数");
    return 1;
  }
  const out = resolve(root, args.out ?? DEFAULT_OUT);
  // 期待ファイルは git に入らない .work/ の下にだけ書く
  const rel = relative(join(root, ".work"), out);
  if (rel.startsWith("..") || resolve(join(root, ".work"), rel) !== out) {
    warn("error: --out は .work/ の下を指す");
    return 1;
  }
  try {
    const api = makeApi(origin, token, fetchImpl);
    await assertFresh(api, args.lib);
    log("絵を作っている…");
    const fx = await generateFixture({ seed: seedValue });
    const placed = await seed(api, args.lib, fx, log);
    if (args.scan) await scanHashes(api, args.lib, log);
    // 上げた時刻を読み戻し、時計が戻っていたら記録して、残す物の期待を実際の古さに合わせる
    const times = await uploadedTimes(api, args.lib);
    const steps = clockSteps(fx.files, times);
    if (steps.back) {
      warn(
        `warning: 上げた時刻が ${steps.back} 件で前の物より古い（最大 ${steps.worst} ms 戻った）。` +
          "手元の時計が戻ったと見る",
      );
    }
    const aligned = alignKeepers(fx, times);
    for (const s of aligned.swapped) {
      warn(
        `warning: ${s.set} は写しの方が古い（元絵 ${s.base} / 写し ${s.copy}）。残す物の期待を写しにした`,
      );
    }
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(
      out,
      `${JSON.stringify(expectedOf(aligned.fx, { lib: args.lib, ...placed }), null, 2)}\n`,
    );
    log(
      `期待: ${relative(root, out)}（確かめる項目 ${fx.checks.length} 件・時刻を読めた物 ${times.size} 件・` +
        `時刻の戻り ${steps.back} 件・残す物を入れ替えた組 ${aligned.swapped.length}）`,
    );
    return 0;
  } catch (e) {
    warn(`error: ${e instanceof Error ? e.message : String(e)}`);
    return 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main(process.argv.slice(2));
}
