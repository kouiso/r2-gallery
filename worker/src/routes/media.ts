import { JPEG_COPY_EXT, MEDIA_EXT, SYSTEM_PREFIX, TRASH_PREFIX } from "../lib/const";
import { jpegCopy, THUMB_EDGE, VIEW_EDGE } from "../lib/jpeg-copy";
import { dropThumbBestEffort } from "../lib/objects";
import { journalBestEffort } from "../lib/catalog";
import type { Env } from "../lib/env";
import { bucketFor } from "../lib/env";
import { corsHeaders, timingSafeEqual } from "../lib/http";
import { sign } from "../lib/sign";

function parseRange(header: string | null): R2Range | undefined {
  const suffix = header ? /^bytes=-(\d+)$/.exec(header) : null;
  if (suffix) {
    const length = Number(suffix[1]);
    return Number.isSafeInteger(length) ? { suffix: length } : undefined;
  }
  const m = header ? /^bytes=(\d+)-(\d*)$/.exec(header) : null;
  if (!m) return undefined;
  const start = Number(m[1]);
  const end = m[2] ? Number(m[2]) : undefined;
  if (!Number.isSafeInteger(start) || (end !== undefined && !Number.isSafeInteger(end))) {
    return undefined;
  }
  if (end !== undefined && end < start) return undefined;
  return end !== undefined ? { offset: start, length: end - start + 1 } : { offset: start };
}

function unsatisfiable(range: R2Range, size: number): boolean {
  return size === 0 || ("suffix" in range ? range.suffix === 0 : (range.offset ?? 0) >= size);
}

function hasBody(obj: R2Object): obj is R2ObjectBody {
  return "body" in obj;
}

