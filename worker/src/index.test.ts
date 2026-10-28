import {
  createExecutionContext,
  env,
  fetchMock,
  SELF,
  waitOnExecutionContext,
} from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

import worker, { forbiddenHost, type Env } from "./index";

declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    LIB_A: R2Bucket;
    LIB_B: R2Bucket;
  }
}

const ORIGIN = "https://example.test";

async function api(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  if (!headers.has("authorization")) headers.set("authorization", "Bearer test-access-token");
  return SELF.fetch(`${ORIGIN}${path}`, { ...init, headers });
}

function b64url(buf: ArrayBuffer): string {
  let s = "";
  for (const b of new Uint8Array(buf)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Same scheme as the worker: HMAC-SHA256 of `${kind}\n${lib}:${key}\n${exp}`. */
async function sign(kind: "m" | "t", lib: string, key: string, exp: number): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode("test-signing-secret"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    k,
    new TextEncoder().encode(`${kind}\n${lib}:${key}\n${exp}`),
  );
  return b64url(mac);
}

const encKey = (key: string) => key.split("/").map(encodeURIComponent).join("/");

async function signedMediaUrl(lib: string, key: string, kind: "m" | "t" = "m", exp?: number) {
  const e = exp ?? Math.floor(Date.now() / 1000) + 600;
  const s = await sign(kind, lib, key, e);
  return `${ORIGIN}/${kind}/${lib}/${encKey(key)}?e=${e}&s=${s}`;
}

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4, 5, 6, 7, 8]);
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1]);
// "RIFF" + size + "WEBP" + "VP8 "
const WEBP = new Uint8Array([
  0x52, 0x49, 0x46, 0x46, 4, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
]);

/**
 * Env whose LIB_A reports `blindKey` as absent on head(), standing in for a concurrent
 * writer that creates the key between the route's existence check and its write.
 */
function headBlindEnv(blindKey: string, blindTimes = Infinity): Env {
  const real = env.LIB_A;
  let left = blindTimes;
  const blind = new Proxy(real, {
    get(target, prop) {
      if (prop === "head") {
        return async (key: string) => {
          if (key === blindKey && left > 0) {
            left--;
            return null;
          }
          return target.head(key);
        };
      }
      const v = Reflect.get(target, prop) as unknown;
      return typeof v === "function" ? (v as (...a: unknown[]) => unknown).bind(target) : v;
    },
  });
  return { ...env, LIB_A: blind } as Env;
}

