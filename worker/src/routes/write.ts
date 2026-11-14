import { MAX_SIMPLE_UPLOAD, SYSTEM_PREFIX, TRASH_PREFIX } from "../lib/const";
import type { Env } from "../lib/env";
import { bucketFor, readable, writable } from "../lib/env";
import { assertUserKey, HttpError, json, readJson, ref } from "../lib/http";
import { handleImport } from "../lib/import";
import {
  completeCreateOnly,
  copyObject,
  createOnly,
  deleteThumb,
  moveObject,
} from "../lib/objects";
import { loadAlbums, loadIndex, mutateAlbums } from "../lib/store";
import type { AlbumsFile, GlobalAlbum, GlobalAlbumItem } from "../lib/store";

// ゴミ箱へ送る時に外したアルバムの控え。復元で元のアルバムへ戻すために、
// 外した項目そのものを META に置く（R2 のゴミ箱には載せない）。
interface TrashAlbumMembership {
  albumId: string;
  item: GlobalAlbumItem;
}
const trashAlbumsPath = (lib: string, trashKey: string) =>
  `${SYSTEM_PREFIX}trash-albums/${lib}/${trashKey.slice(TRASH_PREFIX.length)}.json`;
const refKey = (i: { lib: string; key: string }) => `${i.lib}:${i.key}`;

// 位置の控えは index ではなく「ゴミ箱の物も含めた並び」を albums.json 側に持つ。
// index だと、複数枚を送った時に後の物の位置が先に抜けた物の分ずれて、戻すと逆順になる。
function foldGhostsIntoOrder(album: GlobalAlbum) {
  const order = album.items.map(refKey);
  const seen = new Set(order);
  const prev = album.trashOrder ?? [];
  prev.forEach((id, i) => {
    if (seen.has(id)) return;
    // 手前にいた物のうち残っている最寄りの後ろへ。無ければ先頭
    let at = 0;
    for (let j = i - 1; j >= 0; j--) {
      const k = order.indexOf(prev[j]!);
      if (k >= 0) {
        at = k + 1;
        break;
      }
    }
    order.splice(at, 0, id);
    seen.add(id);
  });
  album.trashOrder = order;
}

// 候補のうち「まだ戻せる物」を返す。期限切れ purge は控えを消さないので、控えがあり、かつ
// .trash の実体も元の key も無い物だけを purge 済みと見なす。restore は実体を先に元の key へ戻して
// からアルバムを更新するので、元の key を見ないと、その間に戻している途中の物が落ちてしまう。
// 控えの一覧と head の結果はリクエスト内で使い回し、mutateAlbums がやり直す時だけ捨てる
// （並行した trash が書いた控えを見落として落とさないため）。
function makeProbe(env: Env) {
  let lists = new Map<string, Promise<Map<string, string[]>>>();
  let heads = new Map<string, Promise<boolean>>();
  const listSidecars = (lib: string) => {
    let p = lists.get(lib);
    if (!p) {
      p = (async () => {
        const out = new Map<string, string[]>();
        const prefix = `${SYSTEM_PREFIX}trash-albums/${lib}/`;
        let cursor: string | undefined;
        do {
          const listed = await env.META.list({ prefix, cursor });
          for (const o of listed.objects) {
            const m = /^(\d+)\/(.+)\.json$/.exec(o.key.slice(prefix.length));
            if (!m) continue;
            const id = `${lib}:${m[2]}`;
            out.set(id, [...(out.get(id) ?? []), `${TRASH_PREFIX}${m[1]}/${m[2]}`]);
          }
          cursor = listed.truncated ? listed.cursor : undefined;
        } while (cursor);
        return out;
      })();
      lists.set(lib, p);
    }
    return p;
  };
  const head = (lib: string, bucket: R2Bucket, key: string) => {
    const id = `${lib}\n${key}`;
    let p = heads.get(id);
    if (!p) {
      p = bucket.head(key).then((o) => o !== null);
      heads.set(id, p);
    }
    return p;
  };
  return {
    reset() {
      lists = new Map();
      heads = new Map();
    },
    async live(candidates: Set<string>): Promise<Set<string>> {
      const live = new Set<string>();
      for (const id of candidates) {
        const lib = id.slice(0, id.indexOf(":"));
        const original = id.slice(lib.length + 1);
        const t = bucketFor(env, lib);
        const trashKeys = t ? (await listSidecars(lib)).get(id) : undefined;
        if (!t || !trashKeys) continue;
        const alive = await Promise.all([
          head(lib, t.bucket, original),
          ...trashKeys.map((k) => head(lib, t.bucket, k)),
        ]);
        if (alive.some(Boolean)) live.add(id);
      }
      return live;
    },
  };
}
type Probe = ReturnType<typeof makeProbe>;

