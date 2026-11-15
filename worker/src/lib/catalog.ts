import { MEDIA_EXT, SYSTEM_PREFIX, TRASH_PREFIX } from "./const";
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
  view(prefix: string, recursive: boolean, sort: FolderSort): FolderView;
  /** 一覧に出る物（メディアの拡張子を持つ物）をサイズごとに束ねたもの */
  bySize(): ReadonlyMap<number, CatalogRow[]>;
}

const RESERVED = [SYSTEM_PREFIX, TRASH_PREFIX];
// 別々の isolate の時計のずれ。索引を作り始めた時刻より少し前の追記も重ねて当てる
// （追記は「その key の今の姿」なので、二度当てても結果は変わらない）
const CLOCK_SKEW_MS = 60_000;
const DEFAULT_MAX_AGE_S = 300;
// 追記が溜まると毎回の読み込みが重くなるので、この数を超えたら索引へ畳む
const JOURNAL_COMPACT_AT = 400;
const VIEW_CACHE = 6;

const snapshotKey = (lib: string) => `${SYSTEM_PREFIX}catalog/${lib}.json`;
const journalPrefix = (lib: string) => `${SYSTEM_PREFIX}catalog/${lib}/j/`;
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
export async function journalBestEffort(env: Env, lib: string, entry: JournalEntry): Promise<void> {
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
  const [rows, thumbs] = await Promise.all([enumerate(bucket), enumerateThumbs(env, lib)]);
  const file: SnapshotFile = {
    version: 1,
    startedAt,
    items: rows.map((r) => [r[0], r[1], r[2], r[3], thumbs.has(r[0]) ? 1 : 0]),
  };
  // 遅く終わった古い作り直しが、新しい索引を上書きしないようにする
  const current = await env.META.head(snapshotKey(lib));
  if (Number(current?.customMetadata?.startedAt ?? 0) > startedAt) return;
  await env.META.put(snapshotKey(lib), JSON.stringify(file), {
    httpMetadata: { contentType: "application/json" },
    customMetadata: { startedAt: String(startedAt) },
  });
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

async function loadJournalBodies(env: Env, keys: string[]): Promise<void> {
  const missing = keys.filter((k) => !journalBodies.has(k));
  await Promise.all(
    missing.map(async (k) => {
      const obj = await env.META.get(k);
      // 一覧の後に畳まれて消えた追記は、新しい索引に入っているので空として扱う
      journalBodies.set(k, obj ? await obj.json<JournalEntry>() : {});
    }),
  );
  if (journalBodies.size > keys.length + 2000) {
    const keep = new Set(keys);
    for (const k of journalBodies.keys()) if (!keep.has(k)) journalBodies.delete(k);
  }
}

async function compose(
  env: Env,
  lib: string,
): Promise<{ state: CatalogState; journal: number } | null> {
  const prefix = journalPrefix(lib);
  let [state, listed] = await Promise.all([
    fetchSnapshot(env, lib, mem.get(lib)),
    listJournal(env, lib),
  ]);
  if (!state) return null;
  const relevantOf = (s: CatalogState) =>
    listed.filter((k) => journalTime(k, prefix) >= s.startedAt - CLOCK_SKEW_MS);
  let relevant = relevantOf(state);
  // 当て済みの追記が一覧から消えていたら、畳まれた直後。新しい索引を取り直す
  if (state.applied.some((k) => !relevant.includes(k))) {
    const again = await fetchSnapshot(env, lib, state);
    if (again && again !== state) {
      state = again;
      listed = await listJournal(env, lib);
      relevant = relevantOf(state);
    }
  }
  const isPrefix =
    state.applied.length <= relevant.length && state.applied.every((k, i) => relevant[i] === k);
  if (!isPrefix) {
    // 途中に割り込む追記・消えた追記がある。索引から当て直す
    state.rows = new Map(state.base);
    state.thumbs = new Set(state.baseThumbs);
    state.applied = [];
    state.views.clear();
    state.sizes = null;
  }
  const todo = relevant.slice(state.applied.length);
  if (todo.length) {
    await loadJournalBodies(env, todo);
    for (const k of todo) applyEntry(state, journalBodies.get(k) ?? {});
    state.applied = relevant;
    state.views.clear();
    state.sizes = null;
  }
  mem.set(lib, state);
  return { state, journal: relevant.length };
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
): FolderView {
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
    if (MEDIA_EXT.test(key)) picked.push({ row, point: sortPoint(sort, row) });
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
    view(prefix, recursive, sort) {
      const id = `${recursive ? 1 : 0}\n${sort}\n${prefix}`;
      const hit = state.views.get(id);
      if (hit) return hit;
      const made = buildView(state.rows.values(), prefix, recursive, sort);
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
  opts: CatalogOptions = {},
): Promise<Catalog> {
  const maxAge = maxAgeMs(env);
  let composed = await compose(env, lib);
  const age = composed ? Date.now() - composed.state.startedAt : Infinity;
  const mustWait =
    !composed || maxAge === 0 || (opts.fresh === true && age > FRESH_MIN_INTERVAL_MS);
  if (mustWait) {
    await rebuildCatalog(env, lib, bucket);
    composed = await compose(env, lib);
  } else if (age > maxAge || composed!.journal > JOURNAL_COMPACT_AT) {
    const work = rebuildCatalog(env, lib, bucket).catch((e) =>
      console.error("catalog_rebuild_failed", lib, e),
    );
    if (opts.ctx) opts.ctx.waitUntil(work);
  }
  if (!composed) throw new Error("catalog_unavailable");
  return toCatalog(composed.state);
}
