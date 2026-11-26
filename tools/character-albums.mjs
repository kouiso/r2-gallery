#!/usr/bin/env node
/**
 * R2 に追加されたキャラ画像を、見た目で既存アルバムへ仕分ける運用ツール（#31）。
 *
 *   plan    : 読み取り専用。参照アルバムと対象画像を落としてローカルで照合し、
 *             plan.json と preview.html（人物の切り出し・判定・CCIP の差・根拠）を出す。
 *   apply   : plan.json で approved: true にしたグループだけをアルバムへ関連付ける。
 *             原画像の移動・削除・上書きはしない。再実行しても二重登録しない。
 *   eval    : 読み取り専用。参照アルバム同士で 1 枚抜き（leave-one-out）の精度を測り、
 *             <out>/eval.json に precision / recall / 保留率・取り違え表・閾値の sweep を出す。
 *   analyze : 手元の画像ファイルだけで人物検出と CCIP を試す（Worker に繋がない）。
 *
 * 判定は既定で CCIP（--engine ccip）。モデルが使えない時は --engine color で従来の色の判定に戻せる。
 *
 * Usage:
 *   R2G_ENDPOINT=https://... R2G_TOKEN=... node tools/character-albums.mjs plan \
 *     --lib personal --ref-albums さくら,ダウナーお姉さん [--keys-file keys.txt | --recent 200] \
 *     [--ref-per-album 24] [--ignore-assigned] [--engine ccip|color] --out .work/character-albums
 *   --ignore-assigned は精度評価用。配属済みも照合し、出した plan は apply できない。
 *   R2G_ENDPOINT=... R2G_TOKEN=... node tools/character-albums.mjs eval \
 *     --lib personal --ref-albums さくら,ひなた,ダウナーお姉さん [--ref-per-album 24] [--max-per-album 100]
 *   R2G_ENDPOINT=... R2G_TOKEN=... node tools/character-albums.mjs apply \
 *     --plan .work/character-albums/plan.json [--dry-run]
 *   node tools/character-albums.mjs analyze a.png b.webp
 *
 * CCIP の共通オプション: --model-dir（既定 R2G_MODEL_DIR か ~/.cache/r2g-models）, --threads N,
 *   --offline（モデルを取りに行かない）, --image-source thumb|original, --threshold, --margin
 *
 * 画像は外部 AI に送らない。トークンや署名 URL はログに出さない。
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import sharp from "sharp";
import { DEFAULT_PARAMS, applyPlan, buildPlan, describe } from "./character-albums-core.mjs";
import {
  buildCcipPlan,
  ccipMerge,
  decideImage,
  evalMetrics,
  refId,
  sampleStable,
  scoreImage,
  sweep,
} from "./character-albums-ccip-core.mjs";

const IMAGE_RE = /\.(jpe?g|png|webp|gif|avif)$/i;
// worker が「その他」として出す仮想アルバム。どのアルバムにも入っていない画像を
// 集めた物なので、配属済みの判定材料にも照合先にも使わない
const OTHER_ALBUM_ID = "__other__";

const { positionals, values: args } = parseArgs({
  allowPositionals: true,
  options: {
    lib: { type: "string", default: "personal" },
    "ref-albums": { type: "string" },
    "ref-per-album": { type: "string", default: "24" },
    "max-per-album": { type: "string", default: "100" },
    "keys-file": { type: "string" },
    recent: { type: "string" },
    out: { type: "string", default: ".work/character-albums" },
    plan: { type: "string" },
    "dry-run": { type: "boolean", default: false },
    "ignore-assigned": { type: "boolean", default: false },
    engine: { type: "string", default: "ccip" },
    "model-dir": { type: "string" },
    threads: { type: "string" },
    offline: { type: "boolean", default: false },
    "image-source": { type: "string", default: "thumb" },
    threshold: { type: "string" },
    margin: { type: "string" },
  },
});

function fail(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

const endpoint = (process.env.R2G_ENDPOINT ?? "").replace(/\/$/, "");
const token = process.env.R2G_TOKEN ?? "";
const needWorker = () => {
  if (!endpoint || !token) fail("R2G_ENDPOINT と R2G_TOKEN を環境変数で渡す");
};

async function request(path, init = {}) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(path.startsWith("http") ? path : endpoint + path, {
      ...init,
      headers: path.startsWith("http")
        ? {}
        : { authorization: `Bearer ${token}`, "content-type": "application/json", ...init.headers },
    });
    if (res.ok) return res;
    // 一覧の途中で Worker が 503 を返すことがあるので、少し待って取り直す。
    if ((res.status === 503 || res.status === 429) && attempt < 4) {
      await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
      continue;
    }
    throw new Error(
      `HTTP ${res.status} ${path.startsWith("http") ? "(thumb)" : path.split("?")[0]}`,
    );
  }
}
const getJson = async (path) => (await request(path)).json();

const api = {
  async listAlbums(lib) {
    return (await getJson(`/v1/${encodeURIComponent(lib)}/albums`)).albums;
  },
  async albumItems(lib, id) {
    const items = [];
    let cursor = "0";
    while (cursor !== null) {
      const d = await getJson(
        `/v1/${encodeURIComponent(lib)}/albums/${id}?limit=200&cursor=${cursor}`,
      );
      items.push(...d.items);
      cursor = d.cursor ?? null;
    }
    return items;
  },
  async createAlbum(lib, title) {
    const res = await request(`/v1/${encodeURIComponent(lib)}/albums`, {
      method: "POST",
      body: JSON.stringify({ title }),
    });
    return res.json();
  },
  async addItems(lib, id, keys) {
    const res = await request(`/v1/${encodeURIComponent(lib)}/albums/${id}/items`, {
      method: "POST",
      body: JSON.stringify({ keys }),
    });
    return res.json();
  },
  async recentKeys(lib, limit, match = () => true) {
    const items = [];
    let cursor = "";
    while (items.length < limit) {
      const q = `recursive=1&order=recent${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
      const d = await getJson(`/v1/${encodeURIComponent(lib)}/folders?${q}`);
      for (const i of d.items ?? []) if (match(i)) items.push(i);
      if (!d.cursor) break;
      cursor = d.cursor;
    }
    return items.slice(0, limit);
  },
  // 明示されたキーを一覧の末尾まで探す。recent の窓で切ると、古い指定キーが見つからず落ちる
  async findKeys(lib, wanted) {
    const found = [];
    const seen = new Set();
    let cursor = "";
    while (seen.size < wanted.size) {
      const q = `recursive=1&order=recent${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
      const d = await getJson(`/v1/${encodeURIComponent(lib)}/folders?${q}`);
      for (const i of d.items ?? []) {
        if (wanted.has(i.key) && !seen.has(i.key)) {
          seen.add(i.key);
          found.push(i);
        }
      }
      if (!d.cursor) break;
      cursor = d.cursor;
    }
    return found;
  },
};

function sample(list, n) {
  if (list.length <= n) return list;
  const step = list.length / n;
  return Array.from({ length: n }, (_, i) => list[Math.floor(i * step)]);
}

async function imageBytes(item) {
  // 原寸は細部が残るぶん CCIP に有利だが、1 枚数 MB になるので既定はサムネ（長辺 512px）
  const url =
    args["image-source"] === "original" ? (item.url ?? item.thumbUrl) : (item.thumbUrl ?? item.url);
  const u = url.startsWith("/") ? endpoint + url : url;
  return Buffer.from(await (await request(u)).arrayBuffer());
}

const escapeHtml = (s) =>
  String(s).replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c],
  );

async function dataUri(bytes) {
  const small = await sharp(bytes)
    .resize(160, 160, { fit: "cover" })
    .webp({ quality: 70 })
    .toBuffer();
  return `data:image/webp;base64,${small.toString("base64")}`;
}

function previewHtml(plan, thumbs, covers) {
  const card = (i) =>
    `<figure><img src="${thumbs.get(i.key) ?? ""}"><figcaption>${escapeHtml(i.confidence ?? "要確認")} ${i.score ?? ""}<br>${escapeHtml(i.rationale)}<br><code>${escapeHtml(i.key)}</code></figcaption></figure>`;
  const section = (g) =>
    `<section><h2>${escapeHtml(g.title)}（${g.action === "add" ? "既存アルバムへ追加" : "新規アルバム候補"}・${g.items.length}枚）</h2>${
      covers.get(g.albumId)
        ? `<p>代表: ${covers
            .get(g.albumId)
            .map((c) => `<img class="ref" src="${c}">`)
            .join("")}</p>`
        : ""
    }<div>${g.items.map(card).join("")}</div></section>`;
  return `<!doctype html><meta charset="utf-8"><title>キャラ別アルバム仕分けプレビュー</title>
<style>body{font-family:sans-serif;margin:16px}figure{display:inline-block;width:180px;vertical-align:top;margin:4px;font-size:11px}img{width:160px;height:160px;object-fit:cover}img.ref{width:64px;height:64px}code{word-break:break-all}</style>
<h1>キャラ別アルバム仕分けプレビュー（${escapeHtml(plan.lib)}）</h1>
<p>反映するグループは plan.json の approved を true にしてから apply する。ここに出ている画像はまだどのアルバムにも入っていない。</p>
${plan.groups.map(section).join("")}
<section><h2>未分類／要確認（${plan.unclassified.length}枚）</h2><div>${plan.unclassified.map(card).join("")}</div></section>
<p>既にアルバムに入っていて触らなかった画像: ${plan.skipped.length}枚</p>`;
}

const DECISION_LABEL = {
  match: "一致",
  review: "要確認",
  unmatched: "未マッチ",
  nochar: "キャラなし",
};

/** CCIP 用の preview。判定に使った人物の切り出しと、CCIP の差（小さいほど同キャラ）を並べる。 */
function previewHtmlCcip(plan, media, covers) {
  const card = (i) => {
    const m = media.get(i.key) ?? { thumb: "", crops: [] };
    const crops = (i.crops ?? [])
      .map(
        (c, n) =>
          `<span class="crop"><img src="${m.crops[n] ?? ""}"><br>${escapeHtml(DECISION_LABEL[c.decision] ?? c.decision)}${c.albumTitle ? ` ${escapeHtml(c.albumTitle)}` : ""}${c.score != null ? ` 差${c.score}` : ""}</span>`,
      )
      .join("");
    const second = i.second ? `<br>2位 ${escapeHtml(i.second.albumTitle)} 差${i.second.score}` : "";
    return `<figure class="${escapeHtml(i.decision)}"><img src="${m.thumb}"><figcaption><b>${escapeHtml(DECISION_LABEL[i.decision] ?? i.decision)}${i.confidence ? `（${escapeHtml(i.confidence)}）` : ""}</b> 人物 ${i.persons}${i.score != null ? `<br>CCIP の差 ${i.score}（代表 ${i.centroid ?? "-"}）` : ""}${second}<div>${crops}</div>${escapeHtml(i.rationale)}<br><code>${escapeHtml(i.key)}</code></figcaption></figure>`;
  };
  const section = (g) =>
    `<section><h2>${escapeHtml(g.title)}（${g.action === "add" ? "既存アルバムへ追加" : "新規アルバム候補"}・${g.items.length}枚）</h2>${
      covers.get(g.albumId)
        ? `<p>参照の切り出し: ${covers
            .get(g.albumId)
            .map((c) => `<img class="ref" src="${c}">`)
            .join("")}</p>`
        : ""
    }<div>${g.items.map(card).join("")}</div></section>`;
  const p = plan.params;
  return `<!doctype html><meta charset="utf-8"><title>キャラ別アルバム仕分けプレビュー</title>
<style>body{font-family:sans-serif;margin:16px}figure{display:inline-block;width:220px;vertical-align:top;margin:4px;font-size:11px;border:1px solid #ddd;padding:4px}figure>img{width:200px;height:200px;object-fit:contain;background:#f4f4f4}.crop{display:inline-block;width:64px;margin:2px;font-size:10px;vertical-align:top}.crop img{width:64px;height:64px;object-fit:contain;background:#fff;border:1px solid #ccc}img.ref{width:64px;height:64px;object-fit:contain}code{word-break:break-all}figure.review{border-color:#d90}figure.nochar{border-color:#999}</style>
<h1>キャラ別アルバム仕分けプレビュー（${escapeHtml(plan.lib)}・CCIP）</h1>
<p>反映するグループは plan.json の approved を true にしてから apply する。ここに出ている画像はまだどのアルバムにも入っていない。</p>
<p>CCIP の差は小さいほど同じキャラ。閾値 ${p.threshold.toFixed(4)} 以下で一致、${p.high.toFixed(4)} 以下かつ代表との差も閾値以下で high。1 位と 2 位の差が ${p.margin} 未満は要確認。人物の切り出しごとに判定し、複数人で揃わない画像は要確認に回す。</p>
${plan.groups.map(section).join("")}
<section><h2>未分類／要確認（${plan.unclassified.length}枚）</h2><div>${plan.unclassified.map(card).join("")}</div></section>
<section><h2>キャラなし（${plan.nochar.length}枚）</h2><p>人物が検出されなかった画像。CCIP はキャラのいない絵同士をほぼ同一とみなすため照合しない。人物がいるのにここへ来た画像は検出漏れ。</p><div>${plan.nochar.map(card).join("")}</div></section>
<p>既にアルバムに入っていて触らなかった画像: ${plan.skipped.length}枚</p>`;
}

