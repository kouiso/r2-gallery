import { IMAGE_EXT, MEDIA_EXT, SYSTEM_PREFIX, TRASH_PREFIX, VIDEO_EXT } from "./const";
import type { Env } from "./env";
import { libraries } from "./env";

/**
 * ライブラリの中身の索引。
 *
 * R2 は辞書順でしか列挙できないので、日付順などで返すには全件が要る。5 万件あると
 * 1 ページ返すたびに list を 50 回以上呼ぶことになり、最初の 1 枚が出るまで数秒かかっていた。
 * 全件の一覧を META に 1 ファイルで置き、Worker 経由の書き込みは小さな追記(journal)で足す。
 * 読む側は「索引 1 件の取得 + journal の一覧」だけで済む。
 *
 * - 索引:   .system/catalog/<lib>.json
 * - 追記:   .system/catalog/<lib>/j/<時刻>-<乱数>.json
 *
 * R2 に直接置かれた物（Worker を通らない書き込み）は索引の作り直しで拾う。
 */

/** [key, size, uploaded(ms), etag] */
export type CatalogRow = [key: string, size: number, uploaded: number, etag: string];

interface SnapshotFile {
  version: 1;
  startedAt: number;
  /** 5 番目はサムネが META に保存済みか */
  items: [string, number, number, string, 0 | 1][];
}

export interface JournalEntry {
  put?: CatalogRow[];
  del?: string[];
  thumb?: string[];
  unthumb?: string[];
}

export type FolderSort = "new" | "old" | "name" | "size";
// 一覧の種別絞り込み。#26: 写真だけ・動画だけを出す口。all はパラメータ省略時の全件
export type FolderType = "photo" | "video";

// 同じ値の物が並ぶと位置が一つに決まらないので、key を決め手に足して全順序にする
export interface SortPoint {
  primary: number | string;
  key: string;
}

export interface FolderView {
  files: CatalogRow[];
  points: SortPoint[];
  folders: string[];
}

interface CatalogState {
  etag: string;
  startedAt: number;
  base: Map<string, CatalogRow>;
  baseThumbs: Set<string>;
  rows: Map<string, CatalogRow>;
  thumbs: Set<string>;
  applied: string[];
  views: Map<string, FolderView>;
  sizes: Map<number, CatalogRow[]> | null;
}

export interface Catalog {
  startedAt: number;
  rows: ReadonlyMap<string, CatalogRow>;
  hasThumb(key: string): boolean;
  view(prefix: string, recursive: boolean, sort: FolderSort, type?: FolderType): FolderView;
  /** 一覧に出る物（メディアの拡張子を持つ物）をサイズごとに束ねたもの */
  bySize(): ReadonlyMap<number, CatalogRow[]>;
}

const RESERVED = [SYSTEM_PREFIX, TRASH_PREFIX];
// 別々の isolate の時計のずれ。索引を作り始めた時刻より少し前の追記も重ねて当てる。
// 追記は「その key の今の姿」なので、Worker 経由の書き込みだけなら二度当てても結果は
// 変わらない。この幅の間に R2 へ直接書かれた物とは食い違い得る（次の作り直しで直る）ので、
// 幅は時計のずれを吸える範囲で小さく取る
const CLOCK_SKEW_MS = 10_000;
const DEFAULT_MAX_AGE_S = 300;
// 追記が溜まると毎回の読み込みが重くなるので、この数を超えたら索引へ畳む
const JOURNAL_COMPACT_AT = 400;
// ここまで溜まると、追記を全部読むだけで 1 リクエストの外部呼び出しの上限（1000 回）に
// 近づく。裏で畳むのを待たず、畳んでから答える
const JOURNAL_HARD_LIMIT = 600;
// 裏の作り直しを別々の isolate が同時に始めないための目印の寿命
const REBUILD_LEASE_MS = 60_000;
const VIEW_CACHE = 6;

const snapshotKey = (lib: string) => `${SYSTEM_PREFIX}catalog/${lib}.json`;
const journalPrefix = (lib: string) => `${SYSTEM_PREFIX}catalog/${lib}/j/`;
const leaseKey = (lib: string) => `${SYSTEM_PREFIX}catalog/${lib}.lease`;
const thumbPrefix = (lib: string) => `${SYSTEM_PREFIX}thumbs/${lib}/`;

