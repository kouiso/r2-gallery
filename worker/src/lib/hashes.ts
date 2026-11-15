import type { Catalog, CatalogRow } from "./catalog";
import { SYSTEM_PREFIX } from "./const";
import type { Env } from "./env";

/**
 * 中身のハッシュ(SHA-256)の置き場。META の `.system/hashes-<lib>.json`。
 *
 * オブジェクトのメタデータには置かない: 既にある物へ後から足すには書き直しが要り、
 * 書き直すと uploaded が変わって一覧の並びが崩れる。
 * 記録は key と etag の組に付く。上書きを許さない作りなので、key と etag が同じなら中身も同じ。
 */
export interface HashRecord {
  size: number;
  etag: string;
  sha256: string;
}

export interface HashesFile {
  version: 1;
  items: Record<string, HashRecord>;
}

const hashesPath = (lib: string) => `${SYSTEM_PREFIX}hashes-${lib}.json`;
const SHA256_HEX = /^[0-9a-f]{64}$/;

export const isSha256Hex = (v: unknown): v is string => typeof v === "string" && SHA256_HEX.test(v);

const hex = (buf: ArrayBuffer): string =>
  [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

export async function sha256OfBytes(data: ArrayBuffer | Uint8Array): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", data));
}

/** R2 の中身をストリームのまま読んで SHA-256 を返す。大きい動画をメモリに載せない。 */
export async function sha256OfObject(
  bucket: R2Bucket,
  key: string,
): Promise<{ sha256: string; size: number; etag: string } | null> {
  const obj = await bucket.get(key);
  if (!obj) return null;
  const digest = new crypto.DigestStream("SHA-256");
  await obj.body.pipeTo(digest);
  return { sha256: hex(await digest.digest), size: obj.size, etag: obj.etag };
}

// アルバムと違い、この一覧は利用者の操作ではなく計算結果。isolate に持つと別の isolate が
// 足した記録を潰すので、毎回読む
export async function loadHashes(env: Env, lib: string): Promise<HashesFile> {
  const obj = await env.META.get(hashesPath(lib));
  const data: HashesFile = obj ? await obj.json<HashesFile>() : { version: 1, items: {} };
  data.items ??= {};
  return data;
}

/** etag の条件付きで書く。負けたら読み直してやり直す（アルバムの保存と同じ型）。 */
export async function mutateHashes(
  env: Env,
  lib: string,
  mutate: (data: HashesFile) => boolean | void,
): Promise<HashesFile> {
  const path = hashesPath(lib);
  for (let attempt = 0; attempt < 8; attempt++) {
    const obj = await env.META.get(path);
    const data: HashesFile = obj ? await obj.json<HashesFile>() : { version: 1, items: {} };
    data.items ??= {};
    // 変える物が無ければ書かない（ゴミ箱へ送るたびにファイルを書き直さない）
    if (mutate(data) === false) return data;
    const put = await env.META.put(path, JSON.stringify(data), {
      httpMetadata: { contentType: "application/json" },
      onlyIf: new Headers(obj ? { "if-match": `"${obj.etag}"` } : { "if-none-match": "*" }),
    });
    if (put) return data;
  }
  throw new Error("hashes_store_contended");
}

/**
 * アップロードが成功した後の記録。失敗を 5xx にすると、保存済みなのにアプリがやり直して
 * 409 になり「名前 (2)」で二重保存される。なので握りつぶして記録だけ残す。
 */
export async function recordHashBestEffort(
  env: Env,
  lib: string,
  key: string,
  rec: HashRecord,
): Promise<void> {
  try {
    await mutateHashes(env, lib, (d) => {
      d.items[key] = rec;
    });
  } catch (e) {
    console.error("hash_record_failed", lib, key, e);
  }
}

export async function dropHashBestEffort(env: Env, lib: string, key: string): Promise<void> {
  try {
    await mutateHashes(env, lib, (d) => {
      if (!(key in d.items)) return false;
      delete d.items[key];
    });
  } catch (e) {
    console.error("hash_drop_failed", lib, key, e);
  }
}

/** 今ある物と etag・サイズが合う記録だけを有効とする。合わない記録は古い中身の物。 */
export function validHash(hashes: HashesFile, row: CatalogRow): string | null {
  const rec = hashes.items[row[0]];
  return rec && rec.etag === row[3] && rec.size === row[1] ? rec.sha256 : null;
}

const PLAIN_MD5 = /^[0-9a-f]{32}$/;

/**
 * サイズが同じ物の束のうち、SHA-256 を比べる必要がある物を返す。
 *
 * 単発 PUT の etag は中身の MD5 なので、etag が違う 2 つは中身も違う。5 万件あると
 * たまたま同じサイズになる別の写真が数百組あり、全部読んで計算すると何 GB にもなる。
 * 「同じ」と決めるのは SHA-256 のまま、違うと分かる物だけを先に外す。
 * 複数パートで上げた物の etag は MD5 ではないので、束に 1 つでもあれば全員を比べる。
 */
