#!/usr/bin/env node
/**
 * R2 に追加されたキャラ画像を、見た目で既存アルバムへ仕分ける運用ツール（#31）。
 *
 *   plan  : 読み取り専用。参照アルバムと対象画像のサムネを落としてローカルで照合し、
 *           plan.json と preview.html（代表サムネ・候補・確信度・根拠）を出す。
 *   apply : plan.json で approved: true にしたグループだけをアルバムへ関連付ける。
 *           原画像の移動・削除・上書きはしない。再実行しても二重登録しない。
 *
 * Usage:
 *   R2G_ENDPOINT=https://... R2G_TOKEN=... node tools/character-albums.mjs plan \
 *     --lib personal --ref-albums さくら,ダウナーお姉さん [--keys-file keys.txt | --recent 200] \
 *     [--ref-per-album 24] [--ignore-assigned] --out .work/character-albums
 *   --ignore-assigned は精度評価用。配属済みも照合し、出した plan は apply できない。
 *   R2G_ENDPOINT=... R2G_TOKEN=... node tools/character-albums.mjs apply \
 *     --plan .work/character-albums/plan.json [--dry-run]
 *
 * 画像は外部 AI に送らない。トークンや署名 URL はログに出さない。
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import sharp from "sharp";
import { DEFAULT_PARAMS, applyPlan, buildPlan, describe } from "./character-albums-core.mjs";

const IMAGE_RE = /\.(jpe?g|png|webp|gif|avif)$/i;

const { positionals, values: args } = parseArgs({
  allowPositionals: true,
  options: {
    lib: { type: "string", default: "personal" },
    "ref-albums": { type: "string" },
    "ref-per-album": { type: "string", default: "24" },
    "keys-file": { type: "string" },
    recent: { type: "string" },
    out: { type: "string", default: ".work/character-albums" },
    plan: { type: "string" },
    "dry-run": { type: "boolean", default: false },
    "ignore-assigned": { type: "boolean", default: false },
  },
});

function fail(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

const endpoint = (process.env.R2G_ENDPOINT ?? "").replace(/\/$/, "");
const token = process.env.R2G_TOKEN ?? "";
if (!endpoint || !token) fail("R2G_ENDPOINT と R2G_TOKEN を環境変数で渡す");

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
  async recentKeys(lib, limit) {
    const items = [];
    let cursor = "";
    while (items.length < limit) {
      const q = `recursive=1&order=recent${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
      const d = await getJson(`/v1/${encodeURIComponent(lib)}/folders?${q}`);
      items.push(...(d.items ?? []));
      if (!d.cursor) break;
      cursor = d.cursor;
    }
    return items.slice(0, limit);
  },
};

function sample(list, n) {
  if (list.length <= n) return list;
  const step = list.length / n;
  return Array.from({ length: n }, (_, i) => list[Math.floor(i * step)]);
}

async function thumbBytes(item) {
  const url = item.thumbUrl ?? item.url;
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

async function runPlan() {
  const lib = args.lib;
  const refTitles = (args["ref-albums"] ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (!refTitles.length) fail("--ref-albums に照合に使うアルバム名をカンマ区切りで渡す");
  const perAlbum = Number(args["ref-per-album"]);
  const wanted = args["keys-file"]
    ? new Set(
        readFileSync(args["keys-file"], "utf8")
          .split(/\r?\n/)
          .map((s) => s.trim())
          .filter(Boolean),
      )
    : null;
  const all = await api.listAlbums(lib);
  const assigned = new Set();
  const refs = [];
  const covers = new Map();
  for (const a of all) {
    const items = await api.albumItems(lib, a.id);
    for (const it of items) assigned.add(`${it.lib ?? lib}:${it.key}`);
    if (!refTitles.includes(a.title)) continue;
    if (a.readOnly) {
      // 読み取り専用アルバムには追加できないので、照合先にも入れない。
      console.warn(`warn: 「${a.title}」は読み取り専用なので照合に使わない`);
      continue;
    }
    const picked = sample(
      items.filter((i) => IMAGE_RE.test(i.key)),
      perAlbum,
    );
    const descs = [];
    const coverUris = [];
    for (const it of picked) {
      const bytes = await thumbBytes(it);
      descs.push({ key: it.key, ...(await describe(bytes)) });
      if (coverUris.length < 6) coverUris.push(await dataUri(bytes));
    }
    refs.push({ id: a.id, title: a.title, refs: descs });
    covers.set(a.id, coverUris);
  }
  const missing = refTitles.filter((t) => !refs.some((r) => r.title === t));
  if (missing.length) fail(`書き込める参照アルバムが見つからない: ${missing.join(",")}`);

  let targetItems;
  if (wanted) {
    const recent = await api.recentKeys(lib, Number(args.recent ?? 2000));
    targetItems = recent.filter((i) => wanted.has(i.key));
    const notFound = [...wanted].filter((k) => !targetItems.some((i) => i.key === k));
    if (notFound.length) console.warn(`warn: 一覧に見つからないキー ${notFound.length} 件は対象外`);
  } else {
    targetItems = await api.recentKeys(lib, Number(args.recent ?? 200));
  }
  targetItems = targetItems.filter((i) => IMAGE_RE.test(i.key));

  const targets = [];
  const thumbs = new Map();
  for (const it of targetItems) {
    const bytes = await thumbBytes(it);
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
  if (evaluation) plan.evaluation = true;
  mkdirSync(args.out, { recursive: true });
  writeFileSync(join(args.out, "plan.json"), JSON.stringify(plan, null, 2));
  writeFileSync(join(args.out, "preview.html"), previewHtml(plan, thumbs, covers));
  const summary = plan.groups.map((g) => `${g.title}=${g.items.length}`).join(" ");
  console.log(
    `対象 ${targets.length} 枚 / 配属済み ${plan.skipped.length} / 候補 ${summary || "なし"} / 未分類 ${plan.unclassified.length}`,
  );
  console.log(`plan: ${join(args.out, "plan.json")}  preview: ${join(args.out, "preview.html")}`);
}

async function runApply() {
  if (!args.plan) fail("--plan <plan.json> を渡す");
  const plan = JSON.parse(readFileSync(args.plan, "utf8"));
  if (plan.version !== 1) fail("plan.json の version が 1 ではない");
  if (plan.evaluation) fail("--ignore-assigned で作った評価用 plan は apply できない");
  const results = await applyPlan(plan, api, {
    dryRun: args["dry-run"],
    log: (m) => console.log(m),
  });
  if (!args["dry-run"]) writeFileSync(args.plan, JSON.stringify(plan, null, 2));
  const errors = results.filter((r) => r.status === "error");
  for (const e of errors) console.error(`error: ${e.id}: ${e.error}`);
  process.exit(errors.length ? 1 : 0);
}

const command = positionals[0];
if (command === "plan") await runPlan();
else if (command === "apply") await runApply();
else fail("usage: character-albums.mjs <plan|apply> [options]");
