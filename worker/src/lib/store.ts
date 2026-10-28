import {
  IMAGE_EXT,
  INDEX_CACHE_MS,
  MEDIA_EXT,
  OTHER_ALBUM_ID,
  OTHER_ALBUM_TITLE,
  SYSTEM_PREFIX,
  VIDEO_EXT,
} from "./const";
import type { Env } from "./env";
import { signedUrl } from "./sign";

export interface IndexItem {
  key: string;
  thumb?: string;
  note?: string;
  createdAt?: number;
}

export interface IndexAlbum {
  id: string;
  title: string;
  subtitle?: string;
  cover?: string;
  items: IndexItem[];
}

export interface IndexFile {
  version: 1;
  generatedAt?: string;
  /** Optional flat list of every media key in the library; used to build "その他". */
  items?: IndexItem[];
  albums: IndexAlbum[];
}

/** Virtual album holding index.items that no declared album claims. */
export function otherAlbum(index: IndexFile): IndexAlbum | null {
  if (!index.items?.length) return null;
  const assigned = new Set(index.albums.flatMap((a) => a.items.map((i) => i.key)));
  const items = index.items.filter((i) => !assigned.has(i.key) && MEDIA_EXT.test(i.key));
  return items.length ? { id: OTHER_ALBUM_ID, title: OTHER_ALBUM_TITLE, items } : null;
}

export function mediaType(key: string): "image" | "video" | "other" {
  if (IMAGE_EXT.test(key)) return "image";
  if (VIDEO_EXT.test(key)) return "video";
  return "other";
}

const cachedIndex = new Map<string, { at: number; data: IndexFile }>();

export async function loadIndex(env: Env, lib: string): Promise<IndexFile> {
  const hit = cachedIndex.get(lib);
  if (hit && Date.now() - hit.at < INDEX_CACHE_MS) return hit.data;
  const obj = await env.META.get(`${SYSTEM_PREFIX}index-${lib}.json`);
  const data: IndexFile = obj ? await obj.json<IndexFile>() : { version: 1, albums: [] };
  data.albums ??= [];
  cachedIndex.set(lib, { at: Date.now(), data });
  return data;
}

/** Persist the album index and refresh the in-memory cache entry. */
export async function saveIndex(env: Env, lib: string, index: IndexFile): Promise<void> {
  index.generatedAt = new Date().toISOString();
  await env.META.put(`${SYSTEM_PREFIX}index-${lib}.json`, JSON.stringify(index), {
    httpMetadata: { contentType: "application/json" },
  });
  cachedIndex.set(lib, { at: Date.now(), data: index });
}

// ---------- user albums (shared across libraries) ----------

/** One album entry: `lib` stamps which library's bucket holds the object. */
export interface GlobalAlbumItem extends IndexItem {
  lib: string;
}

export interface GlobalAlbum {
  id: string;
  title: string;
  subtitle?: string;
  items: GlobalAlbumItem[];
}

export interface AlbumsFile {
  version: 1;
  generatedAt?: string;
  albums: GlobalAlbum[];
}

// NOTE: unlike the generated index, this file is mutated by user requests —
// never serve it from a per-isolate cache: a stale snapshot would let a
// read-modify-write clobber entries another isolate just wrote, and would
// keep returning deleted albums. It stays small; always read it fresh.
export async function loadAlbums(env: Env): Promise<AlbumsFile> {
  const obj = await env.META.get(`${SYSTEM_PREFIX}albums.json`);
  const data: AlbumsFile = obj ? await obj.json<AlbumsFile>() : { version: 1, albums: [] };
  data.albums ??= [];
  return data;
}

export async function saveAlbums(env: Env, data: AlbumsFile): Promise<void> {
  data.generatedAt = new Date().toISOString();
  await env.META.put(`${SYSTEM_PREFIX}albums.json`, JSON.stringify(data), {
    httpMetadata: { contentType: "application/json" },
  });
}

/** Read-modify-write the shared albums file with an etag precondition: a
 *  losing writer reloads and retries instead of clobbering a concurrent
 *  mutation from another isolate. */
export async function mutateAlbums(
  env: Env,
  mutate: (data: AlbumsFile) => void | Promise<void>,
): Promise<AlbumsFile> {
  const path = `${SYSTEM_PREFIX}albums.json`;
  for (let attempt = 0; attempt < 8; attempt++) {
    const obj = await env.META.get(path);
    const data: AlbumsFile = obj ? await obj.json<AlbumsFile>() : { version: 1, albums: [] };
    data.albums ??= [];
    await mutate(data);
    data.generatedAt = new Date().toISOString();
    const put = await env.META.put(path, JSON.stringify(data), {
      httpMetadata: { contentType: "application/json" },
      onlyIf: new Headers(obj ? { "if-match": `"${obj.etag}"` } : { "if-none-match": "*" }),
    });
    if (put) return data;
  }
  throw new Error("albums_store_contended");
}

export async function mediaFor(env: Env, origin: string, lib: string, item: IndexItem) {
  const type = mediaType(item.key);
  const thumbKey = item.thumb ?? item.key;
  // Images always decode (the /t/ route falls back to the original). For videos a
  // fallback would serve the video itself to an <img>, so only sign a thumb URL
  // when a real image exists: a declared `thumb`, or a generated `.webp` in META.
  const thumbStored =
    !!item.thumb || !!(await env.META.head(`${SYSTEM_PREFIX}thumbs/${lib}/${thumbKey}.webp`));
  // 画像は /t/ が原本へフォールバックするので常に署名するが、サムネ未生成かは
  // クライアントがバックフィル対象を決められるよう thumbStored で別途伝える。
  const hasThumb = type === "image" ? true : thumbStored;
  const [url, thumbUrl] = await Promise.all([
    signedUrl(env, origin, "m", lib, item.key),
    hasThumb ? signedUrl(env, origin, "t", lib, thumbKey) : null,
  ]);
  return {
    key: item.key,
    lib,
    type,
    url,
    thumbUrl,
    thumbStored,
    note: item.note ?? null,
    createdAt: item.createdAt ?? null,
  };
}
