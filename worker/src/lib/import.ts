import { IMPORT_MAX_DEFAULT, MAX_REDIRECTS, MEDIA_EXT } from "./const";
import type { Env } from "./env";
import { HttpError, json, readJson, assertUserKey } from "./http";
import { writable } from "./env";
import { createOnly } from "./objects";

/* ---------------- URL import (SSRF-guarded) ---------------- */

/** Reject loopback/private/link-local/reserved IPv4 literals and all IPv6 literals. */
export function forbiddenHost(host: string): boolean {
  const h = host.toLowerCase().replace(/\.$/, "");
  if (!h) return true;
  if (h === "localhost" || h.endsWith(".localhost")) return true;
  if (/\.(local|internal|lan|home|corp|arpa)$/.test(h)) return true;
  if (h.startsWith("[")) return true; // IPv6 literal: conservative reject
  const m = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(h);
  if (!m) return false; // hostname: relies on fetch-time DNS; literals already normalized
  const [a, b] = [Number(m[1]), Number(m[2])];
  if (a === 0 || a === 10 || a === 127 || a >= 224) return true;
  if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT
  if (a === 169 && b === 254) return true; // link-local
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && (b === 168 || b === 0)) return true;
  if (a === 198 && (b === 18 || b === 19)) return true; // benchmarking
  return false;
}

function assertFetchableUrl(env: Env, raw: string): URL {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new HttpError(400, "bad_url");
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") throw new HttpError(400, "bad_scheme");
  if (u.username || u.password) throw new HttpError(400, "bad_url");
  if (env.IMPORT_ALLOW_PRIVATE !== "1" && forbiddenHost(u.hostname)) {
    throw new HttpError(400, "forbidden_host");
  }
  return u;
}

/** Media extension for a filename, derived from the URL path or content type. */
function importName(pathname: string, contentType: string): string {
  const base =
    decodeURIComponent(pathname.split("/").pop() || "file")
      .replace(/[^\w.-]+/g, "_")
      .replace(/^\.+/, "") || "file";
  if (MEDIA_EXT.test(base)) return base;
  const ext = contentType.startsWith("video/")
    ? `.${(contentType.slice(6).split(";")[0] ?? "").replace("quicktime", "mov")}`
    : `.${(contentType.slice(6).split(";")[0] ?? "").replace("jpeg", "jpg")}`;
  return `${base}${/svg/.test(ext) ? ".png" : ext}`;
}

export async function handleImport(req: Request, env: Env, lib: string): Promise<Response> {
  const { bucket } = writable(env, lib);
  const body = await readJson(req);
  const prefix = String(body.prefix ?? "").replace(/^\/+|\/+$/g, "");
  if (prefix) assertUserKey(`${prefix}/x`); // validate but keep prefix value
  let url = assertFetchableUrl(env, String(body.url ?? ""));

  let res: Response | null = null;
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    try {
      res = await fetch(url.toString(), { redirect: "manual" });
    } catch {
      throw new HttpError(502, "fetch_failed");
    }
    const loc = res.headers.get("location");
    if (
      loc &&
      ((res.status >= 300 && res.status < 400) || (res.type as string) === "opaqueredirect")
    ) {
      if (hop === MAX_REDIRECTS) throw new HttpError(508, "too_many_redirects");
      url = assertFetchableUrl(env, new URL(loc, url).toString());
      res = null;
      continue;
    }
    break;
  }
  if (!res) throw new HttpError(502, "fetch_failed");
  if (!res.ok) throw new HttpError(502, `upstream_${res.status}`);

  const type = ((res.headers.get("content-type") ?? "").split(";")[0] ?? "").toLowerCase();
  if (!type.startsWith("image/") && !type.startsWith("video/")) {
    throw new HttpError(415, "unsupported_media_type");
  }
  if (type === "image/svg+xml") throw new HttpError(415, "unsupported_media_type");
  const max = Number(env.IMPORT_MAX_BYTES ?? IMPORT_MAX_DEFAULT);
  const declared = Number(res.headers.get("content-length") ?? "0");
  if (declared > max) throw new HttpError(413, "too_large");

  const chunks: Uint8Array[] = [];
  let got = 0;
  const reader = res.body?.getReader();
  if (!reader) throw new HttpError(502, "fetch_failed");
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (got + value.byteLength > max) {
      await reader.cancel().catch(() => undefined);
      throw new HttpError(413, "too_large");
    }
    chunks.push(value);
    got += value.byteLength;
  }
  const data = new Uint8Array(got);
  {
    let off = 0;
    for (const c of chunks) {
      data.set(c, off);
      off += c.byteLength;
    }
  }

  const name = importName(url.pathname, type);
  const key = `${prefix ? `${prefix}/` : ""}${name}`;
  if (await bucket.head(key)) throw new HttpError(409, "destination_exists");
  const put = await bucket.put(key, data, {
    httpMetadata: { contentType: type },
    onlyIf: createOnly(),
  });
  if (!put) throw new HttpError(409, "destination_exists");
  return json({ key, size: put.size }, 201);
}