/** Call the worker in-process with a custom env (SELF always uses the configured one). */
async function direct(path: string, init: RequestInit, e: Env): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("authorization", "Bearer test-access-token");
  const ctx = createExecutionContext();
  const res = await worker.fetch(new Request(`${ORIGIN}${path}`, { ...init, headers }), e, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

async function putObject(lib: string, key: string, body: BodyInit = PNG, type = "image/png") {
  return api(`/v1/${lib}/objects?key=${encodeURIComponent(key)}`, {
    method: "PUT",
    headers: { "content-type": type },
    body,
  });
}

interface Folders {
  prefix: string;
  folders: string[];
  items: {
    key: string;
    type: string;
    size: number;
    url: string;
    thumbUrl: string;
    createdAt: number | null;
  }[];
  cursor: string | null;
}

async function folders(lib: string, prefix = ""): Promise<Folders> {
  const res = await api(`/v1/${lib}/folders?prefix=${encodeURIComponent(prefix)}`);
  expect(res.status).toBe(200);
  return (await res.json()) as Folders;
}

beforeAll(async () => {
  // Seed the index and a read-only library object directly through the bindings.
  await env.META.put(
    ".system/index-a.json",
    JSON.stringify({
      version: 1,
      generatedAt: "2026-01-01T00:00:00Z",
      items: [
        { key: "seed/cover.jpg" },
        { key: "seed/second.jpg" },
        { key: "seed/loose.jpg", note: "unassigned" },
        { key: "seed/clip.mp4" },
        { key: "seed/hls.ts" },
        { key: "note.txt" },
      ],
      albums: [
        {
          id: "album-1",
          title: "Album 1",
          cover: "seed/cover.jpg",
          items: [
            { key: "seed/cover.jpg", note: "first" },
            { key: "seed/second.jpg", note: "second" },
          ],
        },
      ],
    }),
  );
  await env.LIB_A.put("seed/cover.jpg", PNG, { httpMetadata: { contentType: "image/jpeg" } });
  await env.LIB_A.put("seed/second.jpg", PNG, { httpMetadata: { contentType: "image/jpeg" } });
  await env.LIB_A.put("seed/loose.jpg", PNG, { httpMetadata: { contentType: "image/jpeg" } });
  await env.LIB_A.put("seed/clip.mp4", PNG, { httpMetadata: { contentType: "video/mp4" } });
  await env.LIB_A.put("seed/hls.ts", PNG, { httpMetadata: { contentType: "video/MP2T" } });
  await env.LIB_B.put("ro/keep.jpg", PNG, { httpMetadata: { contentType: "image/jpeg" } });
  await env.LIB_A.put("hidden/.system/x.jpg", PNG);
});

describe("auth", () => {
  it("rejects requests without a bearer token", async () => {
    const res = await SELF.fetch(`${ORIGIN}/v1/libraries`);
    expect(res.status).toBe(401);
  });

  it("rejects a wrong token", async () => {
    const res = await SELF.fetch(`${ORIGIN}/v1/libraries`, {
      headers: { authorization: "Bearer nope" },
    });
    expect(res.status).toBe(401);
  });

  it("lists configured libraries with the right token", async () => {
    const res = await api("/v1/libraries");
    expect(res.status).toBe(200);
    const body = (await res.json()) as { libraries: { id: string; readOnly: boolean }[] };
    expect(body.libraries.map((l) => l.id)).toEqual(["a", "b"]);
    expect(body.libraries[1]?.readOnly).toBe(true);
  });

  it("does not require a token for media routes (signature only)", async () => {
    const res = await SELF.fetch(`${ORIGIN}/m/a/seed/cover.jpg?e=1&s=x`);
    expect(res.status).toBe(403);
  });
});

describe("signed media urls", () => {
  it("serves an object with a valid signature", async () => {
    const res = await SELF.fetch(await signedMediaUrl("a", "seed/cover.jpg"));
    expect(res.status).toBe(200);
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(PNG);
    expect(res.headers.get("content-type")).toBe("image/jpeg");
  });

  it("rejects a tampered signature", async () => {
    const url = await signedMediaUrl("a", "seed/cover.jpg");
    const res = await SELF.fetch(url.replace(/s=.{4}/, "s=AAAA"));
    expect(res.status).toBe(403);
  });

  it("rejects a signature minted for a different kind or key", async () => {
    const url = await signedMediaUrl("a", "seed/cover.jpg", "m");
    const asThumb = await SELF.fetch(url.replace("/m/", "/t/"));
    expect(asThumb.status).toBe(403);
    const otherKey = await SELF.fetch(url.replace("cover.jpg", "second.jpg"));
    expect(otherKey.status).toBe(403);
  });

  it("rejects expired urls", async () => {
    const url = await signedMediaUrl("a", "seed/cover.jpg", "m", 1);
    expect((await SELF.fetch(url)).status).toBe(403);
  });

  it("serves byte ranges with 206", async () => {
    const res = await SELF.fetch(await signedMediaUrl("a", "seed/cover.jpg"), {
      headers: { range: "bytes=0-3" },
    });
    expect(res.status).toBe(206);
    expect(res.headers.get("content-range")).toBe(`bytes 0-3/${PNG.length}`);
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(PNG.slice(0, 4));
  });

  it("serves a stored thumbnail when present, else falls back to the original", async () => {
    await env.META.put(".system/thumbs/a/seed/cover.jpg.webp", "WEBPDATA", {
      httpMetadata: { contentType: "image/webp" },
    });
    const t = await SELF.fetch(await signedMediaUrl("a", "seed/cover.jpg", "t"));
    expect(t.status).toBe(200);
    expect(await t.text()).toBe("WEBPDATA");
    const fallback = await SELF.fetch(await signedMediaUrl("a", "seed/second.jpg", "t"));
    expect(fallback.status).toBe(200);
    expect(new Uint8Array(await fallback.arrayBuffer())).toEqual(PNG);
  });
});

describe("albums", () => {
  it("returns the album list with signed covers", async () => {
    const res = await api("/v1/a/albums");
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      albums: { id: string; title: string; count: number; coverUrl: string | null }[];
    };
    expect(body.albums).toHaveLength(2);
    expect(body.albums[0]?.count).toBe(2);
    expect(body.albums[0]?.coverUrl).toMatch(/^https:\/\/example\.test\/t\/a\//);
  });

  it("exposes unassigned index items as the __other__ album", async () => {
    const list = await api("/v1/a/albums");
    const body = (await list.json()) as { albums: { id: string; title: string; count: number }[] };
    const other = body.albums.find((a) => a.id === "__other__");
    expect(other?.title).toBe("その他");
    // loose.jpg, clip.mp4 and hls.ts are unassigned; note.txt is filtered out as non-media.
    expect(other?.count).toBe(3);

    const res = await api("/v1/a/albums/__other__");
    expect(res.status).toBe(200);
    const page = (await res.json()) as {
      items: { key: string; type: string; note: string | null }[];
    };
    expect(page.items.map((i) => i.key)).toEqual([
      "seed/loose.jpg",
      "seed/clip.mp4",
      "seed/hls.ts",
    ]);
    expect(page.items[0]?.note).toBe("unassigned");
    // HLS downloads are uploaded as concatenated .ts — they must list as video, not be dropped.
    expect(page.items.find((i) => i.key === "seed/hls.ts")?.type).toBe("video");
  });

  it("returns a null thumbUrl for videos until a generated thumb exists", async () => {
    const fetchItem = async () => {
      const res = await api("/v1/a/albums/__other__");
      const page = (await res.json()) as {
        items: { key: string; type: string; thumbUrl: string | null }[];
      };
      return page.items.find((i) => i.key === "seed/clip.mp4");
    };

    const before = await fetchItem();
    expect(before?.type).toBe("video");
    expect(before?.thumbUrl).toBeNull();

    await env.META.put(".system/thumbs/a/seed/clip.mp4.webp", PNG, {
      httpMetadata: { contentType: "image/webp" },
    });
    const after = await fetchItem();
    expect(after?.thumbUrl).toMatch(/^https:\/\/example\.test\/t\/a\//);
    expect((await SELF.fetch(after?.thumbUrl ?? "")).status).toBe(200);
  });

  it("paginates album items and signs media urls", async () => {
    const res = await api("/v1/a/albums/album-1?limit=1");
    const page = (await res.json()) as {
      items: { key: string; url: string; note: string | null }[];
      cursor: string | null;
      count: number;
    };
    expect(page.count).toBe(2);
    expect(page.items).toHaveLength(1);
    expect(page.items[0]?.note).toBe("first");
    expect(page.cursor).toBe("1");
    const itemUrl = page.items[0]?.url;
    expect(itemUrl).toBeTruthy();
    expect((await SELF.fetch(itemUrl ?? "")).status).toBe(200);
    const res2 = await api(`/v1/a/albums/album-1?limit=1&cursor=${page.cursor}`);
    const page2 = (await res2.json()) as { items: unknown[]; cursor: string | null };
    expect(page2.items).toHaveLength(1);
    expect(page2.cursor).toBeNull();
  });

  it("404s for an unknown album or library", async () => {
    expect((await api("/v1/a/albums/none")).status).toBe(404);
    expect((await api("/v1/zzz/albums")).status).toBe(404);
  });
});

describe("folders", () => {
  it("lists media items and folders, excluding .system and .trash", async () => {
    await env.LIB_A.put("top.jpg", PNG, { httpMetadata: { contentType: "image/jpeg" } });
    await env.LIB_A.put(".system/dir/secret.jpg", PNG);
    await env.LIB_A.put(".trash/1/old.jpg", PNG);
    await env.LIB_A.put("note.txt", "hello");
    const f = await folders("a");
    expect(f.items.map((i) => i.key)).toContain("top.jpg");
    expect(f.folders).toContain("seed/");
    expect(f.items.some((i) => i.key.includes(".system"))).toBe(false);
    expect(f.items.some((i) => i.key.includes(".trash"))).toBe(false);
    expect(f.items.some((i) => i.key.endsWith(".txt"))).toBe(false);
    expect(f.folders.every((p) => !p.startsWith(".system") && !p.startsWith(".trash"))).toBe(true);
  });

  it("order=recent returns the freshest upload first regardless of key order", async () => {
    // CJK keys sort after every ASCII key lexicographically — a freshly
    // uploaded file named in Japanese must still land on page one.
    await env.LIB_A.put("新しい写真.jpg", PNG, {
      httpMetadata: { contentType: "image/jpeg" },
    });
    const res = await api("/v1/a/folders?prefix=&order=recent");
    expect(res.status).toBe(200);
    const f = (await res.json()) as Folders;
    expect(f.items[0]?.key).toBe("新しい写真.jpg");
  });

  it("order=recent paginates by position cursor, not offset", async () => {
    await env.LIB_A.put("zzz-old.jpg", PNG, { httpMetadata: { contentType: "image/jpeg" } });
    await env.LIB_A.put("aaa-new.jpg", PNG, { httpMetadata: { contentType: "image/jpeg" } });
    const res = await api("/v1/a/folders?prefix=&order=recent");
    const f = (await res.json()) as Folders;
    expect(f.items[0]?.key).toBe("aaa-new.jpg");
    expect(f.items.length).toBeGreaterThan(1);
    // Boundary = the second item: everything strictly after it in the
    // (uploaded desc, key asc) order must be returned — the newest item and
    // anything tied-or-newer stays out, so a client that already rendered
    // the first page never sees a duplicate even if new objects landed.
    const b = f.items[1]!;
    const res2 = await api(
      `/v1/a/folders?prefix=&order=recent&cursor=${encodeURIComponent(`${b.createdAt}|${b.key}`)}`,
    );
    const f2 = (await res2.json()) as Folders;
    const seen = new Set(f.items.slice(0, 2).map((i) => i.key));
    expect(f2.items.some((i) => seen.has(i.key))).toBe(false);
    // An empty/invalid cursor behaves like page one.
    const res3 = await api("/v1/a/folders?prefix=&order=recent&cursor=0%7Ca");
    const f3 = (await res3.json()) as Folders;
    expect(f3.items).toEqual([]);
  });

  it("recursive=1 returns all media under the prefix and no folder list", async () => {
    await env.LIB_A.put("deep/inner/leaf.png", PNG, { httpMetadata: { contentType: "image/png" } });
    const res = await api("/v1/a/folders?prefix=&recursive=1");
    expect(res.status).toBe(200);
    const f = (await res.json()) as Folders;
    expect(f.folders).toEqual([]);
    const keys = f.items.map((i) => i.key);
    expect(keys).toContain("seed/cover.jpg");
    expect(keys).toContain("seed/clip.mp4");
    expect(keys).toContain("seed/hls.ts");
    expect(keys).toContain("deep/inner/leaf.png");
    expect(keys.some((k) => k.startsWith(".system/"))).toBe(false);
    expect(keys.some((k) => k.startsWith(".trash/"))).toBe(false);
    expect(keys.some((k) => k.endsWith(".txt"))).toBe(false);
  });
});

describe("writes", () => {
  it("uploads a small object and refuses overwrite", async () => {
    const res = await putObject("a", "up/one.png");
    expect(res.status).toBe(201);
    const again = await putObject("a", "up/one.png");
    expect(again.status).toBe(409);
    const f = await folders("a", "up/");
    expect(f.items.map((i) => i.key)).toContain("up/one.png");
  });

  it("rejects bad keys", async () => {
    expect((await putObject("a", "../escape.png")).status).toBe(400);
    expect((await putObject("a", ".system/x.png")).status).toBe(400);
    expect((await putObject("a", ".trash/x.png")).status).toBe(400);
  });

  it("returns 403 for every write against a readOnly library", async () => {
    expect((await putObject("b", "x.png")).status).toBe(403);
    expect(
      (
        await api("/v1/b/ops/mkdir", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ prefix: "d" }),
        })
      ).status,
    ).toBe(403);
    expect(
      (
        await api("/v1/b/ops/trash", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ key: "ro/keep.jpg" }),
        })
      ).status,
    ).toBe(403);
    // Copy FROM a readOnly library is allowed, copy TO it is not.
    const fromRo = await api("/v1/ops/copy", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        from: { lib: "b", key: "ro/keep.jpg" },
        to: { lib: "a", key: "up/from-ro.jpg" },
      }),
    });
    expect(fromRo.status).toBe(200);
    const toRo = await api("/v1/ops/copy", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        from: { lib: "a", key: "up/one.png" },
        to: { lib: "b", key: "x.png" },
      }),
    });
    expect(toRo.status).toBe(403);
    // Move out of a readOnly library is forbidden (would delete the source).
    const moveOut = await api("/v1/ops/move", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        from: { lib: "b", key: "ro/keep.jpg" },
        to: { lib: "a", key: "up/m.png" },
      }),
    });
    expect(moveOut.status).toBe(403);
    expect(await env.LIB_B.head("ro/keep.jpg")).not.toBeNull();
  });

  it("copies and moves objects inside a library", async () => {
    const copy = await api("/v1/ops/copy", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        from: { lib: "a", key: "up/one.png" },
        to: { lib: "a", key: "up/two.png" },
      }),
    });
    expect(copy.status).toBe(200);
    const move = await api("/v1/ops/move", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        from: { lib: "a", key: "up/two.png" },
        to: { lib: "a", key: "up/three.png" },
      }),
    });
    expect(move.status).toBe(200);
    const f = await folders("a", "up/");
    const keys = f.items.map((i) => i.key);
    expect(keys).toContain("up/one.png");
    expect(keys).not.toContain("up/two.png");
    expect(keys).toContain("up/three.png");
  });

  it("copies large objects via multipart upload", async () => {
    // MULTIPART_COPY_MIN_BYTES=64 / part=5MiB in wrangler.test.toml, so a 6.5 MiB
    // object is copied in two parts through the multipart code path.
    const big = new Uint8Array(6.5 * 1024 * 1024).map((_, i) => i % 251);
    await env.LIB_A.put("big/src.bin", big, {
      httpMetadata: { contentType: "application/octet-stream" },
    });
    const copy = await api("/v1/ops/copy", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        from: { lib: "a", key: "big/src.bin" },
        to: { lib: "a", key: "big/dst.bin" },
      }),
    });
    expect(copy.status).toBe(200);
    const dst = await env.LIB_A.get("big/dst.bin");
    expect(dst?.size).toBe(big.byteLength);
    expect(new Uint8Array(await dst!.arrayBuffer())).toEqual(big);

    const move = await api("/v1/ops/move", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        from: { lib: "a", key: "big/dst.bin" },
        to: { lib: "a", key: "big/moved.bin" },
      }),
    });
    expect(move.status).toBe(200);
    expect(await env.LIB_A.head("big/dst.bin")).toBeNull();
    expect((await env.LIB_A.head("big/moved.bin"))?.size).toBe(big.byteLength);
  }, 60_000);

  it("runs a multipart upload: create, parts, complete; and abort", async () => {
    const part = new Uint8Array(5 * 1024 * 1024).fill(7);
    const tail = new Uint8Array([1, 2, 3]);

    const create = await api("/v1/a/objects/multipart", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key: "mp/movie.bin", contentType: "video/mp4" }),
    });
    expect(create.status).toBe(201);
    const { uploadId } = (await create.json()) as { uploadId: string };
    expect(uploadId).toBeTruthy();

    const parts: { partNumber: number; etag: string }[] = [];
    for (const [n, body] of [
      [1, part],
      [2, tail],
    ] as const) {
      const res = await api(
        `/v1/a/objects/multipart/part?key=${encodeURIComponent("mp/movie.bin")}&uploadId=${uploadId}&part=${n}`,
        { method: "PUT", headers: { "content-type": "application/octet-stream" }, body },
      );
      expect(res.status).toBe(200);
      parts.push((await res.json()) as { partNumber: number; etag: string });
    }

    const done = await api("/v1/a/objects/multipart/complete", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key: "mp/movie.bin", uploadId, parts }),
    });
    expect(done.status).toBe(201);
    const obj = await env.LIB_A.get("mp/movie.bin");
    expect(obj?.size).toBe(part.byteLength + tail.byteLength);
    expect(obj?.httpMetadata?.contentType).toBe("video/mp4");
    const bytes = new Uint8Array(await obj!.arrayBuffer());
    expect(bytes.slice(0, 4)).toEqual(new Uint8Array([7, 7, 7, 7]));
    expect(bytes.slice(-3)).toEqual(tail);

    // Aborting a second upload leaves no object behind.
    const create2 = await api("/v1/a/objects/multipart", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key: "mp/aborted.bin" }),
    });
    const { uploadId: uid2 } = (await create2.json()) as { uploadId: string };
    const abort = await api("/v1/a/objects/multipart/abort", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key: "mp/aborted.bin", uploadId: uid2 }),
    });
    expect(abort.status).toBe(200);
    expect(await env.LIB_A.head("mp/aborted.bin")).toBeNull();
  });

  it.each(["simple", "multipart"] as const)(
    "lists a newly completed %s video after reload and serves its original byte range",
    async (mode) => {
      const key = `visible-${mode}/合成動画.mp4`;
      const tail = new Uint8Array([11, 22, 33, 44]);
      let expected = tail;
      if (mode === "simple") {
        const saved = await putObject("a", key, tail, "video/mp4");
        expect(saved.status).toBe(201);
        expect(await saved.json()).toMatchObject({ key, size: tail.length });
      } else {
        const create = await api("/v1/a/objects/multipart", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ key, contentType: "video/mp4" }),
        });
        expect(create.status).toBe(201);
        const { uploadId } = (await create.json()) as { uploadId: string };
        const part = new Uint8Array(5 * 1024 * 1024).fill(7);
        expected = new Uint8Array(part.length + tail.length);
        expected.set(part);
        expected.set(tail, part.length);
        const parts: { partNumber: number; etag: string }[] = [];
        for (const [i, bytes] of [part, tail].entries()) {
          const res = await api(
            `/v1/a/objects/multipart/part?key=${encodeURIComponent(key)}&uploadId=${encodeURIComponent(uploadId)}&part=${i + 1}`,
            { method: "PUT", body: bytes },
          );
          expect(res.status).toBe(200);
          parts.push((await res.json()) as { partNumber: number; etag: string });
        }
        const pending = await folders("a", `visible-${mode}/`);
        expect(pending.items.some((item) => item.key === key)).toBe(false);
        const done = await api("/v1/a/objects/multipart/complete", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ key, uploadId, parts }),
        });
        expect(done.status).toBe(201);
        expect(await done.json()).toMatchObject({ key, size: expected.length });
      }

      // 索引に無い新しい動画でも、新しい一覧要求とその署名 URL だけで原本に届くことを確かめる。
      for (let reload = 0; reload < 2; reload++) {
        const res = await api("/v1/a/folders?recursive=1&order=recent");
        expect(res.status).toBe(200);
        const page = (await res.json()) as Folders;
        const matches = page.items.filter((item) => item.key === key);
        expect(matches).toHaveLength(1);
        const item = matches[0]!;
        expect(item).toMatchObject({ type: "video", size: expected.length });
        const media = await SELF.fetch(item.url);
        expect(media.status).toBe(200);
        expect(media.headers.get("content-type")).toBe("video/mp4");
        const actual = await media.arrayBuffer();
        expect(await crypto.subtle.digest("SHA-256", actual)).toEqual(
          await crypto.subtle.digest("SHA-256", expected),
        );
        const range = await SELF.fetch(item.url, {
          headers: { range: `bytes=${expected.length - tail.length}-${expected.length - 1}` },
        });
        expect(range.status).toBe(206);
        expect(range.headers.get("content-range")).toBe(
          `bytes ${expected.length - tail.length}-${expected.length - 1}/${expected.length}`,
        );
        expect(new Uint8Array(await range.arrayBuffer())).toEqual(tail);
      }
      expect((await folders("b", `visible-${mode}/`)).items).toEqual([]);
    },
  );

  it("rejects multipart create on existing keys and on read-only libraries", async () => {
    const dup = await api("/v1/a/objects/multipart", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key: "seed/cover.jpg" }),
    });
    expect(dup.status).toBe(409);
    const ro = await api("/v1/b/objects/multipart", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key: "new.bin" }),
    });
    expect(ro.status).toBe(403);
  });

  describe("never replaces a key created after the existence check", () => {
    const ORIGINAL = new Uint8Array([4, 2, 4, 2]);
    const bytesOf = async (key: string) =>
      new Uint8Array(await (await env.LIB_A.get(key))!.arrayBuffer());

    it("simple upload", async () => {
      const KEY = "race/put.png";
      await env.LIB_A.put(KEY, ORIGINAL);
      const res = await direct(
        `/v1/a/objects?key=${encodeURIComponent(KEY)}`,
        {
          method: "PUT",
          // An in-process Request does not derive content-length from the body like SELF.fetch does.
          headers: { "content-type": "image/png", "content-length": String(PNG.byteLength) },
          body: PNG,
        },
        headBlindEnv(KEY),
      );
      expect(res.status).toBe(409);
      expect(await res.json()).toEqual({ error: "destination_exists" });
      expect(await bytesOf(KEY)).toEqual(ORIGINAL);
    });

    it("copy and move keep both the destination and the move source", async () => {
      const DST = "race/copy-dst.png";
      await env.LIB_A.put(DST, ORIGINAL);
      await env.LIB_A.put("race/copy-src.png", PNG);
      for (const op of ["copy", "move"] as const) {
        const res = await direct(
          `/v1/ops/${op}`,
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              from: { lib: "a", key: "race/copy-src.png" },
              to: { lib: "a", key: DST },
            }),
          },
          headBlindEnv(DST),
        );
        expect(res.status, op).toBe(409);
      }
      expect(await bytesOf(DST)).toEqual(ORIGINAL);
      expect(await bytesOf("race/copy-src.png")).toEqual(PNG);
    });

    it("multipart copy re-checks the destination before completing", async () => {
      // MULTIPART_COPY_MIN_BYTES=64 in wrangler.test.toml routes this through copyMultipart.
      const SRC = "race/mpcopy-src.bin";
      const DST = "race/mpcopy-dst.bin";
      await env.LIB_A.put(SRC, new Uint8Array(100).fill(5));
      await env.LIB_A.put(DST, ORIGINAL);
      const res = await direct(
        "/v1/ops/copy",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ from: { lib: "a", key: SRC }, to: { lib: "a", key: DST } }),
        },
        // Hidden from the up-front check only; visible again at complete time.
        headBlindEnv(DST, 1),
      );
      expect(res.status).toBe(409);
      expect(await bytesOf(DST)).toEqual(ORIGINAL);
    });

    it("multipart complete aborts instead of replacing", async () => {
      const KEY = "race/mp.bin";
      const create = await api("/v1/a/objects/multipart", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ key: KEY }),
      });
      expect(create.status).toBe(201);
      const { uploadId } = (await create.json()) as { uploadId: string };
      const partRes = await api(
        `/v1/a/objects/multipart/part?key=${encodeURIComponent(KEY)}&uploadId=${uploadId}&part=1`,
        { method: "PUT", body: new Uint8Array([9, 9, 9]) },
      );
      const part = (await partRes.json()) as { partNumber: number; etag: string };

      // Another writer lands on the key while the upload is in flight.
      await env.LIB_A.put(KEY, ORIGINAL);

      const done = await api("/v1/a/objects/multipart/complete", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ key: KEY, uploadId, parts: [part] }),
      });
      expect(done.status).toBe(409);
      expect(await bytesOf(KEY)).toEqual(ORIGINAL);
    });
  });

  it("stores a webp thumbnail in META and serves it via /t/", async () => {
    const res = await api("/v1/a/thumb?key=" + encodeURIComponent("seed/cover.jpg"), {
      method: "PUT",
      headers: { "content-type": "image/webp" },
      body: WEBP,
    });
    expect(res.status).toBe(201);
    const head = await env.META.head(".system/thumbs/a/seed/cover.jpg.webp");
    expect(head?.httpMetadata?.contentType).toBe("image/webp");
    const t = await SELF.fetch(await signedMediaUrl("a", "seed/cover.jpg", "t"));
    expect(t.headers.get("content-type")).toBe("image/webp");
    expect(new Uint8Array(await t.arrayBuffer())).toEqual(WEBP);

    const bad = await api("/v1/a/thumb?key=" + encodeURIComponent("x/y.png"), {
      method: "PUT",
      headers: { "content-type": "image/png" },
      body: PNG,
    });
    expect(bad.status).toBe(415);
  });

  it("stores a JPEG thumbnail and serves it via /t/ as image/jpeg", async () => {
    const res = await api("/v1/a/thumb?key=" + encodeURIComponent("seed/cover.jpg"), {
      method: "PUT",
      headers: { "content-type": "image/jpeg" },
      body: JPEG,
    });
    expect(res.status).toBe(201);
    const t = await SELF.fetch(await signedMediaUrl("a", "seed/cover.jpg", "t"));
    expect(t.status).toBe(200);
    expect(t.headers.get("content-type")).toBe("image/jpeg");
    expect(new Uint8Array(await t.arrayBuffer())).toEqual(JPEG);
  });

  it("records the real format when an older app labels a JPEG thumbnail as webp", async () => {
    const res = await api("/v1/a/thumb?key=" + encodeURIComponent("seed/second.jpg"), {
      method: "PUT",
      headers: { "content-type": "image/webp" },
      body: JPEG,
    });
    expect(res.status).toBe(201);
    const t = await SELF.fetch(await signedMediaUrl("a", "seed/second.jpg", "t"));
    expect(t.headers.get("content-type")).toBe("image/jpeg");
  });

  it("refuses thumbnail bytes that are neither JPEG nor WEBP", async () => {
    const res = await api("/v1/a/thumb?key=" + encodeURIComponent("seed/never.jpg"), {
      method: "PUT",
      headers: { "content-type": "image/jpeg" },
      body: PNG,
    });
    expect(res.status).toBe(415);
    expect(await env.META.head(".system/thumbs/a/seed/never.jpg.webp")).toBeNull();
  });

  it("rejects an empty thumbnail body with 411", async () => {
    const res = await api("/v1/a/thumb?key=" + encodeURIComponent("seed/cover.jpg"), {
      method: "PUT",
      headers: { "content-type": "image/webp" },
      body: new Uint8Array(),
    });
    expect(res.status).toBe(411);
  });

  it("rejects a non-image content type with 415 and stores nothing", async () => {
    const res = await api("/v1/a/thumb?key=" + encodeURIComponent("rejected/a.jpg"), {
      method: "PUT",
      headers: { "content-type": "application/octet-stream" },
      body: JPEG,
    });
    expect(res.status).toBe(415);
    expect(await env.META.head(".system/thumbs/a/rejected/a.jpg.webp")).toBeNull();
  });

  it("flips a video to thumbUrl once its thumbnail is uploaded", async () => {
    const item = async () => {
      const page = (await (await api("/v1/a/albums/__other__")).json()) as {
        items: { key: string; thumbUrl: string | null }[];
      };
      return page.items.find((i) => i.key === "seed/clip.mp4");
    };
    await env.META.delete(".system/thumbs/a/seed/clip.mp4.webp");
    expect((await item())?.thumbUrl).toBeNull();
    const put = await api("/v1/a/thumb?key=" + encodeURIComponent("seed/clip.mp4"), {
      method: "PUT",
      headers: { "content-type": "image/webp" },
      body: WEBP,
    });
    expect(put.status).toBe(201);
    expect((await item())?.thumbUrl).toMatch(/^https:\/\/example\.test\/t\/a\//);
  });

  it("mkdir creates a browsable folder", async () => {
    const res = await api("/v1/a/ops/mkdir", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ prefix: "made" }),
    });
    expect(res.status).toBe(201);
    const f = await folders("a");
    expect(f.folders).toContain("made/");
  });
});

