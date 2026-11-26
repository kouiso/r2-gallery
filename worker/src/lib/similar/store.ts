import type { Catalog, CatalogRow } from "../catalog";
import { IMAGE_EXT, SYSTEM_PREFIX } from "../const";
import type { Env } from "../env";
import { validHash, type HashesFile } from "../hashes";
import { HttpError } from "../http";
import { decodeSig, FLAG_FLAT, PARAMS, SIG_BYTES } from "./core";

/**
 * 見た目の署名の置き場。META の `.system/similar/<lib>/<NN>.json`（NN = fnv1a32(key) % 32）。
 *
 * 1 ファイルにすると 5 万件で 25 MB になり、1 件足すたびに全部を書き直すことになる。
 * 32 に割ると 1 回の書き込みは 800 KB ほどで済み、読む側は etag の条件付きで 32 回読むだけになる。
 * 記録は key と etag の組に付く（ハッシュの記録と同じ考え方）。etag が変われば中身が変わったので無効。
 * ゴミ箱へ送っても記録は消さない。一覧に無い行は使わないだけで、単発 PUT の物は移動で戻しても
 * MD5 の etag が変わらないので、戻した時にそのまま有効に戻る。
 */

export const SHARDS = 32;

export type SigSrc = "t" | "o";
export type SigFail = "decode" | "too_large";
/** [etag, 署名(base64url), 元("t"=サムネ / "o"=原本), 元の幅, 元の高さ] か [etag, null, 失敗の印] */
export type ShardItem =
  | [etag: string, sig: string, src: SigSrc, ow: number, oh: number]
  | [etag: string, sig: null, fail: SigFail];

interface ShardFile {
  version: 1;
  alg: string;
  items: Record<string, unknown>;
}

// 記録の種類。列ごとの配列に 1 バイトで持つ
export const KIND_THUMB = 0;
export const KIND_ORIGINAL = 1;
export const KIND_DECODE = 2;
export const KIND_TOO_LARGE = 3;

/**
 * 読み込んだ 1 ファイルぶん。JSON のまま持つと 5 万件で isolate のメモリを食うので、
 * 読んだその場で列ごとの配列に移し、JSON は捨てる。
 */
export interface Shard {
  /** META 上のファイルの etag。ファイルが無ければ null */
  etag: string | null;
  count: number;
  keys: string[];
  etags: string[];
  kind: Uint8Array;
  ow: Uint32Array;
  oh: Uint32Array;
  /** 1 件 SIG_BYTES バイト。失敗の印の行は 0 埋め */
  sigs: Uint8Array;
  at: Map<string, number>;
}

/** 1 件の記録を取り出した形（数件だけ見る呼び出し向け） */
export interface SigRecord {
  etag: string;
  /** 失敗の印なら null */
  sig: Uint8Array | null;
  src: SigSrc | null;
  fail: SigFail | null;
  /** 原本の寸法。分からなければ 0 */
  ow: number;
  oh: number;
}

const shardPath = (lib: string, n: number) =>
  `${SYSTEM_PREFIX}similar/${lib}/${String(n).padStart(2, "0")}.json`;

// hashes.ts の置き場と同じ文字列。あちらは外へ出していないので写して持つ（変える時は両方）
const hashesPath = (lib: string) => `${SYSTEM_PREFIX}hashes-${lib}.json`;

const utf8 = new TextEncoder();

