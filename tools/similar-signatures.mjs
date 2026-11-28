#!/usr/bin/env node
/**
 * 見た目の照合 "vs1" の PC ツール。署名・判定・束ね方は Worker の基準実装
 * （worker/src/lib/similar/core.ts）を Node の型除去でそのまま読み込んで使う。
 * 写し直すと Worker・アプリと 1 bit でもずれた時に、報告の数字が本番の判定と食い違うため。
 *
 *   report（既定・読み取り専用）: 一覧とサムネを読んでローカルで束ね、
 *     .work/similar-report/<lib>/ に stats.json と report.html（ラベル付け用）だけを書く。
 *     --include-originals  サムネの無い物は原本からアプリと同じ 512px JPEG q82 を作って照合する
 *     --probe-dims         原本の先頭 64 KB から寸法を読む（差分かもの判定と残す物の順に使う）
 *     --seed N             report.html に載せる見本の選び方（既定 1）
 *   --score labels.json : report.html から書き出したラベルで、判定ごとの適合率を出す（通信しない）
 *   --purge             : .work/similar-report/<lib>/ を消す（通信しない）
 *   write               : /similar/todo を全シャード歩き、署名を作って 200 件ずつ POST する
 *   --check-expected f  : サーバーの GET /similar が f の期待どおりかを確かめる（write の後にも付けられる）
 *
 * Usage:
 *   R2G_ENDPOINT=https://... R2G_TOKEN=... node tools/similar-signatures.mjs report --lib <id> \
 *     [--probe-dims] [--include-originals] [--seed 1]
 *   node tools/similar-signatures.mjs --score labels.json
 *   node tools/similar-signatures.mjs --purge --lib <id>
 *   R2G_ENDPOINT=http://127.0.0.1:8787 R2G_TOKEN=... node tools/similar-signatures.mjs write --lib a \
 *     [--check-expected .work/similar-e2e/expected.json]
 *
 * --check-expected のファイル（tools/similar-fixture-seed.mjs が書く）:
 *   {"version":1, "lib":"a", "flatAtLeast"?: N,
 *    "checks":[{"key":"<key>", "with"?:"<key>", "expect":["same","variant", ...]}]}
 *   expect に並べる語: keeper / identical / same / variant（same のうち差分かも）/ mirror / similar / none。
 *   with があれば with を含む束（dup・similar 両方）の中での key の扱い、無ければ全部の束の中での扱いを見る。
 *   どの束にも居なければ none。status の pending が 0 であることも必ず確かめる。
 *
 * R2G_ENDPOINT と R2G_TOKEN は表示も保存もしない。署名付き URL もログに出さない（期限内は誰でも読めるため）。
 * 画像は外部へ送らない。report.html は成人向けの中身を含み得るので、commit・アップロード・公開をしない。
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import sharp from "sharp";
import {
  FLAG_FLAT,
  FLAG_FROM_ORIGINAL,
  FLAG_MULTI_FRAME,
  PARAMS,
  encodeSig,
  extOf,
  groupNodes,
  sigInfo,
  sigTableOf,
  vs1FromRgba,
} from "../worker/src/lib/similar/core.ts";
// 原本の寸法も Worker が署名の POST 時に読むのと同じ読み方にする（差分かもの判定が報告と本番で揃うように）
import { PROBE_BYTES, probeDims } from "../worker/src/lib/similar/probe.ts";

export const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));

const mediaExt = JSON.parse(
  readFileSync(new URL("../worker/src/lib/media-ext.json", import.meta.url), "utf8"),
);
// 一覧が画像として扱う拡張子は Worker と同じ表から作る（片方だけ増えると数が合わなくなる）
export const IMAGE_RE = new RegExp(`\\.(${mediaExt.image.join("|")})$`, "i");

/** アプリの makeImageThumb と同じ寸法と画質。同じ入力から署名を作るため */
const THUMB_LONG_EDGE = 512;
const THUMB_QUALITY = 82;
/** アプリの maxThumbSourceBytes と同じ上限。超える原本は too_large として記録する */
export const MAX_SOURCE_BYTES = 32 * 1024 * 1024;
/** アプリがサムネを読む時の上限と同じ */
const MAX_THUMB_BYTES = 4 * 1024 * 1024;
const REPORT_PARALLEL = 16;
const WRITE_PARALLEL = 8;
// 原本は 1 枚 32 MiB まであるので、サムネと同じ数を同時に抱えるとメモリが足りなくなる
const ORIGINAL_PARALLEL = 4;
const SHARDS = 32;
const TODO_LIMIT = 300;
const POST_BATCH = 200;
const GROUP_SAMPLES = 40;
const MEMBER_SAMPLES = 100;
const PREVIEW_EDGE = 200;

export class TooLargeError extends Error {}
export class DecodeError extends Error {}
export class ApiError extends Error {
  constructor(status, code, path) {
    super(`HTTP ${status} ${code ?? ""} ${path}`.replace(/\s+/g, " ").trim());
    this.status = status;
    this.code = code;
  }
}

// ---------------------------------------------------------------- 署名

/**
 * 符号化された画像から vs1 署名を作る。EXIF の向きは rotate() で直してから画素にする（Dart は bakeOrientation）。
 * toColourspace("srgb") を挟むのは、灰色の画像が 2 チャンネルで出てきて RGBA にならないため。
 * 多フレームの画像は先頭だけを使い、その印を立てる。
 */
export async function signatureOf(bytes, { fromOriginal = false } = {}) {
  let data;
  let info;
  let pages = 1;
  try {
    pages = (await sharp(bytes, { failOn: "error" }).metadata()).pages ?? 1;
    ({ data, info } = await sharp(bytes, { failOn: "error" })
      .rotate()
      .toColourspace("srgb")
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true }));
  } catch (e) {
    throw new DecodeError(e instanceof Error ? e.message : String(e));
  }
  if (info.channels !== 4) throw new DecodeError(`channels ${info.channels}`);
  const flags = (fromOriginal ? FLAG_FROM_ORIGINAL : 0) | (pages > 1 ? FLAG_MULTI_FRAME : 0);
  return vs1FromRgba(info.width, info.height, data, flags);
}