describe("trash", () => {
  it("moves objects to .trash, lists them, and restores", async () => {
    await putObject("a", "gone/pic.png");
    const trash = await api("/v1/a/ops/trash", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key: "gone/pic.png" }),
    });
    expect(trash.status).toBe(200);
    const { trashKey } = (await trash.json()) as { trashKey: string };
    expect(trashKey).toMatch(/^\.trash\/\d+\/gone\/pic\.png$/);

    const list = await api("/v1/a/trash");
    const entries = (await list.json()) as {
      items: { trashKey: string; key: string }[];
      retentionDays: number;
    };
    expect(entries.items.map((i) => i.trashKey)).toContain(trashKey);
    // 画面の保持期間の案内は Worker の設定値をそのまま使う
    expect(entries.retentionDays).toBe(30);

    // Trashed objects no longer show up in normal listings.
    const f = await folders("a", "gone/");
    expect(f.items.map((i) => i.key)).not.toContain("gone/pic.png");

    const restore = await api("/v1/a/ops/restore", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ trashKey }),
    });
    expect(restore.status).toBe(200);
    const after = await folders("a", "gone/");
    expect(after.items.map((i) => i.key)).toContain("gone/pic.png");
  });

  it("scheduled purge removes trash older than the retention period", async () => {
    const old = `.trash/${Date.now() - 31 * 86_400_000}/old.png`;
    const fresh = `.trash/${Date.now()}/fresh.png`;
    await env.LIB_A.put(old, PNG);
    await env.LIB_A.put(fresh, PNG);

    const ctx = createExecutionContext();
    const ctrl = {
      cron: "17 3 * * *",
      scheduledTime: Date.now(),
      noRetry: () => undefined,
    } as unknown as ScheduledController;
    await worker.scheduled(ctrl, env);
    await waitOnExecutionContext(ctx);

    expect(await env.LIB_A.head(old)).toBeNull();
    expect(await env.LIB_A.head(fresh)).not.toBeNull();
  });
});

