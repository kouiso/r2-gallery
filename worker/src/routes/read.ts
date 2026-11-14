import { MEDIA_EXT, OTHER_ALBUM_ID, SYSTEM_PREFIX, TRASH_PREFIX } from "../lib/const";
import type { Env } from "../lib/env";
import { bucketFor, libraries, writable } from "../lib/env";
import { assertUserKey, json } from "../lib/http";
import { trashRetentionDays } from "../lib/objects";
import { loadAlbums, loadIndex, mediaFor, otherAlbum } from "../lib/store";
import type { GlobalAlbum, GlobalAlbumItem, IndexAlbum } from "../lib/store";
import { signedUrl } from "../lib/sign";

export function handleLibraries(env: Env): Response {
  return json({
    libraries: libraries(env).map((l) => ({
      id: l.id,
      title: l.title,
      readOnly: !!l.readOnly,
    })),
  });
}

/* ---------------- Review metadata (optional D1 join, read-only) ---------------- */

interface ReviewRow {
  id: number;
  verdict: string;
  round: number;
  label: string;
  intent_comment: string | null;
  director_score: number | null;
  director_comment: string | null;
  created_at: number;
}

interface CriterionRow {
  criterion_key: string;
  weight: number;
  panel_score: number | null;
  director_score: number | null;
  is_veto: number;
  comment: string | null;
}

/**
 * Join an object key to the latest review row stored in D1. Only libraries
 * listed in REVIEW_LIBS may be joined — review data belongs to the bucket it
 * was recorded against, and other libraries must never see it. Read-only:
 * SELECT statements only, never a mutation.
 */
export async function handleMeta(env: Env, libId: string, url: URL): Promise<Response> {
  if (!bucketFor(env, libId)) return json({ error: "unknown_library" }, 404);
  const key = assertUserKey(url.searchParams.get("key"));
  const db = env.REVIEW_DB;
  const allowed = (env.REVIEW_LIBS ?? "")
    .split(",")
    .map((s) => s.trim())
    .includes(libId);
  if (!db || !allowed) return json({ meta: null });
  const review = await db
    .prepare(
      `SELECT id, verdict, round, label, intent_comment, director_score, director_comment, created_at
         FROM image_review WHERE r2_key = ?1 ORDER BY id DESC LIMIT 1`,
    )
    .bind(key)
    .first<ReviewRow>();
  if (!review) return json({ meta: null });
  const { results: criteria } = await db
    .prepare(
      `SELECT criterion_key, weight, panel_score, director_score, is_veto, comment
         FROM image_review_criterion WHERE review_id = ?1 ORDER BY id`,
    )
    .bind(review.id)
    .all<CriterionRow>();
  return json({
    meta: {
      verdict: review.verdict,
      round: review.round,
      label: review.label,
      intentComment: review.intent_comment,
      directorScore: review.director_score,
      directorComment: review.director_comment,
      createdAt: review.created_at,
      criteria: (criteria ?? []).map((c) => ({
        key: c.criterion_key,
        weight: c.weight,
        panelScore: c.panel_score,
        directorScore: c.director_score,
        veto: !!c.is_veto,
        comment: c.comment,
      })),
    },
  });
}

export async function handleTrashList(
  bucket: R2Bucket,
  url: URL,
  retentionDays: number,
): Promise<Response> {
  const cursor = url.searchParams.get("cursor") ?? undefined;
  const listed = await bucket.list({ prefix: TRASH_PREFIX, cursor, limit: 200 });
  return json({
    items: listed.objects.map((o) => {
      const m = /^\.trash\/(\d+)\/(.+)$/.exec(o.key);
      return {
        trashKey: o.key,
        key: m?.[2] ?? o.key,
        deletedAt: Number(m?.[1] ?? 0),
        size: o.size,
      };
    }),
    cursor: listed.truncated ? listed.cursor : null,
    // 画面の「何日で自動削除」を Worker の実際の設定と食い違わせないため一緒に返す
    retentionDays,
  });
}

export function handleTrashListForLib(env: Env, libId: string, url: URL): Promise<Response> {
  return handleTrashList(writable(env, libId).bucket, url, trashRetentionDays(env));
}

