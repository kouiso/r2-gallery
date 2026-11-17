import { env } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

import type { Env } from "./lib/env";
import { signedUrl } from "./lib/sign";
import { handleMedia } from "./routes/media";

declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    LIB_A: R2Bucket;
    LIB_B: R2Bucket;
  }
}

const KEY = "startup-probe/clip.mp4";
const EMPTY = "startup-probe/empty.mp4";
const SIZE = 256 * 1024;
const DATA = Uint8Array.from({ length: SIZE }, (_, i) => i % 251);

type ReadCall = { method: "head" | "get"; key: string; options?: R2GetOptions };

function counted(bucket: R2Bucket) {
  const calls: ReadCall[] = [];
  const proxy = new Proxy(bucket, {
    get(target, property) {
      if (property === "head") {
        return (key: string) => {
          calls.push({ method: "head", key });
          return target.head(key);
        };
      }
      if (property === "get") {
        return (key: string, options?: R2GetOptions) => {
          calls.push({ method: "get", key, options });
          return target.get(key, options);
        };
      }
      const value = Reflect.get(target, property) as unknown;
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return { bucket: proxy, calls };
}

async function request(init: RequestInit = {}, key = KEY, kind: "m" | "t" = "m") {
  const original = counted(env.LIB_A);
  const meta = counted(env.META);
  const e = { ...env, LIB_A: original.bucket, META: meta.bucket } as Env;
  const url = new URL(await signedUrl(e, "https://startup.test", kind, "a", key));
  const response = await handleMedia(new Request(url, init), e, kind, "a", key, url);
  return { response, original: original.calls, meta: meta.calls };
}

beforeAll(async () => {
  await env.LIB_A.put(KEY, DATA, { httpMetadata: { contentType: "video/mp4" } });
  await env.LIB_A.put(EMPTY, new Uint8Array(0), {
    httpMetadata: { contentType: "video/mp4" },
  });
});

describe("signed video startup HTTP probes", () => {
  it("returns only the requested suffix with one ranged R2 read", async () => {
    const { response, original, meta } = await request({ headers: { range: "bytes=-4" } });
    const body = new Uint8Array(await response.arrayBuffer());
    console.log(
      JSON.stringify({
        probe: "suffix-4",
        status: response.status,
        bytes: body.length,
        original,
        meta,
      }),
    );
    expect(response.status).toBe(206);
    expect(response.headers.get("content-range")).toBe(`bytes ${SIZE - 4}-${SIZE - 1}/${SIZE}`);
    expect(response.headers.get("content-length")).toBe("4");
    expect(body).toEqual(DATA.slice(-4));
    expect(original).toEqual([{ method: "get", key: KEY, options: { range: { suffix: 4 } } }]);
    expect(meta).toEqual([]);
  });

  it("answers HEAD from metadata without creating an R2 body stream", async () => {
    const { response, original, meta } = await request({ method: "HEAD" });
    console.log(JSON.stringify({ probe: "head", status: response.status, original, meta }));
    expect(response.status).toBe(200);
    expect(original).toEqual([{ method: "head", key: KEY }]);
    expect(meta).toEqual([]);
    expect(response.headers.get("content-length")).toBe(String(SIZE));
    expect(response.headers.get("content-type")).toBe("video/mp4");
    expect(response.headers.get("etag")).toBeTruthy();
    expect(response.headers.get("accept-ranges")).toBe("bytes");
    expect(response.headers.get("access-control-allow-origin")).toBe("*");
    expect(response.headers.get("cache-control")).toBe("private, max-age=86400");
    expect(await response.text()).toBe("");
  });

  it("ignores Range on HEAD and retains the full representation metadata", async () => {
    const { response, original } = await request({
      method: "HEAD",
      headers: { range: "bytes=0-3", "if-range": '"old-etag"' },
    });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-length")).toBe(String(SIZE));
    expect(response.headers.get("content-range")).toBeNull();
    expect(original).toEqual([{ method: "head", key: KEY }]);
    expect(await response.text()).toBe("");
  });

  it("retains the same ETag and representation length for GET and HEAD", async () => {
    const get = await request();
    const head = await request({ method: "HEAD" });
    expect(head.response.headers.get("etag")).toBe(get.response.headers.get("etag"));
    expect(get.response.headers.get("content-length")).toBe(String(SIZE));
    expect((await get.response.arrayBuffer()).byteLength).toBe(SIZE);
    expect(await head.response.text()).toBe("");
  });

  it.each([
    ["bytes=0-3", 0, 4],
    [`bytes=${SIZE - 4}-`, SIZE - 4, 4],
    [`bytes=${SIZE - 4}-${SIZE + 100}`, SIZE - 4, 4],
    [`bytes=-${SIZE + 100}`, 0, SIZE],
  ])("clamps valid range %s to actual returned bytes", async (range, offset, length) => {
    const { response, original } = await request({ headers: { range } });
    expect(response.status).toBe(206);
    expect(response.headers.get("content-range")).toBe(
      `bytes ${offset}-${offset + length - 1}/${SIZE}`,
    );
    expect(response.headers.get("content-length")).toBe(String(length));
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(
      DATA.slice(offset, offset + length),
    );
    expect(original).toHaveLength(1);
  });

  it.each([
    ["bytes=-0", KEY, SIZE],
    [`bytes=${SIZE}-`, KEY, SIZE],
    ["bytes=0-3", EMPTY, 0],
  ])("returns 416 for unsatisfiable %s on %s", async (range, key, size) => {
    const { response } = await request({ headers: { range } }, key);
    expect(response.status).toBe(416);
    expect(response.headers.get("content-range")).toBe(`bytes */${size}`);
    expect((await response.arrayBuffer()).byteLength).toBe(0);
  });

  it("keeps unsupported multi-range requests as a full streamed response", async () => {
    const { response, original } = await request({ headers: { range: "bytes=0-3,8-9" } });
    expect(response.status).toBe(200);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(DATA);
    expect(original).toEqual([{ method: "get", key: KEY, options: undefined }]);
  });

  it("uses metadata reads for thumbnail HEAD and fallback too", async () => {
    const thumbKey = `.system/thumbs/a/${KEY}.webp`;
    const fallback = await request({ method: "HEAD" }, KEY, "t");
    expect(fallback.response.status).toBe(200);
    expect(fallback.meta).toEqual([{ method: "head", key: thumbKey }]);
    expect(fallback.original).toEqual([{ method: "head", key: KEY }]);
    await env.META.put(thumbKey, new Uint8Array([1, 2, 3]), {
      httpMetadata: { contentType: "image/webp" },
    });
    const stored = await request({ method: "HEAD" }, KEY, "t");
    expect(stored.response.status).toBe(200);
    expect(stored.response.headers.get("content-length")).toBe("3");
    expect(stored.meta).toEqual([{ method: "head", key: thumbKey }]);
    expect(stored.original).toEqual([]);
  });

  it("validates the signature before any R2 HEAD or GET", async () => {
    const original = counted(env.LIB_A);
    const e = { ...env, LIB_A: original.bucket } as Env;
    const url = new URL(await signedUrl(e, "https://startup.test", "m", "a", KEY));
    url.searchParams.set("s", "tampered");
    const response = await handleMedia(new Request(url, { method: "HEAD" }), e, "m", "a", KEY, url);
    expect(response.status).toBe(403);
    expect(original.calls).toEqual([]);
  });

  it("does not turn an unrelated R2 failure for a valid range into 416", async () => {
    const failure = new Error("local fixture R2 unavailable");
    const bucket = new Proxy(env.LIB_A, {
      get(target, property) {
        if (property === "get")
          return async () => {
            throw failure;
          };
        const value = Reflect.get(target, property) as unknown;
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    const e = { ...env, LIB_A: bucket } as Env;
    const url = new URL(await signedUrl(e, "https://startup.test", "m", "a", KEY));
    const req = new Request(url, { headers: { range: "bytes=0-3" } });
    await expect(handleMedia(req, e, "m", "a", KEY, url)).rejects.toBe(failure);
  });
});