describe("url import", () => {
  const REMOTE = "https://cdn.example.org";

  beforeEach(() => {
    fetchMock.activate();
    fetchMock.disableNetConnect();
    return () => fetchMock.deactivate();
  });

  it("forbiddenHost flags loopback, private ranges, and literals", () => {
    for (const h of [
      "127.0.0.1",
      "10.0.0.5",
      "172.16.0.1",
      "192.168.1.1",
      "169.254.169.254",
      "100.64.0.1",
      "0.0.0.0",
      "localhost",
      "foo.localhost",
      "nas.local",
      "gw.internal",
      "[::1]",
      "[fd00::1]",
    ]) {
      expect(forbiddenHost(h), h).toBe(true);
    }
    for (const h of ["8.8.8.8", "1.1.1.1", "example.com", "cdn.example.org"]) {
      expect(forbiddenHost(h), h).toBe(false);
    }
  });

  const importUrl = (url: string, prefix = "imports") =>
    api("/v1/a/objects/import", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ url, prefix }),
    });

  it("imports a remote image into the library", async () => {
    fetchMock
      .get(REMOTE)
      .intercept({ path: "/img.png" })
      .reply(200, PNG, { headers: { "content-type": "image/png" } });
    const res = await importUrl(`${REMOTE}/img.png`);
    expect(res.status).toBe(201);
    const body = (await res.json()) as { key: string };
    expect(body.key).toBe("imports/img.png");
    const obj = await env.LIB_A.get("imports/img.png");
    expect(new Uint8Array(await obj!.arrayBuffer())).toEqual(PNG);
    expect(obj?.httpMetadata?.contentType).toBe("image/png");
  });

  it("follows a redirect while re-validating each hop", async () => {
    fetchMock
      .get(REMOTE)
      .intercept({ path: "/red" })
      .reply(302, "", { headers: { location: "/img.png" } })
      .times(1);
    fetchMock
      .get(REMOTE)
      .intercept({ path: "/img.png" })
      .reply(200, PNG, { headers: { "content-type": "image/png" } });
    const res = await importUrl(`${REMOTE}/red`, "hop");
    expect(res.status).toBe(201);
    expect((await res.json()) as { key: string }).toHaveProperty("key", "hop/img.png");
  });

  it("rejects a redirect to a private address", async () => {
    fetchMock
      .get(REMOTE)
      .intercept({ path: "/hop" })
      .reply(302, "", { headers: { location: "http://169.254.169.254/meta" } });
    const res = await importUrl(`${REMOTE}/hop`);
    expect(res.status).toBe(400);
  });

  it("rejects private IP urls before fetching", async () => {
    for (const url of [
      "http://169.254.169.254/latest/meta-data",
      "http://192.168.0.1/a.jpg",
      "http://localhost/x.jpg",
      "http://[::1]/x.jpg",
    ]) {
      const res = await importUrl(url);
      expect(res.status, url).toBe(400);
    }
  });

  it("rejects non-media content types and oversized bodies", async () => {
    fetchMock
      .get(REMOTE)
      .intercept({ path: "/text" })
      .reply(200, "<html></html>", { headers: { "content-type": "text/html" } });
    expect((await importUrl(`${REMOTE}/text`)).status).toBe(415);

    fetchMock
      .get(REMOTE)
      .intercept({ path: "/huge" })
      .reply(200, new Uint8Array(2 * 1024 * 1024).fill(1), {
        headers: { "content-type": "image/png" },
      });
    // IMPORT_MAX_BYTES=1MiB in the test config.
    expect((await importUrl(`${REMOTE}/huge`)).status).toBe(413);
  });

  it("refuses to replace an existing key, even if it appears after the existence check", async () => {
    const KEY = "imports/taken.png";
    const ORIGINAL = new Uint8Array([1, 1, 1]);
    await env.LIB_A.put(KEY, ORIGINAL, { httpMetadata: { contentType: "image/png" } });
    fetchMock
      .get(REMOTE)
      .intercept({ path: "/taken.png" })
      .reply(200, PNG, { headers: { "content-type": "image/png" } })
      .times(2);

    expect((await importUrl(`${REMOTE}/taken.png`)).status).toBe(409);
    const raced = await direct(
      "/v1/a/objects/import",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ url: `${REMOTE}/taken.png`, prefix: "imports" }),
      },
      headBlindEnv(KEY),
    );
    expect(raced.status).toBe(409);
    const obj = await env.LIB_A.get(KEY);
    expect(new Uint8Array(await obj!.arrayBuffer())).toEqual(ORIGINAL);
  });

  it("rejects non-http schemes and credentialed URLs", async () => {
    for (const url of [
      "ftp://example.com/a.jpg",
      "file:///etc/passwd",
      "http://user:pw@example.com/a.jpg",
      "notaurl",
    ]) {
      expect((await importUrl(url)).status).toBe(400);
    }
  });
});

