import { journalBestEffort, journalExisting, rowOf } from "../lib/catalog";
import { MAX_SIMPLE_UPLOAD, SYSTEM_PREFIX, TRASH_PREFIX } from "../lib/const";
import type { Env } from "../lib/env";
import { readable, writable } from "../lib/env";
import { dropHashBestEffort, isSha256Hex, recordHashBestEffort } from "../lib/hashes";
import { assertUserKey, HttpError, json, readJson, ref } from "../lib/http";
import { handleImport } from "../lib/import";
import {
  completeCreateOnly,
  copyObject,
  createOnly,
  dropThumbBestEffort,
  moveBackFromTrash,
  moveObject,
} from "../lib/objects";
import { loadAlbums, loadIndex, mutateAlbums } from "../lib/store";
import type { AlbumsFile, GlobalAlbum } from "../lib/store";
import {
  dropKeeperDependent,
  foldGhostsIntoOrder,
  insertByTrashOrder,
  makeProbe,
  pruneTrashOrder,
  trashAlbumsPath,
  type TrashAlbumMembership,
} from "../lib/trash-albums";
import { trashDuplicate } from "./duplicates";

// まとめて消す口の取り消しも、戻した物のサムネの有無をこの置き場で確かめる
export const thumbPath = (lib: string, key: string) => `${SYSTEM_PREFIX}thumbs/${lib}/${key}.webp`;

type WaitUntil = Pick<ExecutionContext, "waitUntil">;

/** 新しく置いた物を索引へ足す。同名の古いサムネは消した後なので、サムネ無しとして足す。 */
const journalCreated = (env: Env, lib: string, obj: R2Object, ctx?: WaitUntil) =>
  journalBestEffort(env, lib, { put: [rowOf(obj)], unthumb: [obj.key] }, ctx);

/**
 * 409 で断る在る物を索引へ足す。初回の応答が届かず送り直された物を一覧へ戻す。
 * 追記の直前にもう一度確かめる。断りの確認と追記の間に消された物を、
 * 遅い追記の勝ちで一覧に復活させないため（競合の窓は残るが、残りは作り直しで揃う）
 */
const journalBlocked = async (
  env: Env,
  lib: string,
  bucket: R2Bucket,
  key: string,
  ctx?: WaitUntil,
) => {
  const existing = await bucket.head(key);
  if (existing) await journalExisting(env, lib, existing, ctx);
};

/** PUT /v1/:lib/objects?key= — small object upload; refuses to overwrite. */
export async function handlePutObject(
  req: Request,
  env: Env,
  lib: string,
  url: URL,
  ctx?: WaitUntil,
) {
  const { bucket } = writable(env, lib);
  const key = assertUserKey(url.searchParams.get("key"));
  const len = Number(req.headers.get("content-length") ?? "0");
  if (!req.body || !len) throw new HttpError(411, "length_required");
  if (len > MAX_SIMPLE_UPLOAD) throw new HttpError(413, "too_large_use_multipart");
  // アプリが計算した中身のハッシュ。R2 に検証させ、通った物だけを重複判定の記録に使う
  const claimed = req.headers.get("x-content-sha256")?.toLowerCase();
  if (claimed !== undefined && !isSha256Hex(claimed)) throw new HttpError(400, "bad_sha256");
  const existing = await bucket.head(key);
  if (existing) {
    await journalBlocked(env, lib, bucket, key, ctx);
    throw new HttpError(409, "destination_exists");
  }
  let put: R2Object | null;
  try {
    put = await bucket.put(key, req.body, {
      httpMetadata: {
        contentType: req.headers.get("content-type") ?? "application/octet-stream",
      },
      onlyIf: createOnly(),
      ...(claimed ? { sha256: claimed } : {}),
    });
  } catch (e) {
    // 申告と中身が違う時、R2 は保存せずに例外を投げる
    if (claimed && /sha-?256|checksum|digest/i.test(e instanceof Error ? e.message : String(e))) {
      throw new HttpError(400, "checksum_mismatch");
    }
    throw e;
  }
  if (!put) {
    await journalBlocked(env, lib, bucket, key, ctx);
    throw new HttpError(409, "destination_exists");
  }
  // 同名の削除済みの物のサムネが残っていると、新しい物に古い絵が出る
  await dropThumbBestEffort(env, lib, key);
  await journalCreated(env, lib, put, ctx);
  if (claimed) {
    await recordHashBestEffort(env, lib, key, { size: put.size, etag: put.etag, sha256: claimed });
  }
  return json({ key, size: put.size }, 201);
}