function refTitlesArg() {
  const refTitles = (args["ref-albums"] ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (!refTitles.length) fail("--ref-albums に照合に使うアルバム名をカンマ区切りで渡す");
  return refTitles;
}

/** 全アルバムを読み、配属済みの集合と参照アルバムの画像一覧を返す。 */
async function loadAlbums(lib, refTitles) {
  const all = await api.listAlbums(lib);
  const assigned = new Set();
  const refAlbums = [];
  const membership = new Map();
  for (const a of all) {
    // 「その他」は未配属の集まり。ここを数えると未分類の画像が全部「配属済み」になってしまう
    if (a.id === OTHER_ALBUM_ID) continue;
    const items = await api.albumItems(lib, a.id);
    for (const it of items) assigned.add(`${it.lib ?? lib}:${it.key}`);
    if (!refTitles.includes(a.title)) continue;
    if (a.readOnly) {
      // 読み取り専用アルバムには追加できないので、照合先にも入れない。
      console.warn(`warn: 「${a.title}」は読み取り専用なので照合に使わない`);
      continue;
    }
    const images = items.filter((i) => IMAGE_RE.test(i.key));
    for (const it of images) {
      const id = `${it.lib ?? lib}:${it.key}`;
      membership.set(id, [...(membership.get(id) ?? []), a.id]);
    }
    refAlbums.push({ id: a.id, title: a.title, items: images });
  }
  const missing = refTitles.filter((t) => !refAlbums.some((r) => r.title === t));
  if (missing.length) fail(`書き込める参照アルバムが見つからない: ${missing.join(",")}`);
  return { assigned, refAlbums, membership };
}

async function targetItemsFor(lib) {
  const wanted = args["keys-file"]
    ? new Set(
        readFileSync(args["keys-file"], "utf8")
          .split(/\r?\n/)
          .map((s) => s.trim())
          .filter(Boolean),
      )
    : null;
  let targetItems;
  if (wanted) {
    // 指定されたキーは一覧の末尾まで探す。recent の窓で切ると古いキーが黙って落ちる
    targetItems = await api.findKeys(lib, wanted);
    const notFound = [...wanted].filter((k) => !targetItems.some((i) => i.key === k));
    if (notFound.length) console.warn(`warn: 一覧に見つからないキー ${notFound.length} 件は対象外`);
  } else {
    // recent は画像だけ数える。動画で枠が埋まると指定より少ない枚数しか照合しない
    targetItems = await api.recentKeys(lib, Number(args.recent ?? 200), (i) =>
      IMAGE_RE.test(i.key),
    );
  }
  return targetItems.filter((i) => IMAGE_RE.test(i.key));
}

async function runPlanColor() {
  const lib = args.lib;
  const refTitles = refTitlesArg();
  const perAlbum = Number(args["ref-per-album"]);
  const { assigned, refAlbums } = await loadAlbums(lib, refTitles);
  const refs = [];
  const covers = new Map();
  for (const a of refAlbums) {
    const descs = [];
    const coverUris = [];
    for (const it of sample(a.items, perAlbum)) {
      const bytes = await imageBytes(it);
      descs.push({ key: it.key, lib: it.lib ?? lib, ...(await describe(bytes)) });
      if (coverUris.length < 6) coverUris.push(await dataUri(bytes));
    }
    refs.push({ id: a.id, title: a.title, refs: descs });
    covers.set(a.id, coverUris);
  }
  const targetItems = await targetItemsFor(lib);
  const targets = [];
  const thumbs = new Map();
  for (const it of targetItems) {
    const bytes = await imageBytes(it);
    targets.push({ key: it.key, desc: await describe(bytes) });
    thumbs.set(it.key, await dataUri(bytes));
  }
  const evaluation = args["ignore-assigned"];
  const plan = buildPlan({
    lib,
    targets,
    albums: refs,
    assigned: evaluation ? new Set() : assigned,
    params: DEFAULT_PARAMS,
  });
  plan.engine = "color";
  if (evaluation) plan.evaluation = true;
  writePlan(plan, previewHtml(plan, thumbs, covers), targets.length);
}

function writePlan(plan, html, count) {
  mkdirSync(args.out, { recursive: true });
  writeFileSync(join(args.out, "plan.json"), JSON.stringify(plan, null, 2));
  writeFileSync(join(args.out, "preview.html"), html);
  const summary = plan.groups.map((g) => `${g.title}=${g.items.length}`).join(" ");
  console.log(
    `対象 ${count} 枚 / 配属済み ${plan.skipped.length} / 候補 ${summary || "なし"} / 未分類 ${plan.unclassified.length}${plan.nochar ? ` / キャラなし ${plan.nochar.length}` : ""}`,
  );
  console.log(`plan: ${join(args.out, "plan.json")}  preview: ${join(args.out, "preview.html")}`);
}

async function openEngine() {
  const { openCcip, defaultModelDir } = await import("./character-albums-ccip.mjs");
  const num = (v) => (v === undefined ? undefined : Number(v));
  return openCcip({
    modelDir: args["model-dir"] ?? defaultModelDir(),
    threads: args.threads,
    offline: args.offline,
    log: (m) => console.log(m),
    overrides: { threshold: num(args.threshold), margin: num(args.margin) },
  });
}

/** 画像を落とす間に前の画像を推論できるよう、少し先まで取りに行く。 */
async function* prefetch(items, ahead = 4) {
  const queue = [];
  let i = 0;
  const pull = () => {
    const it = items[i++];
    const p = imageBytes(it).then(
      (bytes) => ({ it, bytes }),
      (error) => ({ it, error }),
    );
    // 待つ前に失敗しても未処理の reject にしない（順番が来た時に error として受け取る）
    queue.push(p);
  };
  while (i < items.length && queue.length < ahead) pull();
  while (queue.length) {
    const next = await queue.shift();
    if (i < items.length) pull();
    yield next;
  }
}

const timingsLog = [];

async function analyzeItems(engine, items, onEach) {
  for await (const { it, bytes, error } of prefetch(items)) {
    if (error) {
      console.warn(`warn: ${it.key} を取れない（${error.message}）`);
      continue;
    }
    let a;
    try {
      a = await engine.analyze(bytes);
    } catch (e) {
      console.warn(`warn: ${it.key} を読めない（${e.message}）`);
      continue;
    }
    timingsLog.push(a.timings);
    if ((await onEach(it, a)) === false) break;
  }
}

/**
 * 参照アルバムの輪郭を作る。人物が 1 人だけの画像の切り出しを、ハッシュ順に最大 perAlbum 枚。
 * 複数人の画像はどの切り出しがアルバムのキャラか分からないので参照に使わない。
 */
async function buildProfiles(engine, lib, refAlbums, perAlbum, cache = new Map()) {
  const profiles = [];
  const covers = new Map();
  for (const a of refAlbums) {
    const ordered = sampleStable(a.items, a.items.length);
    const refs = [];
    const coverUris = [];
    // 複数人やキャラなしが多いアルバムで延々と落とさないよう、試す枚数に上限を置く
    const candidates = ordered.slice(0, perAlbum * 3);
    const take = async (it, an) => {
      if (an.persons.length !== 1) return true;
      refs.push({ key: it.key, lib: it.lib ?? lib, feat: an.persons[0].feat });
      // eval で使い回す推論結果は画素を落としてあるので、代表の切り出しは作らない
      if (coverUris.length < 6 && an.rgb) {
        const { cropDataUri } = await import("./character-albums-ccip.mjs");
        coverUris.push(await cropDataUri(an, an.persons[0].crop, 96));
      }
      return refs.length < perAlbum;
    };
    const uncached = [];
    for (const it of candidates) {
      if (refs.length >= perAlbum) break;
      const hit = cache.get(`${it.lib ?? lib}:${it.key}`);
      if (hit) {
        if ((await take(it, hit)) === false) break;
      } else uncached.push(it);
    }
    if (refs.length < perAlbum) {
      await analyzeItems(engine, uncached, async (it, an) => {
        cache.set(`${it.lib ?? lib}:${it.key}`, stripRgb(an));
        return take(it, an);
      });
    }
    if (!refs.length) fail(`「${a.title}」に人物が 1 人だけ写った画像が見つからず、照合に使えない`);
    // アルバム自体が小さいだけなら警告しない。1 人の画像が足りず参照が痩せた時だけ知らせる
    if (refs.length < Math.min(perAlbum, a.items.length)) {
      console.warn(`warn: 「${a.title}」の参照は ${refs.length} 枚（1 人だけ写った画像が少ない）`);
    }
    profiles.push({ id: a.id, title: a.title, refs, centroid: ccipMerge(refs.map((r) => r.feat)) });
    covers.set(a.id, coverUris);
  }
  return { profiles, covers };
}

// 画素は preview を作ったら要らない。評価で数百枚を抱えるとメモリを食うので落とす
const stripRgb = ({ rgb: _rgb, ...rest }) => rest;

function timingSummary() {
  const n = timingsLog.length;
  if (!n) return null;
  const avg = (k) => Math.round((timingsLog.reduce((s, t) => s + t[k], 0) / n) * 10) / 10;
  return {
    images: n,
    msPerImage: {
      decode: avg("decode"),
      detect: avg("detect"),
      embed: avg("embed"),
      total: avg("total"),
    },
  };
}

async function runPlanCcip() {
  const lib = args.lib;
  const refTitles = refTitlesArg();
  const perAlbum = Number(args["ref-per-album"]);
  const engine = await openEngine();
  const { cropDataUri } = await import("./character-albums-ccip.mjs");
  const { assigned, refAlbums } = await loadAlbums(lib, refTitles);
  const { profiles, covers } = await buildProfiles(engine, lib, refAlbums, perAlbum);
  const evaluation = args["ignore-assigned"];
  const effectiveAssigned = evaluation ? new Set() : assigned;
  const targetItems = await targetItemsFor(lib);
  // 配属済みは plan で触らないので、推論の前に外して時間を使わない
  const todo = targetItems.filter((it) => !effectiveAssigned.has(`${lib}:${it.key}`));
  const targets = targetItems
    .filter((it) => effectiveAssigned.has(`${lib}:${it.key}`))
    .map((it) => ({ key: it.key, result: { decision: "skipped" } }));
  const media = new Map();
  await analyzeItems(engine, todo, async (it, an) => {
    const crops = await scoreImage({
      persons: an.persons,
      albums: profiles,
      // --ignore-assigned で参照に入っている画像を照合する時、自分自身とは比べない
      selfId: `${it.lib ?? lib}:${it.key}`,
      differences: engine.differences,
      topK: engine.params.topK,
    });
    const result = decideImage(crops, engine.params);
    media.set(it.key, {
      thumb: await cropDataUri(an, { left: 0, top: 0, width: an.width, height: an.height }, 200),
      crops: await Promise.all(an.persons.map((p) => cropDataUri(an, p.crop, 64))),
    });
    targets.push({
      key: it.key,
      result,
      persons: an.persons.map(({ box, crop, feat }) => ({ box, crop, feat })),
    });
  });
  const plan = await buildCcipPlan({
    lib,
    targets,
    assigned: effectiveAssigned,
    params: engine.params,
    differences: engine.differences,
  });
  plan.model = engine.info;
  plan.timing = timingSummary();
  if (evaluation) plan.evaluation = true;
  writePlan(plan, previewHtmlCcip(plan, media, covers), targetItems.length);
  if (plan.timing) console.log(`CPU 時間 ${JSON.stringify(plan.timing.msPerImage)} ms/枚`);
}

const SWEEP_THRESHOLDS = [0.1, 0.12, 0.14, 0.16, 0.18, 0.2, 0.22, 0.25];
const SWEEP_MARGINS = [0, 0.01, 0.02, 0.03, 0.05, 0.08];

async function runEval() {
  if (args.engine !== "ccip") fail("eval は --engine ccip だけ");
  const lib = args.lib;
  const refTitles = refTitlesArg();
  if (refTitles.length < 2) fail("eval には参照アルバムが 2 つ以上いる（取り違えを測るため）");
  const perAlbum = Number(args["ref-per-album"]);
  const maxPerAlbum = Number(args["max-per-album"]);
  const engine = await openEngine();
  const { refAlbums, membership } = await loadAlbums(lib, refTitles);
  const cache = new Map();
  const evalSets = new Map();
  // 評価する画像（アルバムごとにハッシュ順の先頭 maxPerAlbum 枚）を先に推論しておき、
  // 参照選びでも同じ推論を使い回す。参照はその先頭部分に入るので二度推論しない
  for (const a of refAlbums) {
    const evalSet = sampleStable(a.items, maxPerAlbum);
    evalSets.set(a.id, evalSet);
    let done = 0;
    await analyzeItems(engine, evalSet, async (it, an) => {
      cache.set(`${it.lib ?? lib}:${it.key}`, stripRgb(an));
      done++;
      if (done % 20 === 0) console.log(`  ${a.title}: ${done}/${evalSet.length}`);
    });
  }
  const { profiles } = await buildProfiles(engine, lib, refAlbums, perAlbum, cache);
  const records = [];
  const samples = [];
  for (const a of refAlbums) {
    for (const it of evalSets.get(a.id)) {
      const id = `${it.lib ?? lib}:${it.key}`;
      const an = cache.get(id);
      if (!an) continue;
      const crops = await scoreImage({
        persons: an.persons,
        albums: profiles,
        selfId: id,
        differences: engine.differences,
        topK: engine.params.topK,
      });
      const truths = (membership.get(id) ?? [a.id]).filter((x) => profiles.some((p) => p.id === x));
      const r = decideImage(crops, engine.params);
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
      });
      samples.push({ truth: a.id, truths, crops });
    }
  }
  const albums = profiles.map((p) => ({ id: p.id, title: p.title }));
  const metrics = evalMetrics(records, albums);
  const table = sweep(samples, albums, engine.params, {
    thresholds: [...new Set([...SWEEP_THRESHOLDS, engine.params.threshold])].sort((x, y) => x - y),
    margins: SWEEP_MARGINS,
  });
  const result = {
    version: 1,
    engine: "ccip",
    lib,
    createdAt: new Date().toISOString(),
    model: engine.info,
    params: engine.params,
    sampling: {
      method: "sha1(key) 順の先頭（leave-one-out: 対象自身は参照と代表から外す）",
      refPerAlbum: perAlbum,
      maxPerAlbum,
      albums: refAlbums.map((a) => ({
        id: a.id,
        title: a.title,
        images: a.items.length,
        evaluated: evalSets.get(a.id).length,
        refs: profiles.find((p) => p.id === a.id).refs.length,
      })),
    },
    timing: timingSummary(),
    metrics,
    sweep: table,
    records,
  };
  mkdirSync(args.out, { recursive: true });
  const path = join(args.out, "eval.json");
  writeFileSync(path, JSON.stringify(result, null, 2));
  printEval(result);
  console.log(`eval: ${path}`);
}