/* ---------------- review meta (D1 join) ---------------- */

// Seeds the local (ephemeral) test D1 only — never touches a real database.
// The `!REVIEW_DB` branch (binding absent) is covered by REVIEW_LIBS gating
// tests: with the binding declared in wrangler.test.toml it is unreachable
// here by design.
describe("GET /v1/:lib/meta", () => {
  beforeAll(async () => {
    const db = env.REVIEW_DB;
    if (!db) throw new Error("REVIEW_DB binding missing in test env");
    const stmts = [
      `CREATE TABLE IF NOT EXISTS image_review (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        r2_key TEXT NOT NULL,
        character_id TEXT NOT NULL DEFAULT '',
        label TEXT NOT NULL DEFAULT '',
        round INTEGER NOT NULL DEFAULT 1,
        intent_comment TEXT NOT NULL DEFAULT '',
        ai_panel_json TEXT,
        director_score INTEGER,
        director_comment TEXT,
        verdict TEXT NOT NULL DEFAULT 'pending',
        image_model TEXT,
        seed INTEGER,
        prompt TEXT,
        created_at INTEGER NOT NULL,
        gen_params TEXT
      )`,
      `CREATE TABLE IF NOT EXISTS image_review_criterion (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        review_id INTEGER NOT NULL,
        criterion_key TEXT NOT NULL,
        weight REAL NOT NULL,
        panel_score INTEGER,
        director_score INTEGER,
        is_veto INTEGER NOT NULL DEFAULT 0,
        comment TEXT,
        created_at INTEGER NOT NULL DEFAULT 0
      )`,
      `DELETE FROM image_review`,
      `DELETE FROM image_review_criterion`,
      `INSERT INTO image_review
        (id, r2_key, verdict, round, label, intent_comment, director_score, director_comment, created_at)
      VALUES
        (5, 'seed/cover.jpg', 'rejected', 1, 'style-check', 'first pass', 2, 'redo', 1690000000),
        (7, 'seed/cover.jpg', 'adopted', 2, 'style-check', 'pose fix', 9, 'keep it', 1700000000),
        (9, 'seed/other.jpg', 'pending', 1, 'style-check', '', NULL, NULL, 1700000100)`,
      `INSERT INTO image_review_criterion
        (review_id, criterion_key, weight, panel_score, director_score, is_veto, comment, created_at)
      VALUES
        (7, 'composition', 0.5, 8, 9, 0, 'ok', 1700000000),
        (7, 'consistency', 0.5, 7, NULL, 1, NULL, 1700000000)`,
    ];
    await db.batch(stmts.map((sql) => db.prepare(sql)));
  });

  it("joins the latest review row plus its criteria", async () => {
    const res = await api("/v1/a/meta?key=seed/cover.jpg");
    expect(res.status).toBe(200);
    const { meta } = (await res.json()) as { meta: Record<string, unknown> };
    expect(meta).toMatchObject({
      verdict: "adopted",
      round: 2,
      label: "style-check",
      intentComment: "pose fix",
      directorScore: 9,
      directorComment: "keep it",
      createdAt: 1_700_000_000,
    });
    expect(meta.criteria).toEqual([
      {
        key: "composition",
        weight: 0.5,
        panelScore: 8,
        directorScore: 9,
        veto: false,
        comment: "ok",
      },
      {
        key: "consistency",
        weight: 0.5,
        panelScore: 7,
        directorScore: null,
        veto: true,
        comment: null,
      },
    ]);
  });

  it("returns meta:null for libraries outside REVIEW_LIBS", async () => {
    const res = await api("/v1/b/meta?key=seed/cover.jpg");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ meta: null });
  });

  it("returns meta:null for keys with no review row", async () => {
    const res = await api("/v1/a/meta?key=nope.jpg");
    expect(await res.json()).toEqual({ meta: null });
  });

  it("validates the key parameter", async () => {
    for (const q of ["?key=", "?key=../x.jpg", "?key=.system/x.jpg"]) {
      const res = await api(`/v1/a/meta${q}`);
      expect(res.status, q).toBe(400);
    }
    const res = await api("/v1/nope/meta?key=a.jpg");
    expect(res.status).toBe(404);
  });

  it("requires authorization", async () => {
    const res = await SELF.fetch(`${ORIGIN}/v1/a/meta?key=a.jpg`);
    expect(res.status).toBe(401);
  });
});