/** POST /v1/:lib/objects/multipart — initiate a multipart upload. */
export async function handleMultipartInit(req: Request, env: Env, lib: string, ctx?: WaitUntil) {
  const { bucket } = writable(env, lib);
  const body = await readJson(req);
  const key = assertUserKey(body.key);
  const existing = await bucket.head(key);
  if (existing) {
    await journalBlocked(env, lib, bucket, key, ctx);
    throw new HttpError(409, "destination_exists");
  }
  const contentType =
    typeof body.contentType === "string" && body.contentType.startsWith("image/")
      ? body.contentType
      : typeof body.contentType === "string" && body.contentType.startsWith("video/")
        ? body.contentType
        : "application/octet-stream";
  const up = await bucket.createMultipartUpload(key, {
    httpMetadata: { contentType },
  });
  return json({ key, uploadId: up.uploadId }, 201);
}

/** PUT /v1/:lib/objects/multipart/part?key=&uploadId=&part= — upload one part. */
export async function handleMultipartPart(req: Request, env: Env, lib: string, url: URL) {
  const { bucket } = writable(env, lib);
  const key = assertUserKey(url.searchParams.get("key"));
  const uploadId = url.searchParams.get("uploadId") ?? "";
  const partNumber = Number(url.searchParams.get("part"));
  if (!uploadId || !Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10_000) {
    throw new HttpError(400, "bad_part");
  }
  if (!req.body) throw new HttpError(411, "length_required");
  const up = await bucket.resumeMultipartUpload(key, uploadId);
  const part = await up.uploadPart(partNumber, req.body);
  return json({ etag: part.etag, partNumber: part.partNumber });
}

/** POST /v1/:lib/objects/multipart/(complete|abort) — finish or cancel a multipart upload. */
export async function handleMultipartDone(
  req: Request,
  env: Env,
  lib: string,
  action: "complete" | "abort",
  ctx?: WaitUntil,
) {
  const { bucket } = writable(env, lib);
  const body = await readJson(req);
  const key = assertUserKey(body.key);
  const uploadId = typeof body.uploadId === "string" ? body.uploadId : "";
  if (!uploadId) throw new HttpError(400, "bad_upload_id");
  const up = await bucket.resumeMultipartUpload(key, uploadId);
  if (action === "abort") {
    await up.abort();
    return json({ ok: true });
  }
  const parts = Array.isArray(body.parts) ? body.parts : [];
  const uploaded: R2UploadedPart[] = parts.map((p) => {
    const r = p && typeof p === "object" ? (p as Record<string, unknown>) : {};
    const partNumber = Number(r.partNumber);
    const etag = typeof r.etag === "string" ? r.etag : "";
    if (!Number.isInteger(partNumber) || !etag) throw new HttpError(400, "bad_parts");
    return { partNumber, etag };
  });
  if (!uploaded.length) throw new HttpError(400, "bad_parts");
  let obj: R2Object;
  try {
    obj = await completeCreateOnly(bucket, up, uploaded);
  } catch (e) {
    // 完了の直前に同名が在った時（409）。応答を落として送り直された物を索引へ戻す
    if (e instanceof HttpError && e.status === 409) {
      await journalBlocked(env, lib, bucket, key, ctx);
    }
    throw e;
  }
  await dropThumbBestEffort(env, lib, key);
  await journalCreated(env, lib, obj, ctx);
  return json({ key, size: obj.size }, 201);
}

const THUMB_TYPES = new Set(["image/webp", "image/jpeg"]);

/** サムネの先頭バイトから実際の形式を決める。JPEG・WEBP 以外は null。 */
export function sniffThumbType(b: Uint8Array): "image/jpeg" | "image/webp" | null {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  const tag = (at: number) => String.fromCharCode(...b.subarray(at, at + 4));
  if (b.length >= 12 && tag(0) === "RIFF" && tag(8) === "WEBP") return "image/webp";
  return null;
}

/**
 * PUT /v1/:lib/thumb?key= — write a META thumbnail (JPEG or WEBP).
 * 置き場所の `.webp` は名前だけ。一覧と /t/ がこの名前で既存サムネを引くので変えない
 */
