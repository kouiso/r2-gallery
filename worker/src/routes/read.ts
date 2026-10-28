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
  // order=recent: R2 lists keys lexicographically, so freshly uploaded objects
  // (e.g. CJK names) sort last and page way past the visible window. Collect
  // the whole listing once, sort by upload time descending, then paginate by a
  // position cursor (<uploadedMs>|<key> of the page's last item) — an offset
  // cursor shifts when a new object lands at the front and re-shows files the
  // client already rendered.
  if (url.searchParams.get("order") === "recent") {
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
      .sort(
        (a, b) =>
          b.uploaded.getTime() - a.uploaded.getTime() ||
          (a.key < b.key ? -1 : a.key > b.key ? 1 : 0),
      );
    let start = 0;
    const sep = (cursor ?? "").indexOf("|");
    if (sep > 0) {
      const t = Number((cursor as string).slice(0, sep));
      const k = decodeURIComponent((cursor as string).slice(sep + 1));
      start = files.findIndex(
        (o) => o.uploaded.getTime() < t || (o.uploaded.getTime() === t && o.key > k),
      );
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
      folders: recursive
        ? []
        : [...prefixes].filter((p) => !p.startsWith(SYSTEM_PREFIX) && !p.startsWith(TRASH_PREFIX)),
      items,
      cursor:
        last && start + slice.length < files.length
          ? `${last.uploaded.getTime()}|${encodeURIComponent(last.key)}`
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
