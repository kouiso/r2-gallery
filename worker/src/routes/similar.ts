import { loadCatalog, type Catalog, type CatalogRow } from "../lib/catalog";
import { IMAGE_EXT } from "../lib/const";
import type { Env } from "../lib/env";
import { readable, similarLimits } from "../lib/env";
import { duplicateState, hashBudget, validHash, type HashesFile } from "../lib/hashes";
import { assertUserKey, HttpError, json, readJson } from "../lib/http";
import {
  compareSigs,
  decodeSig,
  extOf,
  groupNodes,
  newSigTable,
  PARAMS,
  setSig,
  sigInfo,
  type Group,
  type GroupItem,
  type GroupNodeInput,
  type MemberMeta,
} from "../lib/similar/core";
import { PROBE_BYTES, probeDims, type Dims } from "../lib/similar/probe";
import {
  exactRows,
  exactSide,
  isFailKind,
  isFlatAt,
  loadAllShards,
  loadHashesCached,
  loadShard,
  mutateShard,
  resetSimilarStoreMemory,
  shardOf,
  SHARDS,
  sigAtRow,
  validIndex,
  type Shard,
  type ShardItem,
  type SigFail,
  type SigSrc,
} from "../lib/similar/store";
import { mediaFor } from "../lib/store";

/**
 * 見た目の照合（似ている写真）の読み取りと署名の受け取り。
 *
 * Worker は絵を復号しない（wasm も Cloudflare Images も使わない: 後者は課金される）。署名は
 * アプリ・PC ツールが 512px のサムネから作って送り、ここでは etag と突き合わせて置くだけにする。
 * 書くのは META だけ（重複の確認と同じ）なので、読み取り専用のライブラリでも受け付ける。
 */

type Ctx = Pick<ExecutionContext, "waitUntil"> | undefined;

// サムネ 1 枚の目安。照合に要る通信量の見積もりに使う（実物は 20〜60 KB）
const THUMB_BYTES_ESTIMATE = 40 * 1024;
// アプリはこれより大きい原本からはサムネを作らない（maxThumbSourceBytes と同じ値）
const ORIGINAL_FETCH_CAP = 32 * 1024 * 1024;
const TODO_MAX = 300;
const LIST_MAX = 100;
const LIST_DEFAULT = 50;
const GROUP_ITEMS_MAX = 60;
const RELABEL_MAX = 60;
// 原本の先頭を読む本数。同時に開ける接続には上限がある
const PROBE_PARALLEL = 6;
// 署名の置き場を同時に書き直す数（読み解いた置き場の JSON を同時に幾つ持つか）
const SHARD_WRITE_PARALLEL = 2;