export async function handleThumb(req: Request, env: Env, lib: string, url: URL) {
  writable(env, lib);
  const key = assertUserKey(url.searchParams.get("key"));
  const type = (req.headers.get("content-type") ?? "").split(";")[0]?.trim() ?? "";
  const len = Number(req.headers.get("content-length") ?? "0");
  if (!req.body || !len) throw new HttpError(411, "length_required");
  if (len > 4 * 1024 * 1024) throw new HttpError(413, "too_large");
  if (!THUMB_TYPES.has(type)) throw new HttpError(415, "thumb_must_be_jpeg_or_webp");
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length > 4 * 1024 * 1024) throw new HttpError(413, "too_large");
  // 表記ではなく中身で保存する。画像サムネの JPEG を webp と名乗って送る古いアプリが
  // 配られたまま残っているので、表記違いは弾かず正しい形式で記録し直す
  const actual = sniffThumbType(bytes);
  if (!actual) throw new HttpError(415, "thumb_must_be_jpeg_or_webp");
  const obj = await env.META.put(thumbPath(lib, key), bytes, {
    httpMetadata: { contentType: actual },
  });
  await journalBestEffort(env, lib, { thumb: [key] });
  return json({ key: obj.key, size: obj.size, contentType: actual }, 201);
}

/** POST /v1/:lib/objects/import — fetch a remote media URL into the library. */
export function handleImportRoute(req: Request, env: Env, lib: string) {
  return handleImport(req, env, lib);
}

/** POST /v1/ops/copy or /v1/ops/move — server-side object copy/move. */
export async function handleCopyMove(
  req: Request,
  env: Env,
  action: "copy" | "move",
): Promise<Response> {
  const body = await readJson(req);
  const from = ref(body.from);
  const to = ref(body.to);
  const srcKey = assertUserKey(from.key);
  const dstKey = assertUserKey(to.key);
  const dst = writable(env, to.lib);
  if (action === "copy") {
    const src = readable(env, from.lib);
    const put = await copyObject(env, src.bucket, srcKey, dst.bucket, dstKey);
    await dropThumbBestEffort(env, dst.lib.id, dstKey);
    await journalCreated(env, dst.lib.id, put);
    return json({ ok: true, to: { lib: dst.lib.id, key: dstKey }, size: put.size });
  }
  const src = writable(env, from.lib);
  if (src.lib.id === dst.lib.id && srcKey === dstKey) throw new HttpError(400, "same_key");
  const put = await moveObject(env, src.bucket, srcKey, dst.bucket, dstKey);
  await dropThumbBestEffort(env, dst.lib.id, dstKey);
  if (src.lib.id === dst.lib.id) {
    await journalBestEffort(env, dst.lib.id, {
      del: [srcKey],
      put: [rowOf(put)],
      unthumb: [dstKey],
    });
  } else {
    await journalBestEffort(env, src.lib.id, { del: [srcKey] });
    await journalCreated(env, dst.lib.id, put);
  }
  await dropHashBestEffort(env, src.lib.id, srcKey);
  // 元の key は無くなるので、そのサムネは誰からも参照されない。孤児にしない
  await dropThumbBestEffort(env, src.lib.id, srcKey);
  return json({ ok: true, to: { lib: dst.lib.id, key: dstKey }, size: put.size });
}