const mem = new Map<string, CatalogState>();
const journalBodies = new Map<string, JournalEntry>();
const rebuilding = new Map<string, Promise<void>>();

/** テスト用: isolate が持つ索引の写しを捨てる */
export function resetCatalogMemory(): void {
  mem.clear();
  journalBodies.clear();
  rebuilding.clear();
}

function maxAgeMs(env: Env): number {
  const raw = env.CATALOG_MAX_AGE_SECONDS;
  const n = raw === undefined || raw === "" ? DEFAULT_MAX_AGE_S : Number(raw);
  return (Number.isFinite(n) && n >= 0 ? n : DEFAULT_MAX_AGE_S) * 1000;
}

/** 索引を使って答えるか。0 は「毎回作り直す」設定で、索引を当てにする近道は使わない */
export const catalogEnabled = (env: Env): boolean => maxAgeMs(env) > 0;

const journalTime = (journalKey: string, prefix: string): number =>
  Number(journalKey.slice(prefix.length).split("-")[0]) || 0;

/* ---------------- 追記 ---------------- */

/**
 * 書き込みが成功した後に索引へ追記する。ここで失敗を 5xx にすると、保存済みなのに
 * クライアントが再送して 409 になり別名で二重保存される。なので数回試して、だめなら
 * 記録だけ残す（次の作り直しで揃う）。
 */
export async function journalBestEffort(
  env: Env,
  lib: string,
  entry: JournalEntry,
  ctx?: Pick<ExecutionContext, "waitUntil">,
): Promise<void> {
  const key = `${journalPrefix(lib)}${String(Date.now()).padStart(15, "0")}-${crypto.randomUUID()}.json`;
  const body = JSON.stringify(entry);
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      await env.META.put(key, body, { httpMetadata: { contentType: "application/json" } });
      return;
    } catch (e) {
      if (attempt === 2) console.error("catalog_journal_failed", lib, e);
    }
  }
  // WHY: 追記が書けないと在る物が一覧から欠ける。応答の後に間をあけてやり直し、
  //      クライアントの送り直しを待たずに索引が揃うようにする
  if (!ctx) return;
  // 書き直す間隔は設定で変えられる。テストは 0 にして待ちを通さない
  const delays = (env.JOURNAL_RETRY_AFTER_MS ?? "1000,5000,30000")
    .split(",")
    .map((s) => Number(s.trim()) || 0)
    .slice(0, 8);
  ctx.waitUntil(
    (async () => {
      for (const wait of delays) {
        if (wait > 0) await new Promise((r) => setTimeout(r, wait));
        try {
          await env.META.put(key, body, { httpMetadata: { contentType: "application/json" } });
          return;
        } catch {
          // 次の間隔へ
        }
      }
      console.error("catalog_journal_retry_failed", lib);
    })(),
  );
}

/** 409 で断った在る物も索引へ追記する。応答が届かずに送り直された物を一覧へ戻す。 */
export async function journalExisting(
  env: Env,
  lib: string,
  obj: { key: string; size: number; uploaded: Date; etag: string },
  ctx?: Pick<ExecutionContext, "waitUntil">,
): Promise<void> {
  await journalBestEffort(env, lib, { put: [rowOf(obj)], unthumb: [obj.key] }, ctx);
}

export const rowOf = (o: {
  key: string;
  size: number;
  uploaded: Date;
  etag: string;
}): CatalogRow => [o.key, o.size, o.uploaded.getTime(), o.etag];

/* ---------------- 作り直し ---------------- */

/** バケットを全部列挙する。`.system/` と `.trash/` は中へ入らずに飛ばす（サムネだけで本体と同じ数ある）。 */
async function enumerate(bucket: R2Bucket): Promise<CatalogRow[]> {
  const rows: CatalogRow[] = [];
  let cursor: string | undefined;
  let startAfter: string | undefined;
  for (;;) {
    const page = await bucket.list({
      limit: 1000,
      ...(cursor ? { cursor } : startAfter ? { startAfter } : {}),
    });
    let skipPast: string | undefined;
    for (const o of page.objects) {
      const reserved = RESERVED.find((p) => o.key.startsWith(p));
      if (reserved) {
        // その接頭辞のどの key よりも後ろになる位置から続きを取る
        skipPast = `${reserved}\u{10FFFF}`;
        continue;
      }
      skipPast = undefined;
      rows.push(rowOf(o));
    }
    if (!page.truncated) break;
    if (skipPast) {
      startAfter = skipPast;
      cursor = undefined;
    } else {
      cursor = page.cursor;
    }
  }
  return rows;
}