export async function handleMedia(
  req: Request,
  env: Env,
  kind: "m" | "t" | "v",
  lib: string,
  key: string,
  url: URL,
) {
  const exp = Number(url.searchParams.get("e") ?? "0");
  const sig = url.searchParams.get("s") ?? "";
  if (!exp || exp < Date.now() / 1000) return new Response("expired", { status: 403 });
  if (
    !MEDIA_EXT.test(key) ||
    key.startsWith(SYSTEM_PREFIX) ||
    key.startsWith(TRASH_PREFIX) ||
    (kind === "v" && !JPEG_COPY_EXT.test(key))
  ) {
    return new Response("unsupported", { status: 404 });
  }
  const expected = await sign(env, kind, `${lib}:${key}`, exp);
  if (!timingSafeEqual(sig, expected)) return new Response("forbidden", { status: 403 });
  const target = bucketFor(env, lib);
  if (!target) return new Response("not found", { status: 404 });

  const headOnly = req.method === "HEAD";

  // JPEG の写しの共通ヘッダ。/v/ と /t/ の写しは原本と同じ情報を別の形で返すので
  // cache-control は原本と同じ 1 日、etag は原本の etag に枝を足す
  const jpegResponse = (copy: Uint8Array, etagSuffix: string, etag: string) => {
    const headers = new Headers(corsHeaders());
    headers.set("content-type", "image/jpeg");
    headers.set("cache-control", "private, max-age=86400");
    headers.set("x-content-type-options", "nosniff");
    headers.set("etag", `"${etag}-${etagSuffix}"`);
    headers.set("content-length", String(copy.length));
    return new Response(copy.buffer as ArrayBuffer, { headers });
  };

  // /v/ は署名の kind で分ける。写しは毎回作って返し、保存しない。range は見ない
  if (kind === "v") {
    const orig = headOnly ? await target.bucket.head(key) : await target.bucket.get(key);
    if (!orig) return new Response("not found", { status: 404 });
    if (headOnly) {
      const headers = new Headers(corsHeaders());
      headers.set("content-type", "image/jpeg");
      return new Response(null, { headers });
    }
    const copy = hasBody(orig) ? await jpegCopy(env, orig, VIEW_EDGE) : null;
    if (copy) return jpegResponse(copy, "v", orig.etag);
    // 写しが作れない時は原本を返すが、期限だけ短くする。一時の失敗（9422 等）の
    // 答えを端末が1日持つと、直った後も壊れた絵のままになるため
    const headers = new Headers(corsHeaders());
    orig.writeHttpMetadata(headers);
    headers.set("etag", orig.httpEtag);
    headers.set("cache-control", "private, max-age=60");
    headers.set("x-content-type-options", "nosniff");
    if (!headers.get("content-type")) headers.set("content-type", "application/octet-stream");
    headers.set("content-length", String(orig.size));
    return new Response(hasBody(orig) ? orig.body : null, { headers });
  }

  const range = kind === "m" && !headOnly ? parseRange(req.headers.get("range")) : undefined;
  let obj: R2Object | R2ObjectBody | null = null;
  if (kind === "t") {
    const thumbKey = `${SYSTEM_PREFIX}thumbs/${lib}/${key}.webp`;
    obj = headOnly ? await env.META.head(thumbKey) : await env.META.get(thumbKey);
    // サムネが無く binding が在る時は、HEIC 系の原本から JPEG を作って返し、
    // 次からは保存済みとして速く出せるようサムネの置き場に残す
    if (!obj && !headOnly && JPEG_COPY_EXT.test(key) && env.IMAGES) {
      const orig = await target.bucket.get(key);
      if (!orig) return new Response("not found", { status: 404 });
      const copy = await jpegCopy(env, orig, THUMB_EDGE);
      if (copy) {
        try {
          await env.META.put(thumbKey, copy, {
            httpMetadata: { contentType: "image/jpeg" },
          });
          // 原本が作り直されていた時は残した写しが古い原本の物になるので消す
          const cur = await target.bucket.head(key);
          if (!cur || cur.etag !== orig.etag) {
            await dropThumbBestEffort(env, lib, key);
          } else {
            await journalBestEffort(env, lib, { thumb: [key] });
          }
        } catch (e) {
          console.error("thumb_store_failed", lib, key, e);
        }
        return jpegResponse(copy, "t", orig.etag);
      }
      // 写しが作れなかった時は下の今の道（原本を取り直して返す）へ進む
    }
  }
  if (!obj) {
    try {
      // HEAD の本文は使わないため、原本のストリームを作らずメタ情報だけを取る。
      obj = headOnly
        ? await target.bucket.head(key)
        : await target.bucket.get(key, range ? { range } : undefined);
    } catch (error) {
      if (!range) throw error;
      // 通常の Range は GET 一回で返す。範囲外の時だけ大きさを調べ、R2 の例外を HTTP 416 にする。
      obj = await target.bucket.head(key);
      if (!obj || !unsatisfiable(range, obj.size)) throw error;
    }
  }
  if (!obj) return new Response("not found", { status: 404 });

  // Signed media is fetched cross-origin (thumb cache, native webviews), so it
  // needs the same CORS headers as the JSON routes.
  const headers = new Headers(corsHeaders());
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  headers.set("cache-control", "private, max-age=86400");
  headers.set("x-content-type-options", "nosniff");
  if (!headers.get("content-type")) headers.set("content-type", "application/octet-stream");
  headers.set("accept-ranges", "bytes");
  const body = hasBody(obj) ? obj.body : null;
  if (range && unsatisfiable(range, obj.size)) {
    await body?.cancel();
    headers.set("content-range", `bytes */${obj.size}`);
    return new Response(null, { status: 416, headers });
  }
  headers.set("content-length", String(obj.size));
  if (headOnly) return new Response(null, { headers });
  if (range && obj.range) {
    const returned = obj.range;
    const offset =
      "offset" in returned && returned.offset !== undefined
        ? returned.offset
        : "suffix" in range
          ? Math.max(0, obj.size - range.suffix)
          : 0;
    const length =
      "length" in returned && returned.length !== undefined ? returned.length : obj.size - offset;
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${obj.size}`);
    headers.set("content-length", String(length));
    return new Response(body, { status: 206, headers });
  }
  return new Response(body, { headers });
}