/** 同時に limit 本まで走らせる（Promise.all に全部投げると接続の上限で詰まる） */
async function forEachLimit<T>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<void>,
): Promise<void> {
  let next = 0;
  const worker = async () => {
    while (next < items.length) await fn(items[next++]!);
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
}

const lowerExt = (key: string): string => {
  const dot = key.lastIndexOf(".");
  return dot < 0 || dot < key.lastIndexOf("/") ? "" : key.slice(dot + 1).toLowerCase();
};

/* ---------------- 照合の進み具合 ---------------- */

interface Coverage {
  images: number;
  /** 有効な署名がある物（単色も含む） */
  signed: number;
  /** 復号できなかった・大きすぎた印がある物 */
  failed: number;
  /** signed のうち単色に近く、比べない物 */
  flat: number;
  pending: number;
  pendingWithThumb: number;
  pendingNoThumb: number;
  pendingBytesEstimate: number;
}

function coverageOf(catalog: Catalog, shards: readonly Shard[]): Coverage {
  const c: Coverage = {
    images: 0,
    signed: 0,
    failed: 0,
    flat: 0,
    pending: 0,
    pendingWithThumb: 0,
    pendingNoThumb: 0,
    pendingBytesEstimate: 0,
  };
  for (const row of catalog.rows.values()) {
    if (!IMAGE_EXT.test(row[0])) continue;
    c.images++;
    const shard = shards[shardOf(row[0])]!;
    const i = validIndex(shard, row);
    if (i < 0) {
      c.pending++;
      if (catalog.hasThumb(row[0])) {
        c.pendingWithThumb++;
        c.pendingBytesEstimate += THUMB_BYTES_ESTIMATE;
      } else {
        c.pendingNoThumb++;
        c.pendingBytesEstimate += Math.min(row[1], ORIGINAL_FETCH_CAP);
      }
    } else if (isFailKind(shard.kind[i]!)) {
      c.failed++;
    } else {
      c.signed++;
      if (isFlatAt(shard, i)) c.flat++;
    }
  }
  return c;
}

/** GET /v1/:lib/similar/status — 照合が済んだ数・残りの数と通信量の見積もり */
export async function handleSimilarStatus(env: Env, lib: string, ctx: Ctx): Promise<Response> {
  const { bucket } = readable(env, lib);
  const [catalog, shards] = await Promise.all([
    loadCatalog(env, lib, bucket, { ctx }),
    loadAllShards(env, lib),
  ]);
  // 1 回に受ける件数は env で下げられる。アプリはこれに合わせて分けて送る（固定の 200 / 40 で
  // 送ると、下げた時に全部 400 になり、署名も「元に戻す」も通らなくなる）
  const { sigBatch, trashBatch } = similarLimits(env);
  return json({
    alg: PARAMS.alg,
    params: PARAMS.version,
    ...coverageOf(catalog, shards),
    sigBatch,
    trashBatch,
  });
}

/* ---------------- 署名がまだ無い物 ---------------- */

/**
 * GET /v1/:lib/similar/todo?shard=&after=&limit= — 置き場 1 つぶんの、署名も失敗の印も無い画像を
 * key の順に返す。署名を作る側は置き場 0..31 を順に回り、after で続きを取る。
 */
export async function handleSimilarTodo(
  env: Env,
  origin: string,
  lib: string,
  url: URL,
  ctx: Ctx,
): Promise<Response> {
  const { bucket } = readable(env, lib);
  const rawShard = url.searchParams.get("shard") ?? "";
  const shardNo = Number(rawShard);
  if (!/^\d{1,2}$/.test(rawShard) || shardNo >= SHARDS) throw new HttpError(400, "bad_shard");
  const limit = Math.min(
    TODO_MAX,
    Math.max(1, Number(url.searchParams.get("limit") ?? TODO_MAX) || TODO_MAX),
  );
  const after = url.searchParams.get("after") ?? "";
  const [catalog, shard] = await Promise.all([
    loadCatalog(env, lib, bucket, { ctx }),
    loadShard(env, lib, shardNo),
  ]);
  const pending: CatalogRow[] = [];
  for (const row of catalog.rows.values()) {
    if (!IMAGE_EXT.test(row[0]) || shardOf(row[0]) !== shardNo) continue;
    if (validIndex(shard, row) < 0) pending.push(row);
  }
  pending.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  // 署名を送るたびに残りが減って番号がずれるので、続きは「この key より後」で探す
  let start = 0;
  if (after) {
    start = pending.findIndex((r) => r[0] > after);
    if (start < 0) start = pending.length;
  }
  const page = pending.slice(start, start + limit);
  const items = await Promise.all(
    page.map(async (row) => ({
      ...(await mediaFor(
        env,
        origin,
        lib,
        { key: row[0], createdAt: row[2] },
        catalog.hasThumb(row[0]),
      )),
      etag: row[3],
      size: row[1],
      ext: lowerExt(row[0]),
    })),
  );
  const last = page[page.length - 1];
  return json({
    shard: shardNo,
    items,
    next: last && start + page.length < pending.length ? last[0] : null,
    pendingInShard: pending.length,
  });
}

/* ---------------- 署名の受け取り ---------------- */

interface SigUpload {
  key: string;
  etag: string;
  sig: string | null;
  src: SigSrc | null;
  fail: SigFail | null;
}

const badItems = () => new HttpError(400, "bad_items");

function parseUpload(v: unknown, seen: Set<string>): SigUpload {
  const r = v && typeof v === "object" ? (v as Record<string, unknown>) : {};
  let key: string;
  try {
    key = assertUserKey(r.key);
  } catch {
    throw badItems();
  }
  // 動画には見た目の署名を付けない（同じ中身の動画は SHA-256 で束ねる）
  if (!IMAGE_EXT.test(key) || seen.has(key)) throw badItems();
  seen.add(key);
  if (typeof r.etag !== "string" || !r.etag || r.etag.length > 256) throw badItems();
  const hasSig = r.sig !== undefined && r.sig !== null;
  const hasFail = r.fail !== undefined && r.fail !== null;
  if (hasSig === hasFail) throw badItems();
  if (hasSig) {
    if (typeof r.sig !== "string") throw badItems();
    const sig = decodeSig(r.sig);
    if (!sig) throw badItems();
    const info = sigInfo(sig);
    if (!info.w || !info.h) throw badItems();
    if (r.src !== "t" && r.src !== "o") throw badItems();
    return { key, etag: r.etag, sig: r.sig, src: r.src, fail: null };
  }
  if (r.fail !== "decode" && r.fail !== "too_large") throw badItems();
  // 失敗の印には元を使わないので、src は無くてもよい（有っても t / o だけ）
  if (r.src !== undefined && r.src !== "t" && r.src !== "o") throw badItems();
  return { key, etag: r.etag, sig: null, src: null, fail: r.fail };
}

/**
 * POST /v1/:lib/similar/signatures {alg, items:[{key, etag, src, sig? | fail?}]}
 * 今の一覧と etag が合う物だけを置く（合わない物は stale として数えて捨てる）。
 * 署名を置く物は原本の先頭 64 KB を読んで元の寸法を取る（残す物の順と「差分かも」に使う）。
 */
export async function handleSimilarSignatures(
  req: Request,
  env: Env,
  lib: string,
  ctx: Ctx,
): Promise<Response> {
  const { bucket } = readable(env, lib);
  const body = await readJson(req);
  // 算法の版が違う署名を混ぜると判定がでたらめになる。古いアプリには更新を促す（409）
  if (body.alg !== PARAMS.alg) throw new HttpError(409, "alg_mismatch");
  const raw = body.items;
  if (!Array.isArray(raw) || raw.length > similarLimits(env).sigBatch) throw badItems();
  const seen = new Set<string>();
  // 1 件でも壊れていれば何も置かない（半端に置くと、送った側がどれが入ったか分からない）
  const uploads = raw.map((v) => parseUpload(v, seen));

  const catalog = await loadCatalog(env, lib, bucket, { ctx });
  let stale = 0;
  const fresh = uploads.filter((u) => {
    const row = catalog.rows.get(u.key);
    if (row && row[3] === u.etag) return true;
    stale++;
    return false;
  });

  const dims = new Map<string, Dims>();
  const staleKeys = new Set<string>();
  await forEachLimit(
    fresh.filter((u) => u.sig),
    PROBE_PARALLEL,
    async (u) => {
      const size = catalog.rows.get(u.key)![1];
      // 小さい物は全体を読む（範囲が中身より長い指定を避ける）
      const length = Math.min(PROBE_BYTES, size);
      if (length <= 0) {
        dims.set(u.key, { w: 0, h: 0 });
        return;
      }
      const obj = await bucket.get(u.key, { range: { offset: 0, length } });
      // 一覧の後に消えた・入れ替わった物は置かない（寸法が別の中身の物になる）
      if (!obj || obj.etag !== u.etag) {
        await obj?.body.cancel();
        staleKeys.add(u.key);
        return;
      }
      dims.set(u.key, probeDims(new Uint8Array(await obj.arrayBuffer())));
    },
  );

  const byShard = new Map<number, [string, ShardItem][]>();
  for (const u of fresh) {
    if (staleKeys.has(u.key)) {
      stale++;
      continue;
    }
    const d = dims.get(u.key) ?? { w: 0, h: 0 };
    const item: ShardItem = u.sig ? [u.etag, u.sig, u.src!, d.w, d.h] : [u.etag, null, u.fail!];
    const n = shardOf(u.key);
    const list = byShard.get(n);
    if (list) list.push([u.key, item]);
    else byShard.set(n, [[u.key, item]]);
  }

  let stored = 0;
  let failRecorded = 0;
  // 置き場は少しずつ書き直す。200 件はほぼ 32 の置き場全部に散るので、全部を同時に書くと
  // 署名の置き場まるごとの JSON（5 万件で 20 MB 余り）を一度に読み解いて持ち、大きなライブラリで
  // isolate のメモリ（128 MB）を超える。1 つ書き終えれば読み解いた中身は手放す
  await forEachLimit([...byShard], SHARD_WRITE_PARALLEL, async ([n, list]) => {
    // やり直しで何度呼ばれても同じ結果になるよう、数えるのは最後に書けた回の分だけ
    let s = 0;
    let f = 0;
    await mutateShard(
      env,
      lib,
      n,
      (items) => {
        s = 0;
        f = 0;
        for (const [key, item] of list) {
          const have = items[key];
          // 同じ中身に有効な署名があるなら、別の端末の「読めなかった」で潰さない
          if (item[1] === null && have && have[0] === item[0] && have[1] !== null) continue;
          items[key] = item;
          if (item[1] === null) f++;
          else s++;
        }
      },
      catalog,
    );
    stored += s;
    failRecorded += f;
  });
  return json({ stored, stale, failRecorded });
}

/* ---------------- 束の一覧 ---------------- */

interface ModelGroup {
  id: string;
  tier: "dup" | "similar";
  reclaim: number;
  /** 並べる値（dup は空けられる量、similar は件数）。続きのカーソルに入れる */
  sortValue: number;
  items: GroupItem[];
}

interface Model {
  dup: ModelGroup[];
  similar: ModelGroup[];
  summary: {
    dup: { groups: number; items: number; reclaimable: number };
    similar: { groups: number; items: number };
    crowded: number;
    coverage: Pick<Coverage, "images" | "signed" | "pending" | "failed" | "flat">;
    hashPending: number;
    hashSkipped: number;
  };
}

const modelMem = new Map<string, { key: string; model: Model }>();

/** テスト用: isolate が持つ写し（署名・ハッシュ・束ねた結果）を捨てる */
export function resetSimilarMemory(): void {
  modelMem.clear();
  resetSimilarStoreMemory();
}

/** 有効な署名の在りか（単色も含む）。画像でない・署名が無い・失敗の印なら null */
function validSigAt(shards: readonly Shard[], row: CatalogRow): { shard: Shard; i: number } | null {
  if (!IMAGE_EXT.test(row[0])) return null;
  const shard = shards[shardOf(row[0])]!;
  const i = validIndex(shard, row);
  return i >= 0 && !isFailKind(shard.kind[i]!) ? { shard, i } : null;
}

/** テスト用に外へ出す（記憶の量を Node で測る: tools/similar-model-memory.test.mjs） */
export function buildModel(
  catalog: Catalog,
  shards: readonly Shard[],
  hashes: HashesFile,
  maxObjectBytes: number,
  maxNodes: number,
): Model {
  const coverage = coverageOf(catalog, shards);
  const exact = duplicateState(catalog, hashes, maxObjectBytes);
  const inExact = new Set<string>();
  for (const g of exact.groups) for (const r of g.rows) inExact.add(r[0]);
  // 節の数を、節・署名の表を作る前に数える。作ってから断ると、断る前に大きなライブラリで
  // isolate のメモリを使い切る（節は同じ中身の束 1 つと、束に入らない単色でない署名 1 件ずつ）
  let nodeCount = exact.groups.length;
  for (const row of catalog.rows.values()) {
    if (inExact.has(row[0])) continue;
    const v = validSigAt(shards, row);
    if (v && !isFlatAt(v.shard, v.i)) nodeCount++;
  }
  if (nodeCount > maxNodes) throw new HttpError(413, "too_many_for_similar");

  // 有効な署名の在りかを 1 回で集める（単色も含む: 同じ中身の束はどれかの署名を使う）
  const valid = new Map<string, { row: CatalogRow; shard: Shard; i: number }>();
  for (const row of catalog.rows.values()) {
    const v = validSigAt(shards, row);
    if (v) valid.set(row[0], { row, ...v });
  }
  const memberOf = (row: CatalogRow): MemberMeta => {
    const v = valid.get(row[0]);
    return {
      key: row[0],
      size: row[1],
      uploaded: row[2],
      ow: v ? v.shard.ow[v.i]! : 0,
      oh: v ? v.shard.oh[v.i]! : 0,
      ext: extOf(row[0]),
    };
  };

  const nodes: GroupNodeInput[] = [];
  const tableRows: { shard: Shard; i: number }[] = [];
  for (const g of exact.groups) {
    // 同じ中身の束は 1 つの節。動画もここに入り、見た目の辺は持たない。
    // 署名は古い順で最初の単色でない物（ゴミ箱・付け直しの exactSide と同じ決まり）
    let sig = -1;
    for (const r of g.rows) {
      const v = valid.get(r[0]);
      if (sig < 0 && v && !isFlatAt(v.shard, v.i)) sig = tableRows.push(v) - 1;
    }
    // 寸法は分かっている一員の物を全員に使う。古い残す物に寸法が無いと差分かもが付かない
    const side = exactSide(g.rows, (k) => shards[shardOf(k)]);
    nodes.push({
      members: g.rows.map((r) => ({
        ...memberOf(r),
        ...(side.ow > 0 ? { ow: side.ow, oh: side.oh } : {}),
      })),
      sig,
    });
  }
  for (const [key, v] of valid) {
    if (inExact.has(key) || isFlatAt(v.shard, v.i)) continue;
    nodes.push({ members: [memberOf(v.row)], sig: tableRows.push(v) - 1 });
  }

  const table = newSigTable(tableRows.length);
  tableRows.forEach((v, n) => setSig(table, n, sigAtRow(v.shard, v.i)!));
  const { groups, crowded } = groupNodes(nodes, table);

  const toModel = (g: Group): ModelGroup => {
    const members = g.items.slice(1);
    // 反転・差分かもは別の絵のことがあるので、空けられる量には数えない
    const reclaim =
      g.tier === "dup"
        ? members.reduce(
            (s, it) => (it.match === "mirror" || it.variant ? s : s + it.member.size),
            0,
          )
        : members.reduce((s, it) => s + it.member.size, 0);
    return {
      id: g.id,
      tier: g.tier,
      reclaim,
      sortValue: g.tier === "dup" ? reclaim : members.length,
      items: g.items,
    };
  };
  const order = (a: ModelGroup, b: ModelGroup) =>
    b.sortValue - a.sortValue || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  const dup = groups
    .filter((g) => g.tier === "dup")
    .map(toModel)
    .sort(order);
  const similar = groups
    .filter((g) => g.tier === "similar")
    .map(toModel)
    .sort(order);
  const memberCount = (list: ModelGroup[]) => list.reduce((s, g) => s + g.items.length - 1, 0);
  return {
    dup,
    similar,
    summary: {
      dup: {
        groups: dup.length,
        items: memberCount(dup),
        reclaimable: dup.reduce((s, g) => s + g.reclaim, 0),
      },
      similar: { groups: similar.length, items: memberCount(similar) },
      crowded,
      coverage: {
        images: coverage.images,
        signed: coverage.signed,
        pending: coverage.pending,
        failed: coverage.failed,
        flat: coverage.flat,
      },
      hashPending: exact.pending.length,
      hashSkipped: exact.skipped,
    },
  };
}

const utf8 = new TextEncoder();
const utf8d = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });

function encodeCursor(g: ModelGroup): string {
  let s = "";
  for (const b of utf8.encode(JSON.stringify([g.sortValue, g.id]))) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function decodeCursor(raw: string): [number, string] {
  try {
    const bin = atob(raw.replace(/-/g, "+").replace(/_/g, "/"));
    const v = JSON.parse(utf8d.decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)))) as unknown;
    if (
      Array.isArray(v) &&
      v.length === 2 &&
      typeof v[0] === "number" &&
      Number.isFinite(v[0]) &&
      typeof v[1] === "string"
    ) {
      return [v[0], v[1]];
    }
  } catch {
    // 下で 400 にする
  }
  // 読めないカーソルを黙って先頭扱いにすると、全件読み込みが同じページを取り続けて終わらない
  throw new HttpError(400, "bad_cursor");
}

async function itemJson(env: Env, origin: string, lib: string, catalog: Catalog, it: GroupItem) {
  const m = it.member;
  return {
    ...(await mediaFor(
      env,
      origin,
      lib,
      { key: m.key, createdAt: m.uploaded },
      catalog.hasThumb(m.key),
    )),
    size: m.size,
    match: it.match,
    ...(it.ph !== undefined ? { ph: it.ph } : {}),
    ...(it.dh !== undefined ? { dh: it.dh } : {}),
    variant: it.variant,
    ...(m.ow > 0 && m.oh > 0 ? { ow: m.ow, oh: m.oh } : {}),
  };
}