/** POST /v1/:lib/ops/(mkdir|trash|restore) — folder create, soft delete, restore. */
export async function handleLibOps(
  req: Request,
  env: Env,
  lib: string,
  action: string,
): Promise<Response> {
  const { bucket } = writable(env, lib);
  const body = await readJson(req);
  if (action === "mkdir") {
    const prefix = assertUserKey(String(body.prefix ?? "").replace(/\/+$/, ""));
    const key = `${prefix}/.keep`;
    if (!(await bucket.head(key))) {
      // フォルダの段は索引から作るので、目印のファイルも索引に足す
      const marker = await bucket.put(key, new Uint8Array(0));
      if (marker) await journalBestEffort(env, lib, { put: [rowOf(marker)] });
    }
    return json({ ok: true, prefix: `${prefix}/` }, 201);
  }
  if (action === "trash") {
    const key = assertUserKey(body.key);
    if (body.duplicateOf !== undefined) {
      return trashDuplicate(env, lib, bucket, key, assertUserKey(body.duplicateOf));
    }
    const trashKey = `${TRASH_PREFIX}${Date.now()}/${key}`;
    const sidecar = trashAlbumsPath(lib, trashKey);
    // 外す前に控えを書く。ここで失敗すれば何も動かないので、所属が失われない。
    const snapshot = (data: AlbumsFile): TrashAlbumMembership[] =>
      data.albums.flatMap((a) => {
        const item = a.items.find((i) => i.lib === lib && i.key === key);
        return item ? [{ albumId: a.id, item }] : [];
      });
    const planned = snapshot(await loadAlbums(env));
    const putSidecar = (m: TrashAlbumMembership[]) =>
      env.META.put(sidecar, JSON.stringify(m), {
        httpMetadata: { contentType: "application/json" },
      });
    if (planned.length) await putSidecar(planned);
    try {
      await moveObject(env, bucket, key, bucket, trashKey);
    } catch (e) {
      // 途中まで進んで投げた時は実物の場所で決める（/similar/trash と同じ）。元が消えて
      // ゴミ箱に在れば移っているので続ける。元が残っていれば、この呼び出しの写しを消して断る
      // （控えの無い写しはゴミ箱に出るのに戻せない）
      // 確かめられなかった時は undefined。物がどこに在るか分からないので控えは消さない
      const [left, moved] = await Promise.all([bucket.head(key), bucket.head(trashKey)]).catch(
        () => [undefined, undefined] as const,
      );
      if (!(left === null && moved)) {
        const copied = !(e instanceof HttpError && e.code === "destination_exists");
        if (left && moved && copied) {
          await bucket.delete(trashKey).catch((d: unknown) => {
            console.error("trash_leftover_delete_failed", lib, trashKey, d);
          });
        }
        // 元に残っている（動いていない）か、元にもゴミ箱にも無い（別の操作が先に動かした・消した）
        // なら、この呼び出しのゴミ箱の物は無いので控えも要らない
        if (planned.length && left !== undefined) await env.META.delete(sidecar);
        throw e;
      }
    }
    // アルバムの更新より先に索引から外す。後ろで失敗しても、一覧に消した物が残らない
    await journalBestEffort(env, lib, { del: [key] });
    await dropHashBestEffort(env, lib, key);
    // Shared albums must not keep pointing at an object that no longer
    // exists — drop the key from every album that lists it.
    let removed: TrashAlbumMembership[] = [];
    const probe = makeProbe(env);
    let attempt = 0;
    await mutateAlbums(env, async (data) => {
      if (attempt++) probe.reset();
      // etag 競合で再実行されるので、毎回作り直す
      removed = snapshot(data);
      for (const a of data.albums) {
        if (!a.items.some((i) => i.lib === lib && i.key === key)) continue;
        foldGhostsIntoOrder(a);
        a.items = a.items.filter((i) => !(i.lib === lib && i.key === key));
        await pruneTrashOrder(probe, a);
      }
    });
    // 控えを書いてから所属が増減していたら（並行操作）、実際に外した分で書き直す
    if (JSON.stringify(removed) !== JSON.stringify(planned)) {
      if (removed.length) await putSidecar(removed);
      else await env.META.delete(sidecar);
    }
    return json({ ok: true, trashKey });
  }
  // restore
  const trashKey = typeof body.trashKey === "string" ? body.trashKey : "";
  const tm = /^\.trash\/(\d+)\/([\s\S]+)$/.exec(trashKey);
  if (!tm) throw new HttpError(400, "bad_trash_key");
  const original = assertUserKey(tm[2]);
  // 控えがあれば、まだ存在するアルバムへ元の並びで戻す。控えが無い（この修正より前に
  // 捨てた）物は従来どおりファイルだけ戻る。
  const sidecar = trashAlbumsPath(lib, trashKey);
  const saved = await env.META.get(sidecar);
  // 前回、ファイルは戻ったのにアルバムの更新で失敗した場合のやり直しも、写しは済んだのに
  // ゴミ箱側を消せなかった場合も、物の在り処で決める（中身が同じ写しが元の key に在れば戻っている）
  const { obj: back } = await moveBackFromTrash(env, bucket, trashKey, original, !!saved);
  // やり直しでも行を足し直す。前回が索引の追記の前で止まっていると一覧に戻らないため
  // （同じ行を 2 回足しても、一覧は同じになる）
  {
    // ゴミ箱の間もサムネは残してある。あるかを 1 回だけ確かめて索引に足す
    // 確かめられなかった時はサムネの有無に触れない。ここで 5xx にすると、本体は戻ったのに
    // 失敗と伝わり、やり直しは「もうゴミ箱に無い」で通らなくなる
    const hasThumb = await env.META.head(thumbPath(lib, original)).then(
      (o) => o !== null,
      (e: unknown) => {
        console.error("thumb_probe_failed", lib, original, e);
        return null;
      },
    );
    await journalBestEffort(env, lib, {
      put: [rowOf(back)],
      ...(hasThumb === null ? {} : hasThumb ? { thumb: [original] } : { unthumb: [original] }),
    });
  }
  if (saved) {
    const memberships = await saved.json<TrashAlbumMembership[]>();
    const probe = makeProbe(env);
    let attempt = 0;
    await mutateAlbums(env, async (data) => {
      if (attempt++) probe.reset();
      for (const m of memberships) {
        const album = data.albums.find((a) => a.id === m.albumId);
        if (!album) continue;
        const keeperId = m.keeper ? `${lib}:${m.keeper}` : "";
        if (album.items.some((i) => i.lib === lib && i.key === original)) {
          // ゴミ箱から戻した物はもう誰の代わりも要らない。残す物はここでは外さない（従来の決まり）
          if (keeperId) dropKeeperDependent(album, keeperId, `${lib}:${original}`);
          continue;
        }
        // 中身が同じ物として消した物は、残す側が居るアルバムへは戻さない（ライブラリに戻るだけ）。
        // 同じ絵が並んで二重になるのを避ける従来の決まり。残す側はここでは外さない:
        // 残す側を外すのは消した直後の取り消し（/similar/undo）だけ
        if (m.exact && m.keeper && album.items.some((i) => i.lib === lib && i.key === m.keeper)) {
          // このアルバムでは、残す側が戻した物の代わりにずっと居ることになる。代わりの控えを丸ごと
          // 消して、元からアルバムに居た物と同じ扱いにする。控えを残すと、同じ残す側で一緒に消した
          // 別の物の取り消しが残す側を外し、戻した物も残す側もアルバムから消えてしまう
          if (album.keeperFor?.[keeperId]) {
            delete album.keeperFor[keeperId];
            if (!Object.keys(album.keeperFor).length) delete album.keeperFor;
          }
          continue;
        }
        if (keeperId) dropKeeperDependent(album, keeperId, `${lib}:${original}`);
        insertByTrashOrder(album, m.item);
        await pruneTrashOrder(probe, album);
      }
    });
    await env.META.delete(sidecar);
  }
  return json({ ok: true, key: original });
}