const pct = (x) => (x == null ? "  -  " : `${(x * 100).toFixed(1).padStart(5)}%`);

function printEval(r) {
  console.log(
    `\n参照 ${r.sampling.refPerAlbum} 枚/アルバム、評価 最大 ${r.sampling.maxPerAlbum} 枚/アルバム`,
  );
  console.log("アルバム              画像   評価  参照  precision  recall  保留    誤り");
  for (const row of r.metrics.perAlbum) {
    const s = r.sampling.albums.find((a) => a.id === row.albumId);
    console.log(
      `${row.title.padEnd(18)} ${String(s.images).padStart(6)} ${String(row.n).padStart(6)} ${String(s.refs).padStart(5)}  ${pct(row.precision)}   ${pct(row.recall)} ${pct(row.abstainRate)} ${pct(row.errorRate)}`,
    );
  }
  const { micro, macro } = r.metrics;
  console.log(
    `全体(枚数で平均)  precision ${pct(micro.precision)} recall ${pct(micro.recall)} 保留 ${pct(micro.abstainRate)} 誤り ${pct(micro.errorRate)}`,
  );
  console.log(
    `アルバム平均      precision ${pct(macro.precision)} recall ${pct(macro.recall)} 保留 ${pct(macro.abstainRate)}`,
  );
  console.log("\n取り違え表（行 = 正解、列 = 判定）");
  for (const [truth, cols] of Object.entries(r.metrics.confusion)) {
    console.log(
      `  ${truth}: ${Object.entries(cols)
        .map(([k, v]) => `${k}=${v}`)
        .join(" ")}`,
    );
  }
  // 48 行並べると読めないので、閾値を行・margin を列にした表にする（値は precision/recall のアルバム平均）
  const margins = [...new Set(r.sweep.map((s) => s.margin))];
  const thresholds = [...new Set(r.sweep.map((s) => s.threshold))];
  const def = Math.round(r.params.threshold * 10000) / 10000;
  console.log(
    "\nsweep（アルバム平均の precision/recall。* が既定。全組合せは eval.json の sweep）",
  );
  console.log(`  threshold\\margin ${margins.map((m) => m.toFixed(2).padStart(15)).join("")}`);
  for (const t of thresholds) {
    const cells = margins.map((m) => {
      const s = r.sweep.find((x) => x.threshold === t && x.margin === m);
      const mark = t === def && m === r.params.margin ? "*" : " ";
      return `${mark}${pct(s.macro.precision).trim()}/${pct(s.macro.recall).trim()}`.padStart(15);
    });
    console.log(`  ${t.toFixed(4).padEnd(16)} ${cells.join("")}`);
  }
  if (r.timing)
    console.log(`\nCPU 時間 ${JSON.stringify(r.timing.msPerImage)} ms/枚（${r.timing.images} 枚）`);
}