// 並びの控えが増え続けないよう、アルバムにも今のゴミ箱にも無い key（アルバムから外した物、
// purge された物）を落とし、ゴミ箱の物が無くなれば控え自体を消す。mutateAlbums の中で呼ぶ。
// trash は控えを書いてから albums.json を更新するので、並行して送った物は落ちない。
async function pruneTrashOrder(probe: Probe, album: GlobalAlbum) {
  const order = album.trashOrder;
  if (!order) return;
  const present = new Set(album.items.map(refKey));
  const ghosts = new Set(order.filter((k) => !present.has(k)));
  const live = ghosts.size ? await probe.live(ghosts) : ghosts;
  if (!live.size) {
    delete album.trashOrder;
    return;
  }
  album.trashOrder = order.filter((k) => present.has(k) || live.has(k));
}

function insertByTrashOrder(album: GlobalAlbum, item: GlobalAlbumItem) {
  const id = refKey(item);
  const order = album.trashOrder ?? [];
  const idx = order.indexOf(id);
  // 項目数の2乗にならないよう、現在の位置は一度だけ作る
  const where = new Map(album.items.map((i, n) => [refKey(i), n]));
  let at = album.items.length;
  if (idx >= 0) {
    // 最寄りの手前の物の後ろ → 無ければ最寄りの後ろの物の前 → 無ければ先頭
    at = 0;
    let found = false;
    for (let j = idx - 1; j >= 0 && !found; j--) {
      const k = where.get(order[j]!);
      if (k !== undefined) {
        at = k + 1;
        found = true;
      }
    }
    for (let j = idx + 1; j < order.length && !found; j++) {
      const k = where.get(order[j]!);
      if (k !== undefined) {
        at = k;
        found = true;
      }
    }
  }
  album.items.splice(at, 0, item);
}

/** PUT /v1/:lib/objects?key= — small object upload; refuses to overwrite. */
export async function handlePutObject(req: Request, env: Env, lib: string, url: URL) {
  const { bucket } = writable(env, lib);
  const key = assertUserKey(url.searchParams.get("key"));
  const len = Number(req.headers.get("content-length") ?? "0");
  if (!req.body || !len) throw new HttpError(411, "length_required");
  if (len > MAX_SIMPLE_UPLOAD) throw new HttpError(413, "too_large_use_multipart");
  if (await bucket.head(key)) throw new HttpError(409, "destination_exists");
  const put = await bucket.put(key, req.body, {
    httpMetadata: {
      contentType: req.headers.get("content-type") ?? "application/octet-stream",
    },
    onlyIf: createOnly(),
  });
  if (!put) throw new HttpError(409, "destination_exists");
  // 同名の削除済みの物のサムネが残っていると、新しい物に古い絵が出る
  await deleteThumb(env, lib, key);
  return json({ key, size: put.size }, 201);
}

/** POST /v1/:lib/objects/multipart — initiate a multipart upload. */
export async function handleMultipartInit(req: Request, env: Env, lib: string) {
  const { bucket } = writable(env, lib);
  const body = await readJson(req);
  const key = assertUserKey(body.key);
  if (await bucket.head(key)) throw new HttpError(409, "destination_exists");
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
  const obj = await completeCreateOnly(bucket, up, uploaded);
  await deleteThumb(env, lib, key);
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
  const obj = await env.META.put(`${SYSTEM_PREFIX}thumbs/${lib}/${key}.webp`, bytes, {
    httpMetadata: { contentType: actual },
  });
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
    await deleteThumb(env, dst.lib.id, dstKey);
    return json({ ok: true, to: { lib: dst.lib.id, key: dstKey }, size: put.size });
  }
  const src = writable(env, from.lib);
  if (src.lib.id === dst.lib.id && srcKey === dstKey) throw new HttpError(400, "same_key");
  const put = await moveObject(env, src.bucket, srcKey, dst.bucket, dstKey);
  await deleteThumb(env, dst.lib.id, dstKey);
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
    if (!(await bucket.head(key))) await bucket.put(key, new Uint8Array(0));
    return json({ ok: true, prefix: `${prefix}/` }, 201);
  }
  if (action === "trash") {
    const key = assertUserKey(body.key);
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
      if (planned.length) await env.META.delete(sidecar);
      throw e;
    }
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
  const tm = /^\.trash\/(\d+)\/(.+)$/.exec(trashKey);
  if (!tm) throw new HttpError(400, "bad_trash_key");
  const original = assertUserKey(tm[2]);
  // 控えがあれば、まだ存在するアルバムへ元の並びで戻す。控えが無い（この修正より前に
  // 捨てた）物は従来どおりファイルだけ戻る。
  const sidecar = trashAlbumsPath(lib, trashKey);
  const saved = await env.META.get(sidecar);
  // 前回、ファイルは戻ったのにアルバムの更新で失敗した場合のやり直し：移動は済んでいるので飛ばす
  const resumed = saved && !(await bucket.head(trashKey)) && !!(await bucket.head(original));
  if (!resumed) await moveObject(env, bucket, trashKey, bucket, original);
  if (saved) {
    const memberships = await saved.json<TrashAlbumMembership[]>();
    const probe = makeProbe(env);
    let attempt = 0;
    await mutateAlbums(env, async (data) => {
      if (attempt++) probe.reset();
      for (const m of memberships) {
        const album = data.albums.find((a) => a.id === m.albumId);
        if (!album || album.items.some((i) => i.lib === lib && i.key === original)) continue;
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