// ---------- user albums (shared store; an album mixes libraries) ----------

/** POST /v1/:lib/albums — create a user album. Body: {title, subtitle?}. */
export async function handleAlbumCreate(req: Request, env: Env, lib: string) {
  writable(env, lib);
  const body = await readJson(req);
  const title = typeof body.title === "string" ? body.title.trim() : "";
  if (!title) throw new HttpError(400, "title_required");
  if (title.length > 200) throw new HttpError(400, "title_too_long");
  const album: GlobalAlbum = {
    id: crypto.randomUUID(),
    title,
    subtitle: typeof body.subtitle === "string" && body.subtitle.trim() ? body.subtitle : undefined,
    items: [],
  };
  await mutateAlbums(env, (data) => {
    data.albums.push(album);
  });
  return json({ id: album.id, title: album.title }, 201);
}

function albumKeys(body: Record<string, unknown>): string[] {
  const keys = body.keys;
  if (!Array.isArray(keys) || !keys.length || keys.length > 500) {
    throw new HttpError(400, "bad_keys");
  }
  return keys.map((k) => assertUserKey(k));
}

function findAlbum(data: AlbumsFile, id: string): GlobalAlbum {
  const album = data.albums.find((a) => a.id === id);
  if (!album) throw new HttpError(404, "not_found");
  return album;
}

/** POST /v1/:lib/albums/:id/items — append keys to an album; each key is
 *  stamped with :lib so an album can mix libraries. Body: {keys:[...]}. */