export function needsHash(group: CatalogRow[]): CatalogRow[] {
  if (group.length < 2) return [];
  if (group.some((r) => !PLAIN_MD5.test(r[3]))) return group;
  const count = new Map<string, number>();
  for (const r of group) count.set(r[3], (count.get(r[3]) ?? 0) + 1);
  return group.filter((r) => (count.get(r[3]) ?? 0) > 1);
}

export interface HashBudget {
  /** 1 回の呼び出しで読む量の目安。超えた所で止め、残りは次の呼び出しに回す */
  bytes: number;
  /** これより大きい物は計算しない（Worker の CPU 時間に収まらない） */
  maxObjectBytes: number;
}

export function hashBudget(env: Env): HashBudget {
  const num = (raw: string | undefined, fallback: number) => {
    const n = Number(raw);
    return raw !== undefined && raw !== "" && Number.isFinite(n) && n > 0 ? n : fallback;
  };
  return {
    bytes: num(env.DUP_SCAN_BYTES, 96 * 1024 * 1024),
    maxObjectBytes: num(env.DUP_MAX_OBJECT_BYTES, 1024 * 1024 * 1024),
  };
}

export interface EnsureResult {
  /** key → sha256（有効な記録がある物・今計算した物） */
  known: Map<string, string>;
  hashed: number;
  /** 予算切れで計算できなかった数 */
  pending: number;
  /** 大きすぎて計算しない数 */
  skipped: number;
}

/**
 * 渡された物のうち、有効な記録が無い物を計算して記録する。小さい物から進める
 * （大きい動画 1 本で予算を使い切って、写真が 1 枚も進まないのを避ける）。
 */
export async function ensureHashes(
  env: Env,
  lib: string,
  bucket: R2Bucket,
  rows: CatalogRow[],
  budget: HashBudget,
): Promise<EnsureResult> {
  const hashes = await loadHashes(env, lib);
  const known = new Map<string, string>();
  const todo: CatalogRow[] = [];
  let skipped = 0;
  for (const row of rows) {
    const have = validHash(hashes, row);
    if (have) known.set(row[0], have);
    else if (row[1] > budget.maxObjectBytes) skipped++;
    else todo.push(row);
  }
  todo.sort((a, b) => a[1] - b[1]);
  const picked: CatalogRow[] = [];
  let bytes = 0;
  for (const row of todo) {
    if (picked.length && bytes + row[1] > budget.bytes) break;
    picked.push(row);
    bytes += row[1];
  }
  const fresh = new Map<string, HashRecord>();
  // 同時に開ける接続に上限があるので 4 本ずつ読む
  for (let i = 0; i < picked.length; i += 4) {
    await Promise.all(
      picked.slice(i, i + 4).map(async (row) => {
        const got = await sha256OfObject(bucket, row[0]);
        // 一覧の後に消えた・入れ替わった物は記録しない（次の一覧で改めて見る）
        if (!got || got.etag !== row[3]) return;
        fresh.set(row[0], { size: got.size, etag: got.etag, sha256: got.sha256 });
        known.set(row[0], got.sha256);
      }),
    );
  }
  if (fresh.size) {
    try {
      await mutateHashes(env, lib, (d) => {
        for (const [k, rec] of fresh) d.items[k] = rec;
      });
    } catch (e) {
      // 記録できなくても今回の答えは出せる。次回また計算するだけ
      console.error("hash_record_failed", lib, e);
    }
  }
  return { known, hashed: fresh.size, pending: todo.length - picked.length, skipped };
}

export interface DuplicateGroup {
  sha256: string;
  size: number;
  rows: CatalogRow[];
}

export interface DuplicateScanState {
  groups: DuplicateGroup[];
  /** 比べる必要があるのに、まだ計算していない物 */
  pending: CatalogRow[];
  skipped: number;
}

/** 記録済みのハッシュから重複の束を作る。計算はしない。 */
export function duplicateState(
  catalog: Catalog,
  hashes: HashesFile,
  maxObjectBytes: number,
): DuplicateScanState {
  const groups: DuplicateGroup[] = [];
  const pending: CatalogRow[] = [];
  let skipped = 0;
  for (const [size, sameSize] of catalog.bySize()) {
    const bySha = new Map<string, CatalogRow[]>();
    for (const row of needsHash(sameSize)) {
      const sha = validHash(hashes, row);
      if (!sha) {
        if (size > maxObjectBytes) skipped++;
        else pending.push(row);
        continue;
      }
      const list = bySha.get(sha);
      if (list) list.push(row);
      else bySha.set(sha, [row]);
    }
    for (const [sha256, rows] of bySha) {
      if (rows.length < 2) continue;
      // 古い物を先頭に置く。先頭が「残す」の初期値になる
      rows.sort((a, b) => a[2] - b[2] || (a[0] < b[0] ? -1 : 1));
      groups.push({ sha256, size, rows });
    }
  }
  const reclaim = (g: DuplicateGroup) => (g.rows.length - 1) * g.size;
  groups.sort((a, b) => reclaim(b) - reclaim(a) || (a.sha256 < b.sha256 ? -1 : 1));
  return { groups, pending, skipped };
}
