import type { Env } from "./env";

let cachedKey: { secret: string; key: CryptoKey } | null = null;

async function hmacKey(secret: string): Promise<CryptoKey> {
  if (cachedKey?.secret === secret) return cachedKey.key;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  cachedKey = { secret, key };
  return key;
}

function b64url(buf: ArrayBuffer): string {
  let s = "";
  for (const b of new Uint8Array(buf)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function sign(env: Env, kind: string, key: string, exp: number): Promise<string> {
  const k = await hmacKey(env.SIGNING_SECRET);
  const mac = await crypto.subtle.sign(
    "HMAC",
    k,
    new TextEncoder().encode(`${kind}\n${key}\n${exp}`),
  );
  return b64url(mac);
}

export function encodeKey(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

export async function signedUrl(
  env: Env,
  origin: string,
  kind: "m" | "t",
  lib: string,
  key: string,
): Promise<string> {
  const ttl = Number(env.URL_TTL_SECONDS ?? "3600") || 3600;
  // Round expiry to the TTL window so URLs stay cache-friendly on the device.
  const now = Math.floor(Date.now() / 1000);
  const exp = (Math.floor(now / ttl) + 2) * ttl;
  const s = await sign(env, kind, `${lib}:${key}`, exp);
  return `${origin}/${kind}/${encodeURIComponent(lib)}/${encodeKey(key)}?e=${exp}&s=${s}`;
}