export async function handleAlbumItemsAdd(req: Request, env: Env, lib: string, id: string) {
  const { bucket } = writable(env, lib);
  const keys = albumKeys(await readJson(req));
  // Album entries must point at objects that actually exist — reject keys
  // that aren't in this lib's bucket instead of storing 404 entries.
  const missing = (
    await Promise.all(keys.map(async (k) => ((await bucket.head(k)) ? null : k)))
  ).filter((k): k is string => k !== null);
  if (missing.length) throw new HttpError(404, `not_in_library: ${missing.join(",")}`);
  const index = await loadIndex(env, lib);
  const meta = new Map((index.items ?? []).map((i) => [i.key, i]));
  let added = 0;
  const data = await mutateAlbums(env, (d) => {
    const album = findAlbum(d, id);
    const have = new Set(album.items.map((i) => `${i.lib}:${i.key}`));
    for (const k of keys) {
      if (have.has(`${lib}:${k}`)) continue;
      const src = meta.get(k);
      album.items.push(src ? { ...src, lib } : { key: k, lib, createdAt: Date.now() });
      have.add(`${lib}:${k}`);
      added++;
    }
  });
  const album = findAlbum(data, id);
  return json({ id, added, count: album.items.length });
}

/** POST /v1/:lib/albums/:id/items/remove — drop this lib's keys from the
 *  album; entries belonging to other libraries are untouched. */
export async function handleAlbumItemsRemove(req: Request, env: Env, lib: string, id: string) {
  writable(env, lib);
  const keys = new Set(albumKeys(await readJson(req)));
  let removed = 0;
  const probe = makeProbe(env);
  let attempt = 0;
  const data = await mutateAlbums(env, async (d) => {
    if (attempt++) probe.reset();
    const album = findAlbum(d, id);
    const before = album.items.length;
    album.items = album.items.filter((i) => !(i.lib === lib && keys.has(i.key)));
    removed = before - album.items.length;
    await pruneTrashOrder(probe, album);
  });
  const album = findAlbum(data, id);
  return json({ id, removed, count: album.items.length });
}

/** PATCH /v1/:lib/albums/:id — update album fields. Body: {title?, subtitle?}. */
export async function handleAlbumUpdate(req: Request, env: Env, lib: string, id: string) {
  writable(env, lib);
  const body = await readJson(req);
  const data = await mutateAlbums(env, (d) => {
    const album = findAlbum(d, id);
    if (body.title !== undefined) {
      const title = typeof body.title === "string" ? body.title.trim() : "";
      if (!title) throw new HttpError(400, "title_required");
      if (title.length > 200) throw new HttpError(400, "title_too_long");
      album.title = title;
    }
    if (body.subtitle !== undefined) {
      album.subtitle =
        typeof body.subtitle === "string" && body.subtitle.trim() ? body.subtitle : undefined;
    }
  });
  const album = findAlbum(data, id);
  return json({ id, title: album.title, subtitle: album.subtitle ?? null });
}

/** POST /v1/:lib/albums/:id/order — reorder the album's items to match the
 *  given order. Body: {items:[{key,lib}...]} — must contain exactly the same
 *  entries already in the album (reorders only, never adds or removes). */
export async function handleAlbumOrder(req: Request, env: Env, lib: string, id: string) {
  writable(env, lib);
  const body = await readJson(req);
  const items = body.items;
  if (!Array.isArray(items) || items.length > 2000) throw new HttpError(400, "bad_items");
  const wanted = items.map((i) => {
    const key = assertUserKey((i as Record<string, unknown>)?.key);
    const ilib =
      typeof (i as Record<string, unknown>)?.lib === "string" ? (i as { lib: string }).lib : "";
    return `${ilib}:${key}`;
  });
  if (new Set(wanted).size !== wanted.length) throw new HttpError(400, "duplicate_items");
  const data = await mutateAlbums(env, (d) => {
    const album = findAlbum(d, id);
    const byStamp = new Map(album.items.map((i) => [`${i.lib}:${i.key}`, i]));
    if (byStamp.size !== wanted.length || !wanted.every((w) => byStamp.has(w))) {
      throw new HttpError(409, "order_mismatch: items must match the album's current set");
    }
    album.items = wanted.map((w) => byStamp.get(w)!);
  });
  const album = findAlbum(data, id);
  return json({ id, count: album.items.length });
}

/** DELETE /v1/:lib/albums/:id — delete the album itself (media untouched). */
export async function handleAlbumDelete(env: Env, lib: string, id: string) {
  writable(env, lib);
  await mutateAlbums(env, (data) => {
    if (!data.albums.some((a) => a.id === id)) throw new HttpError(404, "not_found");
    data.albums = data.albums.filter((a) => a.id !== id);
  });
  return json({ ok: true });
}