export async function handleAlbums(env: Env, origin: string, lib: string): Promise<Response> {
  if (!bucketFor(env, lib)) return json({ error: "unknown_library" }, 404);
  // User albums live in the shared store (an item carries its own lib).
  // Pipeline-generated index.albums and the per-library "other" virtual album
  // are appended read-only: they can't take user items or lose them.
  const [shared, index] = await Promise.all([loadAlbums(env), loadIndex(env, lib)]);
  const other = otherAlbum(index);
  const all = [
    ...shared.albums.map((a) => ({ a, readOnly: false })),
    ...index.albums.map((a) => ({ a, readOnly: true })),
    ...(other ? [{ a: other, readOnly: true }] : []),
  ];
  const albums = await Promise.all(
    all.map(async ({ a, readOnly }) => {
      // Pipeline albums may pin a cover item; fall back to the first item.
      const coverItem =
        ("cover" in a && a.cover ? a.items.find((i) => i.key === a.cover) : undefined) ??
        a.items[0];
      const coverKey = coverItem?.thumb ?? coverItem?.key;
      const coverLib = (coverItem as GlobalAlbumItem | undefined)?.lib ?? lib;
      return {
        id: a.id,
        title: a.title,
        subtitle: a.subtitle ?? null,
        count: a.items.length,
        readOnly,
        coverUrl:
          coverItem && coverKey ? await signedUrl(env, origin, "t", coverLib, coverKey) : null,
      };
    }),
  );
  return json({ generatedAt: shared.generatedAt ?? null, albums });
}

export async function handleAlbum(
  env: Env,
  origin: string,
  lib: string,
  id: string,
  url: URL,
): Promise<Response> {
  if (!bucketFor(env, lib)) return json({ error: "unknown_library" }, 404);
  let album: IndexAlbum | GlobalAlbum | null = null;
  let readOnly = true;
  if (id === OTHER_ALBUM_ID) {
    const index = await loadIndex(env, lib);
    album = index.albums.find((a) => a.id === id) ?? otherAlbum(index);
  } else {
    const [shared, index] = await Promise.all([loadAlbums(env), loadIndex(env, lib)]);
    album = shared.albums.find((a) => a.id === id) ?? index.albums.find((a) => a.id === id) ?? null;
    readOnly = !shared.albums.some((a) => a.id === id);
  }
  if (!album) return json({ error: "not_found" }, 404);
  const cursor = Math.max(0, Number(url.searchParams.get("cursor") ?? "0") || 0);
  const limit = Math.min(200, Math.max(1, Number(url.searchParams.get("limit") ?? "60") || 60));
  const slice = album.items.slice(cursor, cursor + limit);
  const items = await Promise.all(
    slice.map((i) => mediaFor(env, origin, (i as GlobalAlbumItem).lib ?? lib, i)),
  );
  const next = cursor + limit < album.items.length ? String(cursor + limit) : null;
  return json({
    id: album.id,
    title: album.title,
    count: album.items.length,
    readOnly,
    items,
    cursor: next,
  });
}

export type FolderSort = "new" | "old" | "name" | "size";
const FOLDER_SORTS: readonly string[] = ["new", "old", "name", "size"];
const isFolderSort = (v: string): v is FolderSort => FOLDER_SORTS.includes(v);

/** 並び順ごとの比較値(primary)と、同値の決め手になる key。 */
interface SortPoint {
  primary: number | string;
  key: string;
}

function sortPoint(sort: FolderSort, o: { key: string; size: number; uploaded: Date }): SortPoint {
  switch (sort) {
    case "name":
      // アプリの名前順と同じく、末尾の名前を小文字にして比べる
      return { primary: (o.key.split("/").pop() ?? o.key).toLowerCase(), key: o.key };
    case "size":
      return { primary: o.size, key: o.key };
    default:
      return { primary: o.uploaded.getTime(), key: o.key };
  }
}

/** 新しい順・サイズ順は大きい値が先、古い順・名前順は小さい値が先。同値は key の昇順。 */
function compareFolderSort(sort: FolderSort, a: SortPoint, b: SortPoint): number {
  const dir = sort === "new" || sort === "size" ? -1 : 1;
  const p = a.primary < b.primary ? -1 : a.primary > b.primary ? 1 : 0;
  return p * dir || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
}

const formatFolderCursor = (p: SortPoint): string =>
  `${encodeURIComponent(String(p.primary))}|${encodeURIComponent(p.key)}`;

function parseFolderCursor(sort: FolderSort, cursor: string | undefined): SortPoint | null {
  const sep = (cursor ?? "").indexOf("|");
  if (!cursor || sep <= 0) return null;
  try {
    const raw = decodeURIComponent(cursor.slice(0, sep));
    const primary = sort === "name" ? raw : Number(raw);
    if (typeof primary === "number" && Number.isNaN(primary)) return null;
    return { primary, key: decodeURIComponent(cursor.slice(sep + 1)) };
  } catch {
    return null;
  }
}

