/**
 * キャラ別アルバム仕分けの純粋ロジック（特徴量・判定・計画・適用）。
 * 画像はローカルの sharp だけで扱い、外部 AI へは一切送らない。
 */
import { randomUUID } from "node:crypto";
import sharp from "sharp";

/** 1 回の album items 追加で worker が受け付けるキーの上限。超える分は分けて送る。 */
export const MAX_ADD_KEYS = 500;

export const DEFAULT_PARAMS = Object.freeze({
  high: 0.9,
  medium: 0.82,
  margin: 0.04,
  cluster: 0.9,
  nearDuplicateBits: 6,
  topK: 3,
});

const HUE_BINS = 12;
const SAT_BINS = 3;
const VAL_BINS = 3;
const BINS = HUE_BINS * SAT_BINS * VAL_BINS;
// 髪と顔が入りやすい上半分を重く見る。背景や衣装が変わっても同キャラを寄せるため。
const UPPER_WEIGHT = 2;

function rgbToHsv(r, g, b) {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const d = max - min;
  let h = 0;
  if (d) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h = (h * 60 + 360) % 360;
  }
  return [h, max ? d / max : 0, max / 255];
}

function binOf(r, g, b) {
  const [h, s, v] = rgbToHsv(r, g, b);
  const hb = Math.min(HUE_BINS - 1, Math.floor(h / (360 / HUE_BINS)));
  const sb = Math.min(SAT_BINS - 1, Math.floor(s * SAT_BINS));
  const vb = Math.min(VAL_BINS - 1, Math.floor(v * VAL_BINS));
  return (hb * SAT_BINS + sb) * VAL_BINS + vb;
}

function normalize(vec) {
  let n = 0;
  for (const x of vec) n += x * x;
  n = Math.sqrt(n) || 1;
  return vec.map((x) => x / n);
}

export function cosine(a, b) {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i] * b[i];
  return s;
}

export function hamming(a, b) {
  let x = BigInt.asUintN(64, BigInt(`0x${a}`) ^ BigInt(`0x${b}`));
  let n = 0;
  while (x) {
    n += Number(x & 1n);
    x >>= 1n;
  }
  return n;
}

/** 画像バイト列から色の分布（全体＋上半分）と dHash を作る。 */
export async function describe(bytes) {
  const size = 48;
  const { data, info } = await sharp(bytes)
    .removeAlpha()
    .resize(size, size, { fit: "cover", position: "attention" })
    .raw()
    .toBuffer({ resolveWithObject: true });
  const whole = new Array(BINS).fill(0);
  const upper = new Array(BINS).fill(0);
  for (let y = 0; y < info.height; y++) {
    for (let x = 0; x < info.width; x++) {
      const o = (y * info.width + x) * info.channels;
      const bin = binOf(data[o], data[o + 1], data[o + 2]);
      whole[bin]++;
      if (y < info.height / 2) upper[bin]++;
    }
  }
  const vector = normalize([...normalize(whole), ...normalize(upper).map((x) => x * UPPER_WEIGHT)]);
  const gray = await sharp(bytes)
    .removeAlpha()
    .greyscale()
    .resize(9, 8, { fit: "fill" })
    .raw()
    .toBuffer();
  let hash = 0n;
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      hash = (hash << 1n) | (gray[y * 9 + x] > gray[y * 9 + x + 1] ? 1n : 0n);
    }
  }
  return { vector, dhash: hash.toString(16).padStart(16, "0") };
}

function albumScore(target, refs, topK) {
  const sims = refs.map((r) => cosine(target.vector, r.vector)).sort((a, b) => b - a);
  const top = sims.slice(0, topK);
  const score = top.reduce((s, x) => s + x, 0) / (top.length || 1);
  const nearest = Math.min(...refs.map((r) => hamming(target.dhash, r.dhash)));
  return { score, nearest };
}

const round = (x) => Math.round(x * 1000) / 1000;

/**
 * 1 枚ずつ既存アルバムの参照画像と照合する。
 * 似ているだけの画像を同キャラ扱いしないよう、1 位と 2 位の差（margin）が小さいものは要確認に回す。
 */
export function classify(target, albums, params = DEFAULT_PARAMS, self = null) {
  // 対象自身が参照に入っていると自分と一致して確信度が水増しされるので外す。
  // 同じ名前のファイルが別ライブラリにあると消えてしまうので、除外はライブラリ込みで比べる
  const selfId = self ? `${self.lib ?? ""}:${self.key ?? self}` : null;
  const scored = albums
    .map((a) => ({
      album: a,
      refs: a.refs.filter((r) => `${r.lib ?? ""}:${r.key}` !== selfId),
    }))
    .filter((a) => a.refs.length)
    .map(({ album, refs }) => ({ album, ...albumScore(target, refs, params.topK) }))
    .sort((a, b) => b.score - a.score);
  const [best, second] = scored;
  if (!best) return { decision: "unmatched", rationale: "照合できる参照アルバムがない" };
  const margin = best.score - (second?.score ?? 0);
  const base = {
    albumId: best.album.id,
    albumTitle: best.album.title,
    score: round(best.score),
    second: second ? { albumTitle: second.album.title, score: round(second.score) } : null,
  };
  if (best.nearest <= params.nearDuplicateBits) {
    return {
      ...base,
      decision: "match",
      confidence: "high",
      rationale: `「${best.album.title}」の画像とほぼ同じ構図・色（差分 ${best.nearest}bit）。同一画像の別版の可能性があるので目視で確認する`,
    };
  }
  if (best.score >= params.medium && margin < params.margin && second) {
    return {
      ...base,
      decision: "review",
      rationale: `「${best.album.title}」と「${second.album.title}」の両方に近い（差 ${round(margin)}）。複数人が写っている／似た別キャラの可能性`,
    };
  }
  if (best.score >= params.high) {
    return {
      ...base,
      decision: "match",
      confidence: "high",
      rationale: `髪・顔まわり（上半分）と全体の色の組合せが「${best.album.title}」の上位${params.topK}枚と近い`,
    };
  }
  if (best.score >= params.medium) {
    return {
      ...base,
      decision: "match",
      confidence: "medium",
      rationale: `「${best.album.title}」に寄っているが決め手は弱い。目視で確認する`,
    };
  }
  return {
    ...base,
    decision: "unmatched",
    rationale: "どの既存アルバムとも近くない（新キャラまたは判別不能）",
  };
}