/** Worker に繋がず、手元の画像で検出と CCIP を試す。人物の枠と、画像同士の CCIP の差を出す。 */
async function runAnalyze() {
  const files = positionals.slice(1);
  if (!files.length) fail("analyze には画像ファイルを 1 つ以上渡す");
  const engine = await openEngine();
  const feats = [];
  const labels = [];
  for (const f of files) {
    const a = await engine.analyze(readFileSync(f));
    timingsLog.push(a.timings);
    console.log(
      JSON.stringify({
        file: f,
        size: [a.width, a.height],
        persons: a.persons.map((p) => ({ box: p.box, score: p.score, crop: p.crop })),
        ms: Object.fromEntries(Object.entries(a.timings).map(([k, v]) => [k, Math.round(v)])),
      }),
    );
    a.persons.forEach((p, i) => {
      feats.push(p.feat);
      labels.push(`${f}#${i}`);
    });
  }
  if (feats.length > 1) {
    const d = await engine.differences(feats);
    console.log(
      "CCIP の差（人物の切り出し同士。閾値",
      engine.params.threshold.toFixed(4),
      "以下で同キャラ）",
    );
    for (let i = 0; i < feats.length; i++) {
      for (let j = i + 1; j < feats.length; j++) {
        console.log(`  ${labels[i]} - ${labels[j]}: ${d(i, j).toFixed(4)}`);
      }
    }
  }
  console.log(`CPU 時間 ${JSON.stringify(timingSummary()?.msPerImage)} ms/枚`);
}