export async function handleFolders(
  env: Env,
  origin: string,
  lib: string,
  bucket: R2Bucket,
  url: URL,
): Promise<Response> {
  const prefix = url.searchParams.get("prefix") ?? "";
  // TEMP E2E TEST HOOK — revert after testing: hang "e2e-slow" folder probes.
  if (prefix.includes("e2e-slow")) await new Promise((r) => setTimeout(r, 120_000));
  const cursor = url.searchParams.get("cursor") ?? undefined;
  // recursive=1 returns every media item under the prefix — the gallery
  // "all media" view — instead of one-level folder browsing.
  const recursive = url.searchParams.get("recursive") === "1";
  // sort=new|old|name|size: R2 は辞書順でしか列挙できず、日付・サイズ・名前で並べるには
  // 全件を集めるしかない。端末側で読み込み済みの分だけ並べると先頭ページ以外が
  // 順序に入らない(#44)ので、並べ替えはここで全体に対して行う。
  // order=recent は sort=new の旧名。古いアプリが送り続けるのでそのまま受ける。
  const sortParam = url.searchParams.get("sort");
  if (sortParam !== null && !isFolderSort(sortParam)) return json({ error: "invalid_sort" }, 400);
  const sort: FolderSort | null =
    (sortParam as FolderSort | null) ?? (url.searchParams.get("order") === "recent" ? "new" : null);
  if (sort) {
    const all: Awaited<ReturnType<R2Bucket["list"]>>["objects"] = [];
    const prefixes = new Set<string>();
    let cur: string | undefined;
    do {
      const page = await bucket.list(
        recursive
          ? { prefix, cursor: cur, limit: 1000 }
          : { prefix, delimiter: "/", cursor: cur, limit: 1000 },
      );
      all.push(...page.objects);
      for (const p of page.delimitedPrefixes) prefixes.add(p);
      cur = page.truncated ? page.cursor : undefined;
    } while (cur);
    const files = all
      .filter(
        (o) =>
          MEDIA_EXT.test(o.key) &&
          (!recursive || (!o.key.startsWith(SYSTEM_PREFIX) && !o.key.startsWith(TRASH_PREFIX))),
      )
      .sort((a, b) => compareFolderSort(sort, sortPoint(sort, a), sortPoint(sort, b)));
    // 位置カーソル(<並べ替えの値>|<key>)で続きを探す。件数オフセットだと、先頭に
    // 新しい物が入った時に既に出した分をもう一度出してしまう。
    let start = 0;
    const at = parseFolderCursor(sort, cursor);
    if (at) {
      start = files.findIndex((o) => compareFolderSort(sort, sortPoint(sort, o), at) > 0);
      if (start < 0) start = files.length;
    }
    const slice = files.slice(start, start + 200);
    const items = await Promise.all(
      slice.map((o) =>
        mediaFor(env, origin, lib, { key: o.key, createdAt: o.uploaded.getTime() }).then((m) => ({
          ...m,
          size: o.size,
        })),
      ),
    );
    const last = slice[slice.length - 1];
    return json({
      prefix,
      // 適用した並び順を返す。古い Worker は返さないので、アプリはこれで
      // 「サーバーが並べた」か「端末側で並べ直す」かを決める。
      sort,
      folders: recursive
        ? []
        : [...prefixes].filter((p) => !p.startsWith(SYSTEM_PREFIX) && !p.startsWith(TRASH_PREFIX)),
      items,
      cursor:
        last && start + slice.length < files.length
          ? formatFolderCursor(sortPoint(sort, last))
          : null,
    });
  }
  const listed = await bucket.list(
    recursive ? { prefix, cursor, limit: 200 } : { prefix, delimiter: "/", cursor, limit: 200 },
  );
  const files = listed.objects.filter(
    (o) =>
      MEDIA_EXT.test(o.key) &&
      (!recursive || (!o.key.startsWith(SYSTEM_PREFIX) && !o.key.startsWith(TRASH_PREFIX))),
  );
  const items = await Promise.all(
    files.map((o) =>
      mediaFor(env, origin, lib, { key: o.key, createdAt: o.uploaded.getTime() }).then((m) => ({
        ...m,
        size: o.size,
      })),
    ),
  );
  return json({
    prefix,
    folders: recursive
      ? []
      : listed.delimitedPrefixes.filter(
          (p) => !p.startsWith(SYSTEM_PREFIX) && !p.startsWith(TRASH_PREFIX),
        ),
    items,
    cursor: listed.truncated ? listed.cursor : null,
  });
}