/**
 * サムネの無い原本から、アプリの makeImageThumb と同じ形の 512px JPEG q82 を作る。
 * アプリはエンジンの乗算済み RGBA をそのまま JPEG に詰めるので、透過は黒の上に置かれる。ここも黒に合わせる。
 */
export async function appThumbOf(bytes) {
  try {
    return await sharp(bytes, { failOn: "error" })
      .rotate()
      .resize(THUMB_LONG_EDGE, THUMB_LONG_EDGE, { fit: "inside", withoutEnlargement: true })
      .flatten({ background: "#000000" })
      .jpeg({ quality: THUMB_QUALITY })
      .toBuffer();
  } catch (e) {
    throw new DecodeError(e instanceof Error ? e.message : String(e));
  }
}

/** 原本から署名を作る。アプリと同じく、作った JPEG のバイト列から署名する（どの端末でも同じ入力になる） */
export async function signatureFromOriginal(bytes) {
  return signatureOf(await appThumbOf(bytes), { fromOriginal: true });
}

// ---------------------------------------------------------------- 通信

/**
 * Worker との通信。トークンは endpoint への要求にだけ付け、署名付き URL には付けない。
 * 失敗の文言には経路だけを入れ、ホスト名・クエリ（署名）は入れない。
 */
export function makeApi({ endpoint, token, fetchImpl = fetch }) {
  const base = endpoint.replace(/\/+$/, "");
  const stats = { bytes: 0 };
  const pathOf = (u) => {
    try {
      return new URL(u, base).pathname;
    } catch {
      return "(url)";
    }
  };
  async function send(url, init, authed) {
    for (let attempt = 0; ; attempt++) {
      let res;
      try {
        res = await fetchImpl(url, {
          ...init,
          headers: authed
            ? {
                authorization: `Bearer ${token}`,
                "content-type": "application/json",
                ...init.headers,
              }
            : { ...init.headers },
        });
      } catch (e) {
        // fetch の例外は接続先の住所を含み得るので、経路と種類だけに言い換える
        if (attempt < 3) {
          await sleep(1000 * (attempt + 1));
          continue;
        }
        const code = e?.cause?.code ?? e?.name ?? "error";
        throw new Error(`network ${code} ${authed ? pathOf(url) : "(signed url)"}`);
      }
      if (res.ok) return res;
      // 一覧の途中で Worker が 503 を返すことがあるので、少し待って取り直す
      if ((res.status === 503 || res.status === 429) && attempt < 4) {
        await res.body?.cancel();
        await sleep(1500 * (attempt + 1));
        continue;
      }
      let code = null;
      try {
        code = (await res.json())?.error ?? null;
      } catch {
        code = null;
      }
      throw new ApiError(res.status, code, authed ? pathOf(url) : "(signed url)");
    }
  }
  return {
    stats,
    async get(path) {
      return (await send(base + path, { method: "GET" }, true)).json();
    },
    async post(path, body) {
      return (await send(base + path, { method: "POST", body: JSON.stringify(body) }, true)).json();
    },
    /** 署名付き URL を読む。max を超える物は読み切らずに TooLargeError にする */
    async bytes(url, { max, range } = {}) {
      const res = await send(url, { method: "GET", headers: range ? { range } : {} }, false);
      const len = Number(res.headers.get("content-length"));
      if (max && Number.isFinite(len) && len > max) {
        await res.body?.cancel();
        throw new TooLargeError(`${len}`);
      }
      const buf = Buffer.from(await res.arrayBuffer());
      stats.bytes += buf.length;
      if (max && buf.length > max) throw new TooLargeError(`${buf.length}`);
      return buf;
    },
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const libPath = (lib) => `/v1/${encodeURIComponent(lib)}`;

export async function listLibraryItems(api, lib) {
  const items = [];
  let cursor = "";
  for (;;) {
    const q = `recursive=1&order=recent${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
    const d = await api.get(`${libPath(lib)}/folders?${q}`);
    items.push(...(d.items ?? []));
    if (!d.cursor) break;
    cursor = d.cursor;
  }
  return items;
}

/** SHA-256 で中身が同じと記録済みの束。動画もここに入る */
export async function listExactGroups(api, lib) {
  const groups = [];
  let cursor = "";
  let pending = 0;
  let skipped = 0;
  for (;;) {
    const q = `limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
    const d = await api.get(`${libPath(lib)}/duplicates?${q}`);
    groups.push(...(d.groups ?? []));
    pending = d.pending ?? 0;
    skipped = d.skipped ?? 0;
    if (!d.cursor) break;
    cursor = d.cursor;
  }
  return { groups, pending, skipped };
}

/** 結果の順を保ったまま n 本ずつ並べて走らせる */
export async function pool(items, n, fn) {
  const out = new Array(items.length);
  let next = 0;
  const worker = async () => {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      out[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker));
  return out;
}

function limiter(n) {
  let active = 0;
  const queue = [];
  const run = () => {
    if (active >= n || !queue.length) return;
    active++;
    const { fn, ok, ng } = queue.shift();
    fn()
      .then(ok, ng)
      .finally(() => {
        active--;
        run();
      });
  };
  return (fn) =>
    new Promise((ok, ng) => {
      queue.push({ fn, ok, ng });
      run();
    });
}

// ---------------------------------------------------------------- 束ねる

/**
 * Worker の GET /similar と同じ節の作り方: SHA-256 が同じ物の集まりを 1 節に（動画も含む）、
 * それ以外は署名があって単色でない画像を 1 件 1 節にする。同じ中身の集まりは一員の署名を使う。
 */
export function buildNodes({ metas, sigs, exactGroups }) {
  const sigList = [];
  const rowOf = new Map();
  for (const [key, sig] of sigs) {
    rowOf.set(key, sigList.length);
    sigList.push(sig);
  }
  const table = sigTableOf(sigList);
  const flat = (key) => (sigInfo(sigs.get(key)).flags & FLAG_FLAT) !== 0;
  const inExact = new Set();
  const nodes = [];
  for (const g of exactGroups) {
    // Worker と同じく古い順に見て、最初の単色でない署名を使う（残す物になる物の署名を優先する）
    const keys = g.keys
      .filter((k) => metas.has(k))
      .sort((a, b) => metas.get(a).uploaded - metas.get(b).uploaded || (a < b ? -1 : 1));
    if (keys.length < 2) continue;
    keys.forEach((k) => inExact.add(k));
    const signed = keys.filter((k) => rowOf.has(k));
    const pick = signed.find((k) => !flat(k)) ?? signed[0];
    nodes.push({ members: keys.map((k) => metas.get(k)), sig: pick ? rowOf.get(pick) : -1 });
  }
  for (const [key, row] of rowOf) {
    if (inExact.has(key) || flat(key) || !metas.has(key)) continue;
    nodes.push({ members: [metas.get(key)], sig: row });
  }
  return { nodes, table };
}

const bump = (h, v) => {
  if (v === undefined) return;
  h[v] = (h[v] ?? 0) + 1;
};

/** 束から数字だけを集める（key は stats.json に書かない） */
export function summarize(groups, exactGroups) {
  const tiers = {
    dup: {
      groups: 0,
      items: 0,
      reclaimable: 0,
      variants: 0,
      byMatch: {
        identical: { items: 0, bytes: 0 },
        same: { items: 0, bytes: 0 },
        mirror: { items: 0, bytes: 0 },
      },
    },
    similar: { groups: 0, items: 0, reclaimable: 0 },
  };
  const histograms = {};
  const where = new Map();
  for (const g of groups) {
    const t = tiers[g.tier];
    t.groups++;
    for (const it of g.items) {
      if (g.tier === "dup") {
        where.set(it.member.key, { id: g.id, match: it.match, variant: it.variant });
      }
      if (it.match === "keeper") continue;
      t.items++;
      const size = it.member.size || 0;
      if (g.tier === "dup") {
        const b = tiers.dup.byMatch[it.match];
        b.items++;
        b.bytes += size;
        if (it.variant) tiers.dup.variants++;
        // サーバーの reclaim と同じく、反転と差分かもは「空けられる量」に数えない
        if (it.match !== "mirror" && !it.variant) t.reclaimable += size;
      } else {
        t.reclaimable += size;
      }
      if (it.match === "identical") continue;
      const label = it.variant ? "variant" : it.match;
      const h = (histograms[label] ??= { ph: {}, dh: {}, mph: {}, gMax: {} });
      bump(h.ph, it.ph);
      bump(h.dh, it.dh);
      bump(h.mph, it.mph);
      bump(h.gMax, it.gMax);
    }
  }
  // 既存の SHA-256 の束が、1 つの dup の束にまとまり、残す物以外が全部「すべての重複」で選べる形で
  // 出るか（together = asIdentical + absorbed。これが groups と等しい事が出す条件の 100%）。
  // 残す物と identical なら asIdentical、別の代表に「ほぼ同じ」（差分かもでない）として丸ごと
  // 取られたなら absorbed。反転・似ている・差分かもとして取られた写しは選ばれないので unselectable
  const shaParity = {
    groups: 0,
    together: 0,
    asIdentical: 0,
    absorbed: 0,
    unselectable: 0,
    split: 0,
  };
  for (const g of exactGroups) {
    if (g.keys.length < 2) continue;
    shaParity.groups++;
    const at = g.keys.map((k) => where.get(k));
    if (at.some((w) => !w) || new Set(at.map((w) => w.id)).size !== 1) {
      shaParity.split++;
      continue;
    }
    const rest = at.filter((w) => w.match !== "keeper");
    if (at.length - rest.length <= 1 && rest.every((w) => w.match === "identical")) {
      shaParity.asIdentical++;
      shaParity.together++;
    } else if (rest.every((w) => w.match === "same" && !w.variant)) {
      shaParity.absorbed++;
      shaParity.together++;
    } else shaParity.unselectable++;
  }
  return { tiers, histograms, shaParity };
}

// ---------------------------------------------------------------- report.html

/** 再現できる乱数（mulberry32）。同じ --seed なら同じ見本を選ぶ */
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

function sample(list, n, rand) {
  const a = [...list];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a.slice(0, n);
}

/** ラベル付けに出す見本: dup と similar の束を 40 ずつ、ほぼ同じと似ているの一員を 100 ずつ */
export function pickSamples(groups, seed = 1) {
  const rand = rng(seed);
  const dup = groups.filter((g) => g.tier === "dup");
  const sim = groups.filter((g) => g.tier === "similar");
  const membersOf = (list, pred) =>
    list.flatMap((g) =>
      g.items.filter((it) => it.match !== "keeper" && pred(it)).map((it) => ({ g, it })),
    );
  return {
    dupGroups: sample(dup, GROUP_SAMPLES, rand),
    simGroups: sample(sim, GROUP_SAMPLES, rand),
    sameMembers: sample(
      membersOf(dup, (it) => it.match === "same"),
      MEMBER_SAMPLES,
      rand,
    ),
    similarMembers: sample(
      membersOf(sim, (it) => it.match === "similar"),
      MEMBER_SAMPLES,
      rand,
    ),
  };
}

export function sampleKeys(samples) {
  const keys = new Set();
  for (const g of [...samples.dupGroups, ...samples.simGroups])
    g.items.forEach((it) => keys.add(it.member.key));
  for (const { g, it } of [...samples.sameMembers, ...samples.similarMembers]) {
    keys.add(g.items[0].member.key);
    keys.add(it.member.key);
  }
  return keys;
}

const escapeHtml = (s) =>
  String(s).replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );

const MATCH_JA = {
  keeper: "オリジナル",
  identical: "同じファイル",
  same: "ほぼ同じ",
  mirror: "反転",
  similar: "似ている",
};
const ANSWERS = [
  ["same", "同じ絵"],
  ["diff", "差分"],
  ["other", "別物"],
];

const mb = (n) => `${(n / 1024 / 1024).toFixed(1)} MB`;

/**
 * 持ち主がラベルを付ける 1 枚の HTML。画像は data URI で埋めて、外のどこにも取りに行かない
 * （署名付き URL は期限が切れるうえ、開くたびに本番へ要求が飛ぶため）。
 * 答えはブラウザの localStorage に残し、labels.json として書き出して --score に渡す。
 */
export function reportHtml({ lib, stats, samples, previews }) {
  const pairs = [];
  const pairIndex = new Map();
  const pidOf = (keeper, it) => {
    const id = `${keeper}\n${it.member.key}`;
    if (!pairIndex.has(id)) {
      pairIndex.set(id, `p${pairs.length}`);
      pairs.push({
        keeper,
        key: it.member.key,
        match: it.match,
        variant: !!it.variant,
        ph: it.ph ?? null,
        dh: it.dh ?? null,
        mph: it.mph ?? null,
        gMax: it.gMax ?? null,
      });
    }
    return pairIndex.get(id);
  };
  let q = 0;
  const img = (key) => {
    const src = previews.get(key);
    return src
      ? `<img src="${escapeHtml(src)}" alt="">`
      : `<div class="noimg">画像を読めなかった</div>`;
  };
  const caption = (it) => {
    const tag = it.variant ? `${MATCH_JA[it.match]}・差分かも` : MATCH_JA[it.match];
    const nums =
      it.match === "keeper"
        ? ""
        : ` ph${it.ph ?? "-"} dh${it.dh ?? "-"} mph${it.mph ?? "-"} g${it.gMax ?? "-"}`;
    return `<figcaption><b>${escapeHtml(tag)}</b>${escapeHtml(nums)} ${escapeHtml(mb(it.member.size || 0))}<br><code>${escapeHtml(it.member.key)}</code></figcaption>`;
  };
  const radios = (pid) => {
    const name = `q${q++}`;
    return `<div class="ans">${ANSWERS.map(
      ([v, ja]) => `<label><input type="radio" name="${name}" value="${v}">${ja}</label>`,
    ).join("")}</div>`;
  };
  const tile = (keeper, it) => {
    if (it.match === "keeper")
      return `<figure class="keeper">${img(it.member.key)}${caption(it)}</figure>`;
    const pid = pidOf(keeper, it);
    return `<figure data-pair="${pid}">${img(it.member.key)}${caption(it)}${radios(pid)}</figure>`;
  };
  const group = (g) => {
    const keeper = g.items[0].member.key;
    return `<section class="group"><h3>${g.items.length}件</h3><div class="grid">${g.items
      .map((it) => tile(keeper, it))
      .join("")}</div></section>`;
  };
  const member = ({ g, it }) => {
    const keeper = g.items[0];
    return `<section class="pair"><div class="grid">${tile(keeper.member.key, keeper)}${tile(
      keeper.member.key,
      it,
    )}</div></section>`;
  };
  const t = stats.tiers;
  const body = [
    `<h2>重複の束（無作為に ${samples.dupGroups.length} 組）</h2>`,
    ...samples.dupGroups.map(group),
    `<h2>似ている束（無作為に ${samples.simGroups.length} 組）</h2>`,
    ...samples.simGroups.map(group),
    `<h2>「ほぼ同じ」の一員（無作為に ${samples.sameMembers.length} 件）</h2>`,
    ...samples.sameMembers.map(member),
    `<h2>「似ている」の一員（無作為に ${samples.similarMembers.length} 件）</h2>`,
    ...samples.similarMembers.map(member),
  ].join("\n");
  // </script> で閉じられないよう < を逃がしてから埋める
  const pairsJson = JSON.stringify(Object.fromEntries(pairs.map((p, i) => [`p${i}`, p]))).replace(
    /</g,
    "\\u003c",
  );
  const libJson = JSON.stringify(String(lib)).replace(/</g, "\\u003c");
  return `<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>見た目の照合レポート</title>
<style>
:root{--bg:#fff;--fg:#1c1c1c;--muted:#666;--line:#ddd;--keeper:#e8f1ff;--pick:#fff4d6}
@media (prefers-color-scheme:dark){:root{--bg:#141414;--fg:#eee;--muted:#aaa;--line:#333;--keeper:#1d2a3d;--pick:#3a3020}}
body{background:var(--bg);color:var(--fg);font-family:system-ui,sans-serif;margin:16px;line-height:1.5}
header{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:8px 0;z-index:1}
.grid{display:flex;flex-wrap:wrap;gap:8px}
figure{margin:0;width:${PREVIEW_EDGE + 12}px;border:1px solid var(--line);border-radius:6px;padding:6px;font-size:12px}
figure.keeper{background:var(--keeper)}
figure.done{background:var(--pick)}
img,.noimg{width:${PREVIEW_EDGE}px;height:${PREVIEW_EDGE}px;object-fit:contain;display:block;background:#8884}
.noimg{display:flex;align-items:center;justify-content:center;color:var(--muted)}
code{word-break:break-all;color:var(--muted)}
.ans label{margin-right:8px;white-space:nowrap}
section{margin:12px 0;padding-bottom:12px;border-bottom:1px dashed var(--line)}
table{border-collapse:collapse}td,th{border:1px solid var(--line);padding:2px 8px;text-align:right}
</style></head><body>
<header><b>見た目の照合レポート（${escapeHtml(lib)}・${escapeHtml(PARAMS.alg)}/${escapeHtml(PARAMS.version)}）</b>
 ラベル済み <span id="done">0</span> / <span id="total">${pairs.length}</span>
 <button id="export" type="button">Export labels.json</button></header>
<p>各組を「同じ絵」「差分」（描き足し・別の版）「別物」から選ぶ。答えはこのブラウザに残る。終わったら Export labels.json を押し、
<code>node tools/similar-signatures.mjs --score labels.json</code> に渡す。このファイルは共有・commit しない。</p>
<table><tr><th></th><th>束</th><th>件</th><th>空けられる量</th></tr>
<tr><th>重複</th><td>${t.dup.groups}</td><td>${t.dup.items}</td><td>${escapeHtml(mb(t.dup.reclaimable))}</td></tr>
<tr><th>似ている</th><td>${t.similar.groups}</td><td>${t.similar.items}</td><td>${escapeHtml(mb(t.similar.reclaimable))}</td></tr></table>
<p>画像 ${stats.images} 枚・照合済み ${stats.signed.total} 枚・単色 ${stats.flat} 枚・読めなかった ${stats.decodeFailures} 枚</p>
${body}
<script type="application/json" id="pairs">${pairsJson}</script>
<script>
(() => {
  const LIB = ${libJson};
  const pairs = JSON.parse(document.getElementById("pairs").textContent);
  const STORE = "r2g-similar-labels:v1:" + LIB;
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(STORE) || "{}") || {}; } catch { saved = {}; }
  const idOf = (p) => p.keeper + "\\n" + p.key;
  const sync = (pid, v) => document.querySelectorAll('[data-pair="' + pid + '"]').forEach((f) => {
    f.classList.add("done");
    const i = f.querySelector('input[value="' + v + '"]');
    if (i) i.checked = true;
  });
  const count = () => {
    document.getElementById("done").textContent =
      String(Object.values(pairs).filter((p) => saved[idOf(p)]).length);
  };
  for (const [pid, p] of Object.entries(pairs)) if (saved[idOf(p)]) sync(pid, saved[idOf(p)]);
  count();
  document.addEventListener("change", (e) => {
    const t = e.target;
    if (!(t instanceof HTMLInputElement) || t.type !== "radio") return;
    const f = t.closest("[data-pair]");
    if (!f) return;
    const pid = f.dataset.pair;
    saved[idOf(pairs[pid])] = t.value;
    try { localStorage.setItem(STORE, JSON.stringify(saved)); } catch {}
    sync(pid, t.value);
    count();
  });
  document.getElementById("export").addEventListener("click", () => {
    const labels = Object.values(pairs)
      .filter((p) => saved[idOf(p)])
      .map((p) => ({ ...p, answer: saved[idOf(p)] }));
    const blob = new Blob([JSON.stringify({ version: 1, alg: ${JSON.stringify(PARAMS.alg)}, params: ${JSON.stringify(PARAMS.version)}, lib: LIB, labels }, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "labels.json";
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  });
})();
</script>
</body></html>
`;
}

// ---------------------------------------------------------------- --score

/** 「ほぼ同じ」がこの適合率に届かなければ、マージ前にしきい値を締める（仕様の出荷条件） */
export const SAME_PRECISION_GATE = 0.98;

/**
 * ラベルから判定ごとの適合率を出す。ほぼ同じ・同じファイル・反転は「同じ絵」だけを正解とし、
 * 差分かもの印が無いのに差分だった物は誤りに数える。差分かもは「差分」の割合、似ているは「別物でない」割合。
 */
export function scoreLabels(doc) {
  const list = Array.isArray(doc) ? doc : (doc?.labels ?? []);
  const seen = new Set();
  const cats = {};
  for (const l of list) {
    if (!l || !["same", "diff", "other"].includes(l.answer)) continue;
    const id = `${l.keeper}\n${l.key}`;
    if (seen.has(id)) continue;
    seen.add(id);
    const cat = l.match === "same" && l.variant ? "variant" : l.match;
    const c = (cats[cat] ??= { n: 0, same: 0, diff: 0, other: 0 });
    c.n++;
    c[l.answer]++;
  }
  for (const [cat, c] of Object.entries(cats)) {
    const good = cat === "similar" ? c.same + c.diff : cat === "variant" ? c.diff : c.same;
    c.precision = c.n ? good / c.n : null;
  }
  const same = cats.same;
  const gate =
    same && same.n
      ? { label: "same", precision: same.precision, pass: same.precision >= SAME_PRECISION_GATE }
      : { label: "same", precision: null, pass: null };
  return { categories: cats, gate };
}

// ---------------------------------------------------------------- --check-expected

const outcomeOf = (it) =>
  it.match === "same" && it.variant ? "variant" : it.match === "keeper" ? "keeper" : it.match;

export async function listServerGroups(api, lib) {
  const groups = [];
  for (const tab of ["dup", "similar"]) {
    let cursor = "";
    for (;;) {
      const q = `tab=${tab}&limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
      const d = await api.get(`${libPath(lib)}/similar?${q}`);
      for (const g of d.groups ?? []) groups.push({ ...g, tier: g.tier ?? tab });
      if (!d.cursor) break;
      cursor = d.cursor;
    }
  }
  return groups;
}

/** 期待ファイルとサーバーの束を突き合わせ、外れた物の説明を返す（空なら合格） */
export function checkExpected(expected, groups, status) {
  const problems = [];
  if (!status || status.pending !== 0)
    problems.push(`status.pending が 0 でない (${status?.pending})`);
  if (Number.isInteger(expected.flatAtLeast) && !(status?.flat >= expected.flatAtLeast))
    problems.push(`status.flat ${status?.flat} < ${expected.flatAtLeast}`);
  const truncated = groups.filter((g) => (g.more ?? 0) > 0).length;
  for (const c of expected.checks ?? []) {
    const scope = c.with ? groups.filter((g) => g.items.some((it) => it.key === c.with)) : groups;
    const found = new Set();
    for (const g of scope) for (const it of g.items) if (it.key === c.key) found.add(outcomeOf(it));
    const got = found.size ? [...found] : ["none"];
    if (!got.some((o) => c.expect.includes(o)))
      problems.push(
        `${c.key}${c.with ? ` (with ${c.with})` : ""}: 期待 ${c.expect.join("|")} / 実際 ${got.join("|")}`,
      );
  }
  if (problems.length && truncated)
    problems.push(`(${truncated} 個の束は 60 件で切られていて、more に残りがある)`);
  return problems;
}

// ---------------------------------------------------------------- 実行

function outDirOf(root, lib) {
  // lib は道筋に入るので、.work/similar-report/ の外へ出る名前を受けない
  if (!/^[A-Za-z0-9_-]+$/.test(lib ?? "")) throw new Error("--lib は英数字・_・- だけの名前で渡す");
  return join(root, ".work", "similar-report", lib);
}

async function runReport(api, args, ctx) {
  const t0 = performance.now();
  const lib = args.lib;
  const outDir = outDirOf(ctx.root, lib);
  const includeOriginals = !!args["include-originals"];
  const probe = !!args["probe-dims"];

  ctx.log("一覧を読んでいる…");
  const all = await listLibraryItems(api, lib);
  const images = all.filter((i) => IMAGE_RE.test(i.key));
  const exact = await listExactGroups(api, lib);
  ctx.log(`画像 ${images.length} 枚・SHA-256 の束 ${exact.groups.length} 組`);

  const metas = new Map();
  const itemOf = new Map();
  for (const i of all) {
    itemOf.set(i.key, i);
    metas.set(i.key, {
      key: i.key,
      size: Number(i.size) || 0,
      uploaded: Number(i.createdAt) || 0,
      ow: 0,
      oh: 0,
      ext: extOf(i.key),
    });
  }
  const exactGroups = exact.groups.map((g) => {
    for (const it of g.items ?? []) {
      if (!metas.has(it.key))
        metas.set(it.key, {
          key: it.key,
          size: Number(it.size ?? g.size) || 0,
          uploaded: Number(it.createdAt) || 0,
          ow: 0,
          oh: 0,
          ext: extOf(it.key),
        });
    }
    return { keys: (g.items ?? []).map((it) => it.key) };
  });

  const counts = {
    fromThumb: 0,
    fromOriginal: 0,
    flat: 0,
    decodeFailures: 0,
    tooLarge: 0,
    skippedNoThumb: 0,
    networkErrors: 0,
  };
  const sigs = new Map();
  const original = limiter(ORIGINAL_PARALLEL);
  let done = 0;
  await pool(images, REPORT_PARALLEL, async (it) => {
    try {
      let sig;
      if (it.thumbStored && it.thumbUrl) {
        sig = await signatureOf(await api.bytes(it.thumbUrl, { max: MAX_THUMB_BYTES }));
        counts.fromThumb++;
      } else if (includeOriginals) {
        if ((Number(it.size) || 0) > MAX_SOURCE_BYTES) throw new TooLargeError("size");
        sig = await original(async () =>
          signatureFromOriginal(await api.bytes(it.url, { max: MAX_SOURCE_BYTES })),
        );
        counts.fromOriginal++;
      } else {
        counts.skippedNoThumb++;
        return;
      }
      if (sigInfo(sig).flags & FLAG_FLAT) counts.flat++;
      sigs.set(it.key, sig);
    } catch (e) {
      if (e instanceof DecodeError) counts.decodeFailures++;
      else if (e instanceof TooLargeError) counts.tooLarge++;
      else counts.networkErrors++;
    } finally {
      if (++done % 500 === 0) ctx.log(`照合 ${done} / ${images.length}`);
    }
  });

  const probeStats = { known: 0, unknown: 0, failed: 0 };
  if (probe) {
    // 束に入り得る画像だけ寸法を読む（署名のある物と、SHA-256 の束の一員）
    const wanted = new Set([...sigs.keys(), ...exactGroups.flatMap((g) => g.keys)]);
    const targets = images.filter((i) => wanted.has(i.key));
    await pool(targets, REPORT_PARALLEL, async (it) => {
      try {
        // Range を無視して全体を返す相手でも、読むのは先頭 64 KB だけにする
        const bytes = await api.bytes(it.url, { range: `bytes=0-${PROBE_BYTES - 1}` });
        const d = probeDims(new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.length));
        const m = metas.get(it.key);
        m.ow = d.w;
        m.oh = d.h;
        if (d.w > 0 && d.h > 0) probeStats.known++;
        else probeStats.unknown++;
      } catch {
        probeStats.failed++;
      }
    });
  }

  const { nodes, table } = buildNodes({ metas, sigs, exactGroups });
  const g0 = performance.now();
  const { groups, crowded } = groupNodes(nodes, table);
  const groupingMs = Math.round(performance.now() - g0);
  const summary = summarize(groups, exactGroups);

  const samples = pickSamples(groups, Number(args.seed ?? 1) || 1);
  const previews = await makePreviews(api, lib, sampleKeys(samples), itemOf, ctx);

  const stats = {
    version: 1,
    alg: PARAMS.alg,
    params: PARAMS.version,
    lib,
    generatedAt: new Date().toISOString(),
    options: { includeOriginals, probeDims: probe },
    images: images.length,
    videos: all.filter((i) => i.type === "video").length,
    thumbnails: {
      stored: images.filter((i) => i.thumbStored).length,
      coverage: images.length ? images.filter((i) => i.thumbStored).length / images.length : 0,
    },
    signed: {
      total: sigs.size,
      fromThumb: counts.fromThumb,
      fromOriginal: counts.fromOriginal,
      share: images.length ? sigs.size / images.length : 0,
    },
    flat: counts.flat,
    decodeFailures: counts.decodeFailures,
    tooLarge: counts.tooLarge,
    skippedNoThumb: counts.skippedNoThumb,
    networkErrors: counts.networkErrors,
    exact: { groups: exact.groups.length, hashPending: exact.pending, hashSkipped: exact.skipped },
    nodes: nodes.length,
    tiers: summary.tiers,
    shaParity: summary.shaParity,
    histograms: summary.histograms,
    crowded,
    probe: probe ? probeStats : null,
    bytesDownloaded: api.stats.bytes,
    groupingMs,
    runtimeMs: Math.round(performance.now() - t0),
  };
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, "stats.json"), JSON.stringify(stats, null, 2));
  writeFileSync(join(outDir, "report.html"), reportHtml({ lib, stats, samples, previews }));
  const t = stats.tiers;
  ctx.log(
    `重複 ${t.dup.groups} 組 ${t.dup.items} 件 ${mb(t.dup.reclaimable)} / 似ている ${t.similar.groups} 組 ${t.similar.items} 件 / ` +
      `SHA 一致 ${summary.shaParity.together}/${summary.shaParity.groups} / 束ね ${groupingMs} ms`,
  );
  ctx.log(`出力: ${join(".work", "similar-report", lib)}/stats.json, report.html（共有しない）`);
  return 0;
}

/** 見本の縮小画像を作る。長い実行で署名付き URL が切れていたら、一覧を読み直して 1 回だけ取り直す */
async function makePreviews(api, lib, keys, itemOf, ctx) {
  const previews = new Map();
  const one = async (it) => {
    const src = it.thumbStored && it.thumbUrl ? it.thumbUrl : it.url;
    const bytes = await api.bytes(src, {
      max: it.thumbStored ? MAX_THUMB_BYTES : MAX_SOURCE_BYTES,
    });
    const small = await sharp(bytes, { failOn: "error" })
      .rotate()
      .resize(PREVIEW_EDGE, PREVIEW_EDGE, { fit: "inside" })
      .webp({ quality: 70 })
      .toBuffer();
    previews.set(it.key, `data:image/webp;base64,${small.toString("base64")}`);
  };
  const failed = [];
  await pool([...keys], REPORT_PARALLEL, async (key) => {
    const it = itemOf.get(key);
    if (!it || !IMAGE_RE.test(key)) return;
    try {
      await one(it);
    } catch (e) {
      if (e instanceof ApiError) failed.push(key);
    }
  });
  if (failed.length) {
    ctx.log(`見本 ${failed.length} 件を取り直す（URL の期限切れに備えて一覧を読み直す）`);
    const fresh = new Map((await listLibraryItems(api, lib)).map((i) => [i.key, i]));
    await pool(failed, REPORT_PARALLEL, async (key) => {
      const it = fresh.get(key);
      if (it) await one(it).catch(() => {});
    });
  }
  return previews;
}

async function signTodo(api, it) {
  if (it.thumbStored && it.thumbUrl) {
    return {
      src: "t",
      sig: await signatureOf(await api.bytes(it.thumbUrl, { max: MAX_THUMB_BYTES })),
    };
  }
  if ((Number(it.size) || 0) > MAX_SOURCE_BYTES) throw new TooLargeError("size");
  return {
    src: "o",
    sig: await signatureFromOriginal(await api.bytes(it.url, { max: MAX_SOURCE_BYTES })),
  };
}

async function runWrite(api, args, ctx) {
  const lib = args.lib;
  const before = await api.get(`${libPath(lib)}/similar/status`);
  if (before.alg !== PARAMS.alg) {
    ctx.warn(`error: サーバーの alg が ${before.alg}。ツールを更新する`);
    return 1;
  }
  ctx.log(
    `未照合 ${before.pending} 件（サムネあり ${before.pendingWithThumb}・なし ${before.pendingNoThumb}）`,
  );
  const totals = { stored: 0, stale: 0, failRecorded: 0, networkErrors: 0, posted: 0 };
  let buffer = [];
  // POST は常に 1 本だけ流す。並べると同じシャードの書き込みが競って Worker 側の再試行が増える
  let posting = Promise.resolve();
  const flush = (all) =>
    (posting = posting.then(async () => {
      while (buffer.length >= (all ? 1 : POST_BATCH)) {
        const batch = buffer.slice(0, POST_BATCH);
        buffer = buffer.slice(batch.length);
        const r = await api.post(`${libPath(lib)}/similar/signatures`, {
          alg: PARAMS.alg,
          items: batch,
        });
        totals.posted += batch.length;
        totals.stored += r.stored ?? 0;
        totals.stale += r.stale ?? 0;
        totals.failRecorded += r.failRecorded ?? 0;
      }
    }));
  const original = limiter(ORIGINAL_PARALLEL);
  try {
    for (let shard = 0; shard < SHARDS; shard++) {
      let after = "";
      const postedBefore = totals.posted;
      for (;;) {
        const q = `shard=${shard}&limit=${TODO_LIMIT}${after ? `&after=${encodeURIComponent(after)}` : ""}`;
        const page = await api.get(`${libPath(lib)}/similar/todo?${q}`);
        const items = page.items ?? [];
        await pool(items, WRITE_PARALLEL, async (it) => {
          let row;
          try {
            const r = it.thumbStored
              ? await signTodo(api, it)
              : await original(() => signTodo(api, it));
            row = { key: it.key, etag: it.etag, src: r.src, sig: encodeSig(r.sig) };
          } catch (e) {
            // 通信の失敗は記録しない（次の実行で取り直す）。読めない・大きすぎるは印を残して繰り返さない
            if (e instanceof DecodeError)
              row = { key: it.key, etag: it.etag, src: it.thumbStored ? "t" : "o", fail: "decode" };
            else if (e instanceof TooLargeError)
              row = { key: it.key, etag: it.etag, src: "o", fail: "too_large" };
            else {
              totals.networkErrors++;
              return;
            }
          }
          buffer.push(row);
          if (buffer.length >= POST_BATCH) await flush(false);
        });
        await flush(true);
        if (!page.next || !items.length) break;
        after = page.next;
      }
      if (totals.posted !== postedBefore)
        ctx.log(`シャード ${shard + 1}/${SHARDS}: ここまでの送信 ${totals.posted} 件`);
    }
  } catch (e) {
    if (e instanceof ApiError && e.status === 409 && e.code === "alg_mismatch") {
      ctx.warn("error: alg_mismatch（サーバーの署名の版が違う）。ツールを更新する");
      return 1;
    }
    throw e;
  }
  const after = await api.get(`${libPath(lib)}/similar/status`);
  ctx.log(
    `保存 ${totals.stored}・古い ${totals.stale}・失敗印 ${totals.failRecorded}・通信失敗 ${totals.networkErrors} / 残り ${after.pending} 件`,
  );
  return totals.networkErrors ? 2 : 0;
}

async function runCheck(api, args, ctx) {
  const expected = JSON.parse(readFileSync(args["check-expected"], "utf8"));
  if (expected.version !== 1) {
    ctx.warn("error: 期待ファイルの version が 1 ではない");
    return 1;
  }
  const lib = args.lib ?? expected.lib;
  const [status, groups] = await Promise.all([
    api.get(`${libPath(lib)}/similar/status`),
    listServerGroups(api, lib),
  ]);
  const problems = checkExpected(expected, groups, status);
  for (const p of problems) ctx.warn(`NG ${p}`);
  ctx.log(
    problems.length
      ? `期待と違う ${problems.length} 件`
      : `期待どおり（${(expected.checks ?? []).length} 件・束 ${groups.length} 組）`,
  );
  return problems.length ? 1 : 0;
}

function runScore(args, ctx) {
  const r = scoreLabels(JSON.parse(readFileSync(args.score, "utf8")));
  const pct = (v) => (v === null || v === undefined ? "-" : `${(v * 100).toFixed(1)}%`);
  ctx.log("判定        件数  同じ絵  差分  別物  適合率");
  for (const cat of ["identical", "same", "variant", "mirror", "similar"]) {
    const c = r.categories[cat];
    if (!c) continue;
    ctx.log(
      `${cat.padEnd(10)} ${String(c.n).padStart(5)} ${String(c.same).padStart(7)} ${String(c.diff).padStart(5)} ${String(c.other).padStart(5)}  ${pct(c.precision)}`,
    );
  }
  ctx.log(
    "（ほぼ同じ・同じファイル・反転は同じ絵だけ、差分かもは差分、似ているは別物以外を正解に数える）",
  );
  if (r.gate.pass === null) ctx.log("ほぼ同じ: ラベルが無いので判定できない");
  else if (r.gate.pass) ctx.log(`ほぼ同じ ${pct(r.gate.precision)} ≥ 98%: 出荷条件を満たす`);
  else
    ctx.log(
      `ほぼ同じ ${pct(r.gate.precision)} < 98%: 出荷条件を満たさない。gMax≤8・ph≤3 に締めて採点し直す`,
    );
  return 0;
}

/**
 * CLI の本体。テストから環境・出力先・fetch を差し替えて呼べるようにしてある。
 * 戻り値は終了コード。
 */
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
  const ctx = { root, log, warn };
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      allowPositionals: true,
      options: {
        lib: { type: "string" },
        "include-originals": { type: "boolean", default: false },
        "probe-dims": { type: "boolean", default: false },
        seed: { type: "string" },
        score: { type: "string" },
        purge: { type: "boolean", default: false },
        "check-expected": { type: "string" },
      },
    });
  } catch (e) {
    warn(`error: ${e instanceof Error ? e.message : String(e)}`);
    return 1;
  }
  const { positionals, values: args } = parsed;
  const mode = positionals[0] ?? (args["check-expected"] ? "check" : "report");
  if (!["report", "write", "check"].includes(mode)) {
    warn("usage: similar-signatures.mjs [report|write] --lib <id> [options]");
    return 1;
  }
  try {
    if (args.purge) {
      const dir = outDirOf(root, args.lib);
      rmSync(dir, { recursive: true, force: true });
      log(`消した: ${join(".work", "similar-report", args.lib)}`);
      return 0;
    }
    if (args.score) return runScore(args, ctx);
    if (!args.lib && !(mode === "check" && args["check-expected"])) {
      warn("error: --lib <id> を渡す");
      return 1;
    }
    if (mode === "report") outDirOf(root, args.lib);
    const endpoint = String(env.R2G_ENDPOINT ?? "").trim();
    const token = String(env.R2G_TOKEN ?? "").trim();
    if (!endpoint || !token) {
      warn("error: R2G_ENDPOINT と R2G_TOKEN を環境変数で渡す");
      return 1;
    }
    const api = makeApi({ endpoint, token, fetchImpl });
    if (mode === "report") return await runReport(api, args, ctx);
    if (mode === "write") {
      const code = await runWrite(api, args, ctx);
      if (code === 1 || !args["check-expected"]) return code;
      return Math.max(code, await runCheck(api, args, ctx));
    }
    return await runCheck(api, args, ctx);
  } catch (e) {
    // 例外の文言は経路と状態だけ（makeApi がホスト・署名・トークンを入れない）
    warn(`error: ${e instanceof Error ? e.message : String(e)}`);
    return 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main(process.argv.slice(2));
}