async function enumerateThumbs(env: Env, lib: string): Promise<Set<string>> {
  const prefix = thumbPrefix(lib);
  const out = new Set<string>();
  let cursor: string | undefined;
  do {
    const page = await env.META.list({ prefix, cursor, limit: 1000 });
    for (const o of page.objects) {
      if (o.key.endsWith(".webp")) out.add(o.key.slice(prefix.length, -".webp".length));
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return out;
}

async function listJournal(env: Env, lib: string): Promise<string[]> {
  const prefix = journalPrefix(lib);
  const keys: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.META.list({ prefix, cursor, limit: 1000 });
    for (const o of page.objects) keys.push(o.key);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return keys.sort();
}

async function rebuildOnce(env: Env, lib: string, bucket: R2Bucket): Promise<void> {
  const startedAt = Date.now();
  // 列挙の前に読んだ時点の etag を取る。列挙の間に別の作り直しが書いたなら、
  // それは新しい索引なので、古い索引で上書きしない（書き込みを etag 条件にする）
  const before = await env.META.head(snapshotKey(lib));
  const [rows, thumbs] = await Promise.all([enumerate(bucket), enumerateThumbs(env, lib)]);
  const file: SnapshotFile = {
    version: 1,
    startedAt,
    items: rows.map((r) => [r[0], r[1], r[2], r[3], thumbs.has(r[0]) ? 1 : 0]),
  };
  // 遅く終わった古い作り直しが、新しい索引を上書きしないようにする。時計が狂って
  // 「未来に作った」ことになっている索引には負けない（負けると二度と作り直せなくなる）
  const current = await env.META.head(snapshotKey(lib));
  const currentAt = Number(current?.customMetadata?.startedAt ?? 0);
  if (currentAt > startedAt && currentAt <= Date.now() + CLOCK_SKEW_MS) return;
  const wrote = await env.META.put(snapshotKey(lib), JSON.stringify(file), {
    httpMetadata: { contentType: "application/json" },
    customMetadata: { startedAt: String(startedAt) },
    onlyIf: before ? { etagMatches: before.etag } : { etagDoesNotMatch: "*" },
  });
  // 列挙の間に索引が差し替わっていたらその方が新しい。追記の掃除もやらない
  if (!wrote) return;
  // 索引に入った分の追記を消す。索引を書いた後に消すので、途中で落ちても追記が残るだけ
  const prefix = journalPrefix(lib);
  const old = (await listJournal(env, lib)).filter(
    (k) => journalTime(k, prefix) < startedAt - CLOCK_SKEW_MS,
  );
  for (let i = 0; i < old.length; i += 1000) await env.META.delete(old.slice(i, i + 1000));
}

/** 索引を作り直す。同じ isolate で重なった呼び出しは 1 回にまとめる。 */
export function rebuildCatalog(env: Env, lib: string, bucket: R2Bucket): Promise<void> {
  const running = rebuilding.get(lib);
  if (running) return running;
  const p = rebuildOnce(env, lib, bucket).finally(() => rebuilding.delete(lib));
  rebuilding.set(lib, p);
  return p;
}

/**
 * 応答の後に回す作り直し。古くなった瞬間に、受けた isolate の数だけ全件列挙が走るのを
 * 避けるため、始める前に目印を置き、新しい目印がある間は他の isolate は始めない。
 * 目印の確認と設置は厳密な排他ではない（同時に 2 つ走っても結果は同じ）。
 */
async function rebuildInBackground(env: Env, lib: string, bucket: R2Bucket): Promise<void> {
  if (rebuilding.has(lib)) return;
  const lease = await env.META.head(leaseKey(lib));
  const age = lease ? Date.now() - lease.uploaded.getTime() : Infinity;
  if (age >= 0 && age < REBUILD_LEASE_MS) return;
  await env.META.put(leaseKey(lib), "");
  await rebuildCatalog(env, lib, bucket);
}

/** 日次の cron から呼ぶ。直接 R2 に置かれた物を拾い、追記を畳む。 */
export async function rebuildAllCatalogs(env: Env): Promise<void> {
  for (const lib of libraries(env)) {
    const bucket = env[lib.binding] as R2Bucket | undefined;
    if (!bucket) continue;
    try {
      await rebuildCatalog(env, lib.id, bucket);
    } catch (e) {
      console.error("catalog_rebuild_failed", lib.id, e);
    }
  }
}

/* ---------------- 読み込み ---------------- */

function applyEntry(state: CatalogState, e: JournalEntry): void {
  for (const k of e.del ?? []) state.rows.delete(k);
  for (const r of e.put ?? []) state.rows.set(r[0], r);
  for (const k of e.unthumb ?? []) state.thumbs.delete(k);
  for (const k of e.thumb ?? []) state.thumbs.add(k);
}

async function fetchSnapshot(
  env: Env,
  lib: string,
  have: CatalogState | undefined,
): Promise<CatalogState | null> {
  const got = await env.META.get(
    snapshotKey(lib),
    have ? { onlyIf: { etagDoesNotMatch: have.etag } } : undefined,
  );
  if (!got) return null;
  // 条件に合わない（手元と同じ）時は中身なしで返る。5 万件の JSON を毎回読み直さない
  if (!("body" in got) || !got.body) return have ?? null;
  const file = await (got as R2ObjectBody).json<SnapshotFile>();
  const base = new Map<string, CatalogRow>();
  const baseThumbs = new Set<string>();
  for (const [key, size, uploaded, etag, thumb] of file.items ?? []) {
    base.set(key, [key, size, uploaded, etag]);
    if (thumb) baseThumbs.add(key);
  }
  return {
    etag: got.etag,
    startedAt: Number(file.startedAt) || 0,
    base,
    baseThumbs,
    rows: new Map(base),
    thumbs: new Set(baseThumbs),
    applied: [],
    views: new Map(),
    sizes: null,
  };
}

/**
 * [wanted] のうち手元に無い追記を読む。[listed] に無い物（畳まれた物）は手元からも捨てる。
 * 返すのは「一覧にあったのに本体が消えていた」追記。読む間に畳まれた印なので、
 * 呼び出し側は索引を取り直してやり直す
 */
async function loadJournalBodies(
  env: Env,
  wanted: string[],
  listed: string[],
): Promise<Set<string>> {
  const missing = wanted.filter((k) => !journalBodies.has(k));
  const gone = new Set<string>();
  // 同時に開ける接続には上限があるので、まとめて投げずに区切って読む
  for (let i = 0; i < missing.length; i += 24) {
    await Promise.all(
      missing.slice(i, i + 24).map(async (k) => {
        const obj = await env.META.get(k);
        if (!obj) gone.add(k);
        // 一覧の後に畳まれて消えた追記は、新しい索引に入っているので空として扱う
        journalBodies.set(k, obj ? await obj.json<JournalEntry>() : {});
      }),
    );
  }
  if (journalBodies.size > listed.length + 500) {
    const keep = new Set(listed);
    for (const k of journalBodies.keys()) if (!keep.has(k)) journalBodies.delete(k);
  }
  return gone;
}

type Composed = { state: CatalogState; journal: number };

/**
 * 索引に追記を当てた今の姿を作る。索引が無ければ null。追記が溜まりすぎていて
 * [allowBacklog] が false なら、読まずに "backlog" を返す（呼び出し側が先に畳む）。
 */
async function compose(
  env: Env,
  lib: string,
  allowBacklog = false,
): Promise<Composed | "backlog" | null> {
  const prefix = journalPrefix(lib);
  for (let round = 0; round < 3; round++) {
    // WHY: 追記の一覧を先に取ってから索引を取る。逆の順だと、索引を取った後に
    //      書き込まれた新しい追記と古い索引を組んで、上げた物が欠ける
    const listed = await listJournal(env, lib);
    let state = await fetchSnapshot(env, lib, mem.get(lib));
    if (!state) return null;
    const relevantOf = (s: CatalogState) =>
      listed.filter((k) => journalTime(k, prefix) >= s.startedAt - CLOCK_SKEW_MS);
    let relevant = relevantOf(state);
    // 当て済みの追記が一覧から消えていたら、畳まれた直後。新しい索引を取り直す
    if (state.applied.some((k) => !relevant.includes(k))) {
      const again = await fetchSnapshot(env, lib, state);
      if (again && again !== state) {
        state = again;
        relevant = relevantOf(state);
      }
    }
    if (relevant.length > JOURNAL_HARD_LIMIT && !allowBacklog) return "backlog";
    const isPrefix =
      state.applied.length <= relevant.length && state.applied.every((k, i) => relevant[i] === k);
    const todo = isPrefix ? relevant.slice(state.applied.length) : relevant;
    // 読むのは先に全部済ませる。同じ isolate の別のリクエストがこの state を使っているので、
    // await を挟んで少しずつ書き換えると、当てかけの一覧を相手に見せてしまう
    const gone = await loadJournalBodies(env, todo, listed);
    // 読む間に畳まれて消えた追記がある。索引が差し替わっているはずなので最初からやり直す
    if (gone.size && round < 2) {
      // 次の周回でもう一度本体を確かめる
      for (const k of gone) journalBodies.delete(k);
      continue;
    }
    if (!isPrefix) {
      // 途中に割り込む追記・消えた追記がある。索引から当て直す
      state.rows = new Map(state.base);
      state.thumbs = new Set(state.baseThumbs);
    }
    if (todo.length || !isPrefix) {
      for (const k of todo) applyEntry(state, journalBodies.get(k) ?? {});
      state.applied = relevant;
      state.views.clear();
      state.sizes = null;
    }
    mem.set(lib, state);
    return { state, journal: relevant.length };
  }
  return null;
}

export function sortPoint(sort: FolderSort, row: CatalogRow): SortPoint {
  switch (sort) {
    case "name":
      // アプリの名前順と同じく、末尾の名前を小文字にして比べる
      return { primary: (row[0].split("/").pop() ?? row[0]).toLowerCase(), key: row[0] };
    case "size":
      return { primary: row[1], key: row[0] };
    default:
      return { primary: row[2], key: row[0] };
  }
}

// 続きのカーソルは「この位置より後」を比較で探すため、並べる時と同じ比較を使う
export function compareFolderSort(sort: FolderSort, a: SortPoint, b: SortPoint): number {
  const dir = sort === "new" || sort === "size" ? -1 : 1;
  const p = a.primary < b.primary ? -1 : a.primary > b.primary ? 1 : 0;
  return p * dir || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
}

/** 並べ替え済みの一覧から、カーソルの位置より後の最初の番号を二分探索で返す */
export function indexAfter(sort: FolderSort, points: SortPoint[], at: SortPoint): number {
  let lo = 0;
  let hi = points.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (compareFolderSort(sort, points[mid]!, at) > 0) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

export function buildView(
  rows: Iterable<CatalogRow>,
  prefix: string,
  recursive: boolean,
  sort: FolderSort,
  type?: FolderType,
): FolderView {
  // 絞り込みは拡張子で決める。一覧が拾う拡張子の元は const.ts の media-ext.json
  const ext = type === "photo" ? IMAGE_EXT : type === "video" ? VIDEO_EXT : MEDIA_EXT;
  const folders = new Set<string>();
  const picked: { row: CatalogRow; point: SortPoint }[] = [];
  for (const row of rows) {
    const key = row[0];
    if (!key.startsWith(prefix)) continue;
    if (!recursive) {
      const slash = key.indexOf("/", prefix.length);
      if (slash >= 0) {
        folders.add(key.slice(0, slash + 1));
        continue;
      }
    }
    if (ext.test(key)) picked.push({ row, point: sortPoint(sort, row) });
  }
  picked.sort((a, b) => compareFolderSort(sort, a.point, b.point));
  return {
    files: picked.map((p) => p.row),
    points: picked.map((p) => p.point),
    folders: recursive ? [] : [...folders].sort(),
  };
}

function toCatalog(state: CatalogState): Catalog {
  return {
    startedAt: state.startedAt,
    rows: state.rows,
    hasThumb: (key) => state.thumbs.has(key),
    view(prefix, recursive, sort, type) {
      const id = `${recursive ? 1 : 0}\n${sort}\n${type ?? "all"}\n${prefix}`;
      const hit = state.views.get(id);
      if (hit) return hit;
      const made = buildView(state.rows.values(), prefix, recursive, sort, type);
      if (state.views.size >= VIEW_CACHE) {
        const oldest = state.views.keys().next().value;
        if (oldest !== undefined) state.views.delete(oldest);
      }
      state.views.set(id, made);
      return made;
    },
    bySize() {
      if (!state.sizes) {
        const sizes = new Map<number, CatalogRow[]>();
        for (const row of state.rows.values()) {
          if (!MEDIA_EXT.test(row[0])) continue;
          const list = sizes.get(row[1]);
          if (list) list.push(row);
          else sizes.set(row[1], [row]);
        }
        state.sizes = sizes;
      }
      return state.sizes;
    },
  };
}

export interface CatalogOptions {
  /** 作り直しを応答の後に回すための口。無ければ投げっぱなしにする */
  ctx?: Pick<ExecutionContext, "waitUntil">;
  /** 利用者が「引っ張って更新」した時。古ければ作り直してから返す */
  fresh?: boolean;
  /**
   * 索引がまだ無い時に、作るのを待たずに null を返す（作るのは裏に回す）。
   * 索引が無くても答えられる呼び出し（R2 に直接聞いた一覧のサムネの有無）で使う。
   */
  optional?: boolean;
}

// 「今すぐ最新を」と言われても、直前に作ったばかりなら作り直さない
const FRESH_MIN_INTERVAL_MS = 10_000;

/**
 * 索引を読む。無ければ作ってから返す。古ければ手元の物で返し、作り直しは裏で走らせる
 * （次の読み込みから新しい物になる）。CATALOG_MAX_AGE_SECONDS=0 は毎回作り直す。
 */
export async function loadCatalog(
  env: Env,
  lib: string,
  bucket: R2Bucket,
  opts: CatalogOptions & { optional: true },
): Promise<Catalog | null>;
export async function loadCatalog(
  env: Env,
  lib: string,
  bucket: R2Bucket,
  opts?: CatalogOptions,
): Promise<Catalog>;
export async function loadCatalog(
  env: Env,
  lib: string,
  bucket: R2Bucket,
  opts: CatalogOptions = {},
): Promise<Catalog | null> {
  const maxAge = maxAgeMs(env);
  const background = () => {
    const work = rebuildInBackground(env, lib, bucket).catch((e) =>
      console.error("catalog_rebuild_failed", lib, e),
    );
    if (opts.ctx) opts.ctx.waitUntil(work);
  };
  if (opts.optional) {
    try {
      const got = await compose(env, lib);
      if (!got || got === "backlog" || Date.now() - got.state.startedAt > maxAge) background();
      return got && got !== "backlog" ? toCatalog(got.state) : null;
    } catch (e) {
      console.error("catalog_unavailable", lib, e);
      return null;
    }
  }
  let composed = await compose(env, lib);
  if (composed === "backlog") {
    // WHY: 追記が上限を超えたまま一覧のたびに同期で全件畳み直すと、重い列挙が
    //      応答を塞いで「一括アップロードの後は何も見れない」状態になる。
    //      裏で畳ませて当て済みの索引を先に返す。追加分は畳みが済むと出る。
    //      一覧に出ない間も本体は消えていない
    background();
    const snap = await fetchSnapshot(env, lib, mem.get(lib));
    if (!snap) throw new Error("catalog_unavailable");
    mem.set(lib, snap);
    return toCatalog(snap);
  }
  const age = composed ? Date.now() - composed.state.startedAt : Infinity;
  if (!composed || maxAge === 0 || (opts.fresh === true && age > FRESH_MIN_INTERVAL_MS)) {
    await rebuildCatalog(env, lib, bucket);
    composed = (await compose(env, lib, true)) as Composed | null;
  } else if (age > maxAge || composed.journal > JOURNAL_COMPACT_AT) {
    background();
  }
  if (!composed) throw new Error("catalog_unavailable");
  return toCatalog(composed.state);
}