/**
 * GET /v1/:lib/similar?tab=dup|similar&cursor=&limit= — 重複（同じファイル・ほぼ同じ・反転）と
 * 似ている写真の束。署名・ハッシュ・一覧が変わらない間は束ねた結果を isolate に置いて使い回す。
 */
export async function handleSimilar(
  env: Env,
  origin: string,
  lib: string,
  url: URL,
  ctx: Ctx,
): Promise<Response> {
  const { bucket } = readable(env, lib);
  const tab = url.searchParams.get("tab") ?? "dup";
  if (tab !== "dup" && tab !== "similar") throw new HttpError(400, "bad_tab");
  const limit = Math.min(
    LIST_MAX,
    Math.max(1, Number(url.searchParams.get("limit") ?? LIST_DEFAULT) || LIST_DEFAULT),
  );
  const rawCursor = url.searchParams.get("cursor") ?? "";
  const cursor = rawCursor ? decodeCursor(rawCursor) : null;

  const [catalog, shards, hashes] = await Promise.all([
    loadCatalog(env, lib, bucket, { ctx }),
    loadAllShards(env, lib),
    loadHashesCached(env, lib),
  ]);
  const { maxObjectBytes } = hashBudget(env);
  const cacheKey = [
    PARAMS.version,
    catalog.stamp,
    hashes.etag,
    maxObjectBytes,
    ...shards.map((s) => s.etag ?? "-"),
  ].join("\n");
  let model = modelMem.get(lib)?.key === cacheKey ? modelMem.get(lib)!.model : null;
  if (!model) {
    model = buildModel(catalog, shards, hashes.data, maxObjectBytes, similarLimits(env).maxNodes);
    modelMem.set(lib, { key: cacheKey, model });
  }

  const list = tab === "dup" ? model.dup : model.similar;
  // 消すと束が減って番号がずれるので、続きは「この束より後」で探す
  let start = 0;
  if (cursor) {
    const [value, id] = cursor;
    start = list.findIndex((g) => g.sortValue < value || (g.sortValue === value && g.id > id));
    if (start < 0) start = list.length;
  }
  const page = list.slice(start, start + limit);
  const groups = await Promise.all(
    page.map(async (g) => ({
      id: g.id,
      tier: g.tier,
      reclaim: g.reclaim,
      items: await Promise.all(
        g.items.slice(0, GROUP_ITEMS_MAX).map((it) => itemJson(env, origin, lib, catalog, it)),
      ),
      more: Math.max(0, g.items.length - GROUP_ITEMS_MAX),
    })),
  );
  const last = page[page.length - 1];
  return json({
    groups,
    cursor: last && start + page.length < list.length ? encodeCursor(last) : null,
    total: list.length,
    summary: model.summary,
  });
}

