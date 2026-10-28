import { SYSTEM_PREFIX, TRASH_PREFIX } from "./const";
import type { Env } from "./env";

export class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
  ) {
    super(code);
  }
}

export const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...corsHeaders(),
    },
  });

export function corsHeaders(): Record<string, string> {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, content-type",
    "access-control-allow-methods": "GET, POST, PUT, DELETE, OPTIONS",
    "access-control-max-age": "86400",
  };
}

/** Keys users may address directly: no traversal, no reserved prefixes, sane length. */
export function assertUserKey(key: unknown): string {
  if (typeof key !== "string" || !key || key.length > 1024) throw new HttpError(400, "bad_key");
  if (key.startsWith("/") || key.split("/").some((p) => p === "" || p === "." || p === "..")) {
    throw new HttpError(400, "bad_key");
  }
  if (key.startsWith(SYSTEM_PREFIX) || key.startsWith(TRASH_PREFIX)) {
    throw new HttpError(400, "reserved_key");
  }
  return key;
}

export async function readJson(req: Request): Promise<Record<string, unknown>> {
  try {
    const v = await req.json();
    if (v && typeof v === "object") return v as Record<string, unknown>;
  } catch {
    /* fallthrough */
  }
  throw new HttpError(400, "bad_json");
}

export const ref = (v: unknown): { lib: unknown; key: unknown } =>
  v && typeof v === "object" ? (v as { lib: unknown; key: unknown }) : { lib: null, key: null };

export function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  let diff = ab.length ^ bb.length;
  const len = Math.max(ab.length, bb.length);
  for (let i = 0; i < len; i++) diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  return diff === 0;
}

export function isAuthorized(req: Request, env: Env): boolean {
  if (!env.ACCESS_TOKEN) return false;
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  return !!match?.[1] && timingSafeEqual(match[1].trim(), env.ACCESS_TOKEN);
}