/** 完全連結で束ねる。単連結だと似た画像の鎖で別キャラまで繋がるため。 */
export function clusterUnmatched(items, threshold) {
  const groups = [];
  for (const item of items) {
    const g = groups.find((members) =>
      members.every((m) => cosine(m.desc.vector, item.desc.vector) >= threshold),
    );
    if (g) g.push(item);
    else groups.push([item]);
  }
  return groups;
}

const PROVISIONAL = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

/**
 * 判定結果を、アルバムごとの候補グループ＋新キャラ候補＋未分類にまとめる。
 * 既にどこかのアルバムに入っている画像は手動仕分けを尊重して触らない。
 */
export function buildPlan({ lib, targets, albums, assigned, params = DEFAULT_PARAMS, planId }) {
  // 仮タイトルに実行ごとの id を入れる。別の実行が同じラベルを作っても、
  // apply 時のタイトル照合が別プランのアルバムへ誤って寄せることがない
  const runId = planId ?? randomUUID().slice(0, 8);
  const groups = new Map();
  const review = [];
  const unmatched = [];
  const skipped = [];
  for (const t of targets) {
    if (assigned.has(`${lib}:${t.key}`)) {
      skipped.push({ key: t.key, reason: "既にアルバムに入っている" });
      continue;
    }
    const r = classify(t.desc, albums, params, { lib, key: t.key });
    const entry = {
      key: t.key,
      score: r.score ?? null,
      second: r.second ?? null,
      rationale: r.rationale,
    };
    if (r.decision === "match") {
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
    } else if (r.decision === "review") {
      review.push(entry);
    } else {
      unmatched.push({ ...entry, desc: t.desc });
    }
  }
  const created = [];
  const unclassified = [...review];
  let n = 0;
  for (const members of clusterUnmatched(unmatched, params.cluster)) {
    const items = members.map(({ desc: _desc, ...rest }) => rest);
    if (members.length < 2) {
      unclassified.push(...items);
      continue;
    }
    const label = `キャラクター${PROVISIONAL[n % PROVISIONAL.length]}${n >= PROVISIONAL.length ? Math.floor(n / PROVISIONAL.length) : ""}（仮・${runId}）`;
    n++;
    created.push({
      id: `create:${label}`,
      action: "create",
      title: label,
      approved: false,
      items: items.map((i) => ({
        ...i,
        confidence: "low",
        rationale: `${i.rationale}。未分類同士で色の組合せが近い`,
      })),
    });
  }
  return {
    version: 1,
    lib,
    planId: runId,
    createdAt: new Date().toISOString(),
    params,
    groups: [...groups.values(), ...created],
    unclassified,
    skipped,
  };
}

/**
 * 承認済み（approved: true）のグループだけ反映する。削除・移動はしない。
 * 作ったアルバムの id を plan に書き戻すので、再実行しても二重作成しない。
 * api: { listAlbums(lib), createAlbum(lib, title), addItems(lib, id, keys) }
 */
export async function applyPlan(plan, api, { dryRun = false, log = () => {}, onProgress } = {}) {
  const albums = await api.listAlbums(plan.lib);
  const writable = new Map(albums.filter((a) => !a.readOnly).map((a) => [a.id, a]));
  const results = [];
  for (const g of plan.groups) {
    if (!g.approved) {
      results.push({ id: g.id, status: "held" });
      continue;
    }
    const keys = g.items.map((i) => i.key);
    let albumId = g.action === "add" ? g.albumId : g.appliedAlbumId;
    if (g.action === "add" && !writable.has(albumId)) {
      results.push({
        id: g.id,
        status: "error",
        error: "書き込めないアルバム（読み取り専用か存在しない）",
      });
      continue;
    }
    if (g.action === "create" && !(albumId && writable.has(albumId))) {
      const same = albums.find((a) => !a.readOnly && a.title === g.title);
      if (same) albumId = same.id;
      else if (dryRun) albumId = null;
      else albumId = (await api.createAlbum(plan.lib, g.title)).id;
      g.appliedAlbumId = albumId ?? undefined;
      // 作成した id を即座に残す。途中で止まっても、やり直しはタイトル照合ではなく id で戻れる
      await onProgress?.(plan);
    }
    if (dryRun) {
      log(`[dry-run] ${g.title}: ${keys.length} 枚を追加予定`);
      results.push({ id: g.id, status: "dry-run", count: keys.length });
      continue;
    }
    // worker の上限を超える束は分けて送る
    let added = 0;
    let count;
    for (let i = 0; i < keys.length; i += MAX_ADD_KEYS) {
      const r = await api.addItems(plan.lib, albumId, keys.slice(i, i + MAX_ADD_KEYS));
      added += r.added;
      count = r.count;
    }
    log(`${g.title}: 追加 ${added} 枚（アルバム内 ${count} 枚）`);
    results.push({ id: g.id, status: "applied", albumId, added, count });
  }
  return results;
}