/* ---------------- 残す物を変えた時の判定し直し ---------------- */

/**
 * POST /v1/:lib/similar/relabel {keep, keys} — 利用者が別の物を「オリジナル」にした時、
 * 束の各員を新しい残す物と比べ直す。束は残す物を基準に作ったので、基準が変わると
 * 「ほぼ同じ」が成り立たない組が出る（その物は match:null を返し、アプリは選べなくする）。
 */
export async function handleSimilarRelabel(
  req: Request,
  env: Env,
  lib: string,
  ctx: Ctx,
): Promise<Response> {
  const { bucket } = readable(env, lib);
  const body = await readJson(req);
  const keep = assertUserKey(body.keep);
  const raw = body.keys;
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > RELABEL_MAX) throw badItems();
  const keys = [
    ...new Set(
      raw.map((k) => {
        try {
          return assertUserKey(k);
        } catch {
          throw badItems();
        }
      }),
    ),
  ];
  const shardNos = [...new Set([keep, ...keys].map(shardOf))];
  const [catalog, hashes, loaded] = await Promise.all([
    loadCatalog(env, lib, bucket, { ctx }),
    loadHashesCached(env, lib),
    Promise.all(shardNos.map((n) => loadShard(env, lib, n).then((s) => [n, s] as const))),
  ]);
  const shards = new Map(loaded);
  const keepRow = catalog.rows.get(keep);
  if (!keepRow) throw new HttpError(409, "keeper_missing");

  // 同じ中身の物は一覧と同じく集まりの署名で比べる。要る区画を先に読み足す
  const rowsOf = new Map<string, CatalogRow[]>();
  for (const k of [keep, ...keys]) {
    const row = catalog.rows.get(k);
    if (row && IMAGE_EXT.test(k)) rowsOf.set(k, exactRows(row, catalog, hashes.data));
  }
  const more = [...new Set([...rowsOf.values()].flat().map((r) => shardOf(r[0])))].filter(
    (n) => !shards.has(n),
  );
  for (const [n, s] of await Promise.all(
    more.map((n) => loadShard(env, lib, n).then((s) => [n, s] as const)),
  )) {
    shards.set(n, s);
  }
  const sideOf = (row: CatalogRow) => {
    const side = rowsOf.has(row[0])
      ? exactSide(rowsOf.get(row[0])!, (k) => shards.get(shardOf(k)))
      : { sig: null, ow: 0, oh: 0 };
    return {
      sig: side.sig,
      meta: {
        ow: side.ow,
        oh: side.oh,
        ext: extOf(row[0]),
        sha256: validHash(hashes.data, row),
      },
    };
  };
  const k = sideOf(keepRow);
  const labels: Record<string, unknown> = {};
  for (const key of keys) {
    if (key === keep) {
      labels[key] = { match: "keeper" };
      continue;
    }
    const row = catalog.rows.get(key);
    const other = row ? sideOf(row) : null;
    const r = other ? compareSigs(k.sig, other.sig, k.meta, other.meta) : null;
    labels[key] = r ? { match: r.label, ph: r.ph, dh: r.dh, variant: r.variant } : { match: null };
  }
  return json({ labels });
}