/** FNV-1a 32 bit（UTF-8 のバイト列に対して）。どの isolate でも同じ key は同じ置き場になる */
export function fnv1a32(s: string): number {
  let h = 0x811c9dc5;
  for (const b of utf8.encode(s)) {
    h ^= b;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

export const shardOf = (key: string): number => fnv1a32(key) % SHARDS;

/* ---------------- 読み込み ---------------- */

const isCount = (v: unknown): v is number =>
  typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= 0xffffffff;

/** 壊れた行は読まずに捨てる（手で直された・古い版の行で 500 にしない） */
function sanitize(raw: unknown): ShardItem | null {
  if (!Array.isArray(raw) || typeof raw[0] !== "string" || !raw[0]) return null;
  const [etag, sig, third] = raw as unknown[];
  if (sig === null) {
    return third === "decode" || third === "too_large" ? [etag as string, null, third] : null;
  }
  if (typeof sig !== "string" || (third !== "t" && third !== "o")) return null;
  if (!decodeSig(sig)) return null;
  const ow = isCount(raw[3]) ? raw[3] : 0;
  const oh = isCount(raw[4]) ? raw[4] : 0;
  return [etag as string, sig, third, ow, oh];
}

function parseFile(text: string | null): Record<string, ShardItem> {
  if (!text) return {};
  let file: ShardFile;
  try {
    file = JSON.parse(text) as ShardFile;
  } catch {
    return {};
  }
  // 算法の版が違うファイルは空として扱う。古い署名と比べると判定がでたらめになる
  if (!file || file.version !== 1 || file.alg !== PARAMS.alg || typeof file.items !== "object") {
    return {};
  }
  const out: Record<string, ShardItem> = {};
  for (const [key, raw] of Object.entries(file.items ?? {})) {
    const item = sanitize(raw);
    if (item) out[key] = item;
  }
  return out;
}

function toShard(items: Record<string, ShardItem>, etag: string | null): Shard {
  const keys = Object.keys(items);
  const count = keys.length;
  const shard: Shard = {
    etag,
    count,
    keys,
    etags: new Array<string>(count),
    kind: new Uint8Array(count),
    ow: new Uint32Array(count),
    oh: new Uint32Array(count),
    sigs: new Uint8Array(count * SIG_BYTES),
    at: new Map(),
  };
  keys.forEach((key, i) => {
    const item = items[key]!;
    shard.etags[i] = item[0];
    shard.at.set(key, i);
    if (item[1] === null) {
      shard.kind[i] = item[2] === "too_large" ? KIND_TOO_LARGE : KIND_DECODE;
      return;
    }
    shard.kind[i] = item[2] === "o" ? KIND_ORIGINAL : KIND_THUMB;
    shard.ow[i] = item[3];
    shard.oh[i] = item[4];
    // sanitize で確かめ済みなので null にはならない
    shard.sigs.set(decodeSig(item[1])!, i * SIG_BYTES);
  });
  return shard;
}

const emptyShard = (etag: string | null): Shard => toShard({}, etag);

const shardMem = new Map<string, Shard>();
const hashesMem = new Map<string, { etag: string; data: HashesFile }>();

/** テスト用: isolate が持つ写しを捨てる */
export function resetSimilarStoreMemory(): void {
  shardMem.clear();
  hashesMem.clear();
}

/**
 * 1 ファイルを読む。手元の写しと etag が同じなら中身を受け取らない（32 ファイルを毎回読み直さない）。
 */
export async function loadShard(env: Env, lib: string, n: number): Promise<Shard> {
  const id = `${lib}\n${n}`;
  const have = shardMem.get(id);
  const got = await env.META.get(
    shardPath(lib, n),
    have?.etag ? { onlyIf: { etagDoesNotMatch: have.etag } } : undefined,
  );
  if (!got) {
    const empty = emptyShard(null);
    shardMem.set(id, empty);
    return empty;
  }
  // 条件に合わない（手元と同じ）時は中身なしで返る
  if (!("body" in got) || !got.body) return have ?? emptyShard(got.etag);
  const shard = toShard(parseFile(await (got as R2ObjectBody).text()), got.etag);
  shardMem.set(id, shard);
  return shard;
}

/** 32 ファイルを全部読む。JSON は 1 ファイルずつ届いた順に列の配列へ移すので、大きな JSON が同時に残らない */
export function loadAllShards(env: Env, lib: string): Promise<Shard[]> {
  return Promise.all(Array.from({ length: SHARDS }, (_, n) => loadShard(env, lib, n)));
}

/**
 * 一覧の行に対して有効な記録の番号を返す（無ければ -1）。有効なのは、一覧に在り、etag が同じで、
 * 画像の拡張子を持つ物だけ。
 */
export function validIndex(shard: Shard, row: CatalogRow | undefined): number {
  if (!row || !IMAGE_EXT.test(row[0])) return -1;
  const i = shard.at.get(row[0]);
  return i !== undefined && shard.etags[i] === row[3] ? i : -1;
}

export const isFailKind = (kind: number) => kind === KIND_DECODE || kind === KIND_TOO_LARGE;

/** 有効な署名の行が単色か。失敗の印の行は false */
export function isFlatAt(shard: Shard, i: number): boolean {
  return (
    !isFailKind(shard.kind[i]!) && (shard.sigs[i * SIG_BYTES + SIG_BYTES - 1]! & FLAG_FLAT) !== 0
  );
}

/** i 行目の署名（失敗の印なら null）。表の中を指すだけで写さない */
export function sigAtRow(shard: Shard, i: number): Uint8Array | null {
  return isFailKind(shard.kind[i]!)
    ? null
    : shard.sigs.subarray(i * SIG_BYTES, (i + 1) * SIG_BYTES);
}

export function recordAt(shard: Shard, i: number): SigRecord {
  const kind = shard.kind[i]!;
  const fail = isFailKind(kind);
  return {
    etag: shard.etags[i]!,
    sig: fail ? null : shard.sigs.slice(i * SIG_BYTES, (i + 1) * SIG_BYTES),
    src: fail ? null : kind === KIND_ORIGINAL ? "o" : "t",
    fail: kind === KIND_DECODE ? "decode" : kind === KIND_TOO_LARGE ? "too_large" : null,
    ow: shard.ow[i]!,
    oh: shard.oh[i]!,
  };
}

/**
 * 1 件の記録を読む（etag は確かめない。呼び出し側が head した etag と比べる）。
 * まとめてゴミ箱へ送る時の「署名が今の中身の物か」の確認に使う。
 */
export async function loadRecord(env: Env, lib: string, key: string): Promise<SigRecord | null> {
  const shard = await loadShard(env, lib, shardOf(key));
  const i = shard.at.get(key);
  return i === undefined ? null : recordAt(shard, i);
}

/* ---------------- 書き込み ---------------- */

/**
 * etag の条件付きで 1 ファイルを書き直す。負けたら読み直してやり直す（アルバム・ハッシュの保存と同じ型）。
 * 書くたびに、一覧に無い・etag が合わない・画像でない・置き場違いの行を落とす（ファイルを太らせない）。
 * mutate が false を返し、落とす行も無ければ書かない。
 */
export async function mutateShard(
  env: Env,
  lib: string,
  n: number,
  mutate: (items: Record<string, ShardItem>) => boolean | void,
  catalog: Catalog,
): Promise<Shard> {
  const path = shardPath(lib, n);
  for (let attempt = 0; attempt < 8; attempt++) {
    const obj = await env.META.get(path);
    const items = parseFile(obj ? await obj.text() : null);
    const changed = mutate(items) !== false;
    let pruned = false;
    for (const key of Object.keys(items)) {
      const row = catalog.rows.get(key);
      if (row && row[3] === items[key]![0] && IMAGE_EXT.test(key) && shardOf(key) === n) continue;
      delete items[key];
      pruned = true;
    }
    if (!changed && !pruned) {
      const shard = toShard(items, obj?.etag ?? null);
      shardMem.set(`${lib}\n${n}`, shard);
      return shard;
    }
    const file = { version: 1, alg: PARAMS.alg, items };
    const put = await env.META.put(path, JSON.stringify(file), {
      httpMetadata: { contentType: "application/json" },
      onlyIf: new Headers(obj ? { "if-match": `"${obj.etag}"` } : { "if-none-match": "*" }),
    });
    if (put) {
      // 書いた中身をそのまま写しにする。次の読み込みが同じ 800 KB を取り直さない
      const shard = toShard(items, put.etag);
      shardMem.set(`${lib}\n${n}`, shard);
      return shard;
    }
  }
  throw new HttpError(503, "similar_store_contended");
}

/* ---------------- 同じ中身の物の署名 ---------------- */

/** 古い順（一覧の残す物の初期値と同じ並び） */
const oldestRow = (a: CatalogRow, b: CatalogRow) => a[2] - b[2] || (a[0] < b[0] ? -1 : 1);

/**
 * row と SHA-256 が同じ物（row 自身を含む）を古い順に返す。中身の記録が無ければ row だけ。
 * row は head で見た今の行でもよい（一覧の同じ key の行と入れ替える）。
 */
export function exactRows(row: CatalogRow, catalog: Catalog, hashes: HashesFile): CatalogRow[] {
  const sha = validHash(hashes, row);
  if (!sha) return [row];
  const same = (catalog.bySize().get(row[1]) ?? []).filter(
    (r) => r[0] !== row[0] && validHash(hashes, r) === sha,
  );
  return [row, ...same].sort(oldestRow);
}

export interface SigSide {
  sig: Uint8Array | null;
  ow: number;
  oh: number;
}

/**
 * 同じ中身の物の集まりが使う署名と寸法。一覧（GET /similar）は集まりを 1 つの節にして、古い順で
 * 最初の単色でない有効な署名を使う。ゴミ箱・付け直しで比べ直す時も同じ署名を使わないと、
 * 一覧で「ほぼ同じ」と出た物が消す時に stale_signature や not_similar になり、読み直しても同じ組が
 * 出て終わらない（古い写しはサムネが無く署名が無い、など）。寸法は分かっている一員の物を使う。
 * rows は古い順。単色の署名しか無ければそれを返す（比べると「似ていない」になる）。
 */
export function exactSide(
  rows: readonly CatalogRow[],
  shardFor: (key: string) => Shard | undefined,
): SigSide {
  let sig: Uint8Array | null = null;
  let flat: Uint8Array | null = null;
  let ow = 0;
  let oh = 0;
  for (const r of rows) {
    const shard = shardFor(r[0]);
    const i = shard ? validIndex(shard, r) : -1;
    if (!shard || i < 0 || isFailKind(shard.kind[i]!)) continue;
    if (!ow && shard.ow[i]! > 0 && shard.oh[i]! > 0) {
      ow = shard.ow[i]!;
      oh = shard.oh[i]!;
    }
    if (sig) continue;
    if (!isFlatAt(shard, i)) sig = sigAtRow(shard, i);
    else flat ??= sigAtRow(shard, i);
  }
  return { sig: sig ?? flat, ow, oh };
}

/* ---------------- ハッシュの記録（読むだけ） ---------------- */

/**
 * SHA-256 の記録を etag 付きで読む。5 万件だと数 MB の JSON なので、etag が同じなら手元の写しを使う。
 * 返す中身は共有なので書き換えないこと（書くのは hashes.ts の mutateHashes だけ）。
 */
export async function loadHashesCached(
  env: Env,
  lib: string,
): Promise<{ etag: string; data: HashesFile }> {
  const have = hashesMem.get(lib);
  const got = await env.META.get(
    hashesPath(lib),
    have ? { onlyIf: { etagDoesNotMatch: have.etag } } : undefined,
  );
  if (!got) {
    hashesMem.delete(lib);
    return { etag: "", data: { version: 1, items: {} } };
  }
  // 条件に合わない（手元と同じ）時は中身なしで返る。条件は手元に写しがある時しか付けない
  if (have && (!("body" in got) || !got.body)) return have;
  return remember(lib, got.etag, await (got as R2ObjectBody).json<HashesFile>());
}

function remember(lib: string, etag: string, data: HashesFile) {
  data.items ??= {};
  const entry = { etag, data };
  hashesMem.set(lib, entry);
  return entry;
}
