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

export function readable(env: Env, libId: unknown): { lib: LibraryConfig; bucket: R2Bucket } {
  const t = typeof libId === "string" ? bucketFor(env, libId) : null;
  if (!t) throw new HttpError(404, "unknown_library");
  return t;
}
