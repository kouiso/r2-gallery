import { MEDIA_EXT, SYSTEM_PREFIX, TRASH_PREFIX } from "../lib/const";
import type { Env } from "../lib/env";
import { bucketFor } from "../lib/env";
import { corsHeaders, timingSafeEqual } from "../lib/http";
import { sign } from "../lib/sign";

function parseRange(header: string | null): { offset: number; length?: number } | undefined {
  const m = header ? /^bytes=(\d+)-(\d*)$/.exec(header) : null;
  if (!m) return undefined;
  const start = Number(m[1]);
  const end = m[2] ? Number(m[2]) : undefined;
  return end !== undefined && end >= start
    ? { offset: start, length: end - start + 1 }
    : { offset: start };
}

export async function handleMedia(
  req: Request,
  env: Env,
  kind: "m" | "t",
  lib: string,
  key: string,
  url: URL,
) {
  const exp = Number(url.searchParams.get("e") ?? "0");
  const sig = url.searchParams.get("s") ?? "";
  if (!exp || exp < Date.now() / 1000) return new Response("expired", { status: 403 });
  if (!MEDIA_EXT.test(key) || key.startsWith(SYSTEM_PREFIX) || key.startsWith(TRASH_PREFIX)) {
    return new Response("unsupported", { status: 404 });
  }
  const expected = await sign(env, kind, `${lib}:${key}`, exp);
  if (!timingSafeEqual(sig, expected)) return new Response("forbidden", { status: 403 });
  const target = bucketFor(env, lib);
  if (!target) return new Response("not found", { status: 404 });

  const range = kind === "m" ? parseRange(req.headers.get("range")) : undefined;
  let obj: R2ObjectBody | null = null;
  if (kind === "t") obj = await env.META.get(`${SYSTEM_PREFIX}thumbs/${lib}/${key}.webp`);
  if (!obj) obj = await target.bucket.get(key, range ? { range } : undefined);
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
  if (req.method === "HEAD") return new Response(null, { headers });
  if (range && obj.range && "offset" in obj.range) {
    const offset = obj.range.offset ?? 0;
    const length = obj.range.length ?? obj.size - offset;
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${obj.size}`);
    headers.set("content-length", String(length));
    return new Response(obj.body, { status: 206, headers });
  }
  return new Response(obj.body, { headers });
}
