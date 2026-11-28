import { HttpError } from "./http";

export interface Env {
  [binding: string]: unknown;
  /** Bucket used for index files and thumbnails (under `.system/`). */
  META: R2Bucket;
  /** JSON: [{"id":"a","binding":"LIB_A","title":"Library A","readOnly":true}, ...] */
  LIBRARIES: string;
  ACCESS_TOKEN: string;
  SIGNING_SECRET: string;
  URL_TTL_SECONDS?: string;
  TRASH_RETENTION_DAYS?: string;
  /** Objects larger than this are copied via multipart upload (default 96 MiB). */
  MULTIPART_COPY_MIN_BYTES?: string;
  /** Part size for multipart copies; must stay >= 5 MiB (default 64 MiB). */
  MULTIPART_COPY_PART_BYTES?: string;
  /** Max bytes fetched by URL import (default 50 MiB). */
  IMPORT_MAX_BYTES?: string;
  /** Test hook: allow imports from private/loopback hosts ("1"). */
  IMPORT_ALLOW_PRIVATE?: string;
  /**
   * テスト用: アルバムの跡を確かめる外部呼び出しの上限を下げる（既定 150、まとめてゴミ箱は 80。
   * 上げることはできない）。テストで数千件の跡を置かずに打ち切りを確かめるために使う
   */
  TRASH_PROBE_BUDGET?: string;
  /**
   * 一覧の索引をこの秒数より古いと見なしたら裏で作り直す（既定 300）。
   * "0" は毎回作り直してから返す（索引が合わない時の逃げ道。5 万件あると遅い）。
   */
  CATALOG_MAX_AGE_SECONDS?: string;
  /** 索引への追記が失敗した時に応答の後で書き直す間隔（ミリ秒、カンマ区切り。既定 "1000,5000,30000"）。 */
  JOURNAL_RETRY_AFTER_MS?: string;
  /** 重複の確認で 1 回の呼び出しが読む量の目安（既定 96 MiB）。 */
  DUP_SCAN_BYTES?: string;
  /** 重複の確認で 1 回の呼び出しが読む件数の上限（既定 200、最大 400）。 */
  DUP_SCAN_OBJECTS?: string;
  /** これより大きい物は重複の確認で中身を計算しない（既定 1 GiB）。 */
  DUP_MAX_OBJECT_BYTES?: string;
  /**
   * 似ている写真を見られるライブラリの画像の数の上限（既定 40000）。束ねる節の数もこれを超えない。
   * 超えると GET /similar は署名を読む前に 413 too_many_for_similar で断り、/similar/status は
   * tooMany: true を返す（アプリは署名を作り始めずに従来の重複の画面へ替える）。PC ツールは手元で束ねる。
   * 署名を全部読んで束ねるので、これより大きいライブラリは Worker のメモリ（128 MB）に収まらない。
   * 測った値（一覧・32 の置き場・ハッシュの記録・groupNodes の中の山の合計。読み込み途中の JSON は除く）:
   * 4 万件で約 75 MB、5 万件で約 93 MB（tools/similar-model-memory.test.mjs が既定の上限で確かめる。
   * 予算は 96 MB）。上げる時は先に測ること。
   */
  SIMILAR_MAX_NODES?: string;
  /** POST /similar/signatures の 1 回の件数の上限（既定 200、最大 200。原本の先頭を 1 件ずつ読むので外部呼び出しの上限に効く）。 */
  SIMILAR_SIG_BATCH?: string;
  /** POST /similar/trash の 1 回の件数の上限（既定 40、最大 40。1 件あたり約 12 回の外部呼び出しを使う）。 */
  SIMILAR_TRASH_BATCH?: string;
  /** Cloudflare Images の binding。無い環境では JPEG の写しを作らない。 */
  IMAGES?: unknown;
  /** Optional read-only D1 binding holding per-object review rows. */
  REVIEW_DB?: D1Database;
  /** Comma-separated library ids allowed to join objects to REVIEW_DB rows. */
  REVIEW_LIBS?: string;
}

export interface LibraryConfig {
  id: string;
  binding: string;
  title: string;
  readOnly?: boolean;
}

export function libraries(env: Env): LibraryConfig[] {
  try {
    const parsed = JSON.parse(env.LIBRARIES || "[]") as LibraryConfig[];
    return parsed.filter((l) => typeof l.id === "string" && typeof l.binding === "string");
  } catch {
    return [];
  }
}

export function bucketFor(
  env: Env,
  libId: string,
): { lib: LibraryConfig; bucket: R2Bucket } | null {
  const lib = libraries(env).find((l) => l.id === libId);
  const bucket = lib ? (env[lib.binding] as R2Bucket | undefined) : undefined;
  return lib && bucket ? { lib, bucket } : null;
}

export function writable(env: Env, libId: unknown): { lib: LibraryConfig; bucket: R2Bucket } {
  const t = typeof libId === "string" ? bucketFor(env, libId) : null;
  if (!t) throw new HttpError(404, "unknown_library");
  if (t.lib.readOnly) throw new HttpError(403, "read_only_library");
  return t;
}

export interface SimilarLimits {
  maxNodes: number;
  sigBatch: number;
  trashBatch: number;
}

/**
 * SIMILAR_* の値を読む。壊れた値・0 以下は既定に戻し、件数の上限は最大値で頭打ちにする
 * （設定で上限を上げると 1 リクエストの外部呼び出しの上限 1000 回を超えて落ちる）。
 */
export function similarLimits(env: Env): SimilarLimits {
  const num = (raw: string | undefined, fallback: number) => {
    const n = Number(raw);
    return raw !== undefined && raw !== "" && Number.isInteger(n) && n > 0 ? n : fallback;
  };
  return {
    maxNodes: num(env.SIMILAR_MAX_NODES, 40_000),
    sigBatch: Math.min(200, num(env.SIMILAR_SIG_BATCH, 200)),
    trashBatch: Math.min(40, num(env.SIMILAR_TRASH_BATCH, 40)),
  };
}

export function readable(env: Env, libId: unknown): { lib: LibraryConfig; bucket: R2Bucket } {
  const t = typeof libId === "string" ? bucketFor(env, libId) : null;
  if (!t) throw new HttpError(404, "unknown_library");
  return t;
}