async function runApply() {
  if (!args.plan) fail("--plan <plan.json> を渡す");
  const plan = JSON.parse(readFileSync(args.plan, "utf8"));
  if (plan.version !== 1) fail("plan.json の version が 1 ではない");
  if (plan.evaluation) fail("--ignore-assigned で作った評価用 plan は apply できない");
  const results = await applyPlan(plan, api, {
    dryRun: args["dry-run"],
    log: (m) => console.log(m),
    // 作ったアルバムの id をすぐ plan に残す。途中で止まっても再実行は id で続きから戻る
    onProgress: args["dry-run"]
      ? undefined
      : () => writeFileSync(args.plan, JSON.stringify(plan, null, 2)),
  });
  if (!args["dry-run"]) writeFileSync(args.plan, JSON.stringify(plan, null, 2));
  const errors = results.filter((r) => r.status === "error");
  for (const e of errors) console.error(`error: ${e.id}: ${e.error}`);
  process.exit(errors.length ? 1 : 0);
}

const command = positionals[0];
if (!["ccip", "color"].includes(args.engine)) fail("--engine は ccip か color");
if (!["thumb", "original"].includes(args["image-source"]))
  fail("--image-source は thumb か original");
if (command === "plan") {
  needWorker();
  await (args.engine === "color" ? runPlanColor() : runPlanCcip());
} else if (command === "apply") {
  needWorker();
  await runApply();
} else if (command === "eval") {
  needWorker();
  await runEval();
} else if (command === "analyze") await runAnalyze();
else fail("usage: character-albums.mjs <plan|apply|eval|analyze> [options]");
