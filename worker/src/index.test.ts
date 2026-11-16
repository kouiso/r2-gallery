import {
  createExecutionContext,
  env,
  fetchMock,
  SELF,
  waitOnExecutionContext,
} from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { resetCatalogMemory } from "./lib/catalog";
import { purgeTrash } from "./lib/objects";
import worker, { forbiddenHost, type Env } from "./index";
import { ALLOWED_METHODS } from "./lib/http";

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

describe("CORS preflight", () => {
  // 本番の Pages オリジンはリポジトリに無く、worker は allow-origin を "*" で返す設計。
  // よって任意のオリジンで検証する（特定オリジンは作り話になるため置かない）。
  const preflight = (method: string) =>
    SELF.fetch(`${ORIGIN}/v1/lib-a/albums/x`, {
      method: "OPTIONS",
      headers: {
        origin: "https://web.example.test",
        "access-control-request-method": method,
        "access-control-request-headers": "authorization, content-type",
      },
    });
  const list = (v: string | null) => (v ?? "").split(",").map((m) => m.trim().toLowerCase());

  // クライアントが実際に使う全メソッドを許可しないと、Web 版でブラウザが本リクエスト自体を送らない（#54）
  it.each(["GET", "POST", "PUT", "PATCH", "DELETE"])("allows %s", async (method) => {
    const res = await preflight(method);
    expect(res.status).toBe(204);
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
    const allowed = list(res.headers.get("access-control-allow-methods"));
    expect(allowed).toContain(method.toLowerCase());
    expect(allowed).toContain("options");
    const headers = list(res.headers.get("access-control-allow-headers"));
    expect(headers).toContain("authorization");
    expect(headers).toContain("content-type");
  });

  // 入口の方法拒否が通すメソッドは全部 CORS にも出ること（一覧を二重管理しない回帰防止）。
  // GET/HEAD/POST は単純メソッドで事前確認は不要だが、一覧を一本化しているので全て並ぶのが正。
  it("lists every method the entry guard accepts", async () => {
    const allowed = list((await preflight("PATCH")).headers.get("access-control-allow-methods"));
    for (const m of ALLOWED_METHODS) expect(allowed).toContain(m.toLowerCase());
  });

  // アプリが付ける独自ヘッダが許可に無いと、Web 版だけ事前確認で止まる
  it("allows every custom header the app sends", async () => {
    const allowed = list((await preflight("PUT")).headers.get("access-control-allow-headers"));
    for (const h of ["authorization", "content-type", "x-content-sha256"]) {
      expect(allowed).toContain(h);
    }
  });
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

  describe("sort=new|old|name|size は全件に対して並べ、カーソルで続きを返す (#44)", () => {
    const N = 205; // 1ページ(200件)を超える件数で、2ページ目の位置が崩れないことを確かめる
    const sorts = ["new", "old", "name", "size"] as const;
    type Sort = (typeof sorts)[number];

    interface Row {
      key: string;
      size: number;
      uploaded: number;
    }

    beforeAll(async () => {
      for (let i = 0; i < N; i++) {
        // 大文字小文字の混在・同サイズ・同時刻を含め、同値の決め手(key)も確かめる
        const name = `${i % 3 === 0 ? "B" : "a"}${String((i * 37) % N).padStart(3, "0")}.jpg`;
        await env.LIB_A.put(`sortbig/${name}`, new Uint8Array(((i * 7) % 50) + 1), {
          httpMetadata: { contentType: "image/jpeg" },
        });
      }
    });

    async function expected(sort: Sort): Promise<string[]> {
      const rows: Row[] = [];
      let cursor: string | undefined;
      do {
        const l = await env.LIB_A.list({ prefix: "sortbig/", cursor });
        for (const o of l.objects)
          rows.push({ key: o.key, size: o.size, uploaded: o.uploaded.getTime() });
        cursor = l.truncated ? l.cursor : undefined;
      } while (cursor);
      const base = (k: string) => k.split("/").pop()!.toLowerCase();
      const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
      rows.sort((a, b) => {
        const c =
          sort === "new"
            ? b.uploaded - a.uploaded
            : sort === "old"
              ? a.uploaded - b.uploaded
              : sort === "size"
                ? b.size - a.size
                : cmp(base(a.key), base(b.key));
        return c || cmp(a.key, b.key);
      });
      return rows.map((r) => r.key);
    }

    async function walk(
      sort: Sort,
      query = "",
    ): Promise<{ keys: string[]; pages: number; echoed: (string | undefined)[] }> {
      const keys: string[] = [];
      const echoed: (string | undefined)[] = [];
      let cursor: string | null = null;
      let pages = 0;
      do {
        const q: string = `/v1/a/folders?prefix=sortbig/&sort=${sort}${query}${
          cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""
        }`;
        const res = await api(q);
        expect(res.status).toBe(200);
        const body = (await res.json()) as Folders & { sort?: string };
        echoed.push(body.sort);
        keys.push(...body.items.map((i) => i.key));
        cursor = body.cursor;
        pages++;
      } while (cursor);
      return { keys, pages, echoed };
    }

    for (const sort of sorts) {
      it(`sort=${sort}: ライブラリ全体がその順で、続きのページも重複・欠けなしで出る`, async () => {
        const { keys, pages, echoed } = await walk(sort);
        // 並びの比較を先にする。返し値の確認が先だと、順序のバグが返し値の失敗に隠れる
        expect(keys).toEqual(await expected(sort));
        expect(pages).toBe(2);
        expect(echoed).toEqual([sort, sort]);
      });
    }

    it("recursive=1 でも同じ順で続きが取れる(写真タブの経路)", async () => {
      const { keys } = await walk("size", "&recursive=1");
      expect(keys.filter((k) => k.startsWith("sortbig/"))).toEqual(await expected("size"));
    });

    it("sort が無い order=recent だけの古いアプリは、新しい順のまま", async () => {
      const res = await api("/v1/a/folders?prefix=sortbig/&order=recent");
      const body = (await res.json()) as Folders & { sort?: string };
      expect(body.items.map((i) => i.key)).toEqual((await expected("new")).slice(0, 200));
    });

    it("知らない sort は 400", async () => {
      const res = await api("/v1/a/folders?prefix=sortbig/&sort=random");
      expect(res.status).toBe(400);
    });
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

  it("drops the source key's thumbnail after a move", async () => {
    await env.LIB_A.put("mv1/src.png", PNG, { httpMetadata: { contentType: "image/png" } });
    await env.META.put(".system/thumbs/a/mv1/src.png.webp", WEBP);
    const move = await api("/v1/ops/move", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        from: { lib: "a", key: "mv1/src.png" },
        to: { lib: "a", key: "mv1/dst.png" },
      }),
    });
    expect(move.status).toBe(200);
    // 元の key は無いので、そのサムネは孤児。消えていなければならない
    expect(await env.META.head(".system/thumbs/a/mv1/src.png.webp")).toBeNull();
    expect(await env.LIB_A.head("mv1/src.png")).toBeNull();
    expect(await env.LIB_A.head("mv1/dst.png")).not.toBeNull();
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

  describe("album membership", () => {
    const post = (path: string, body: unknown) =>
      api(path, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
    const trash = async (key: string) =>
      ((await (await post("/v1/a/ops/trash", { key })).json()) as { trashKey: string }).trashKey;
    const restore = (trashKey: string) => post("/v1/a/ops/restore", { trashKey });
    const items = async (id: string) =>
      ((await (await api("/v1/a/albums/" + id)).json()) as { items: { key: string }[] }).items.map(
        (i) => i.key,
      );
    // 各テストが固有のプレフィックスを使い、他のテストのアルバムと混ざらないようにする
    async function mkAlbum(prefix: string, names: string[]) {
      const keys = names.map((n) => `${prefix}/${n}.png`);
      for (const k of keys) await putObject("a", k);
      const { id } = (await (await post("/v1/a/albums", { title: prefix })).json()) as {
        id: string;
      };
      await post(`/v1/a/albums/${id}/items`, { keys });
      return { id, keys };
    }

    it("restores the album membership when restoring from trash", async () => {
      const { id, keys } = await mkAlbum("m1", ["one", "two"]);
      const tk = await trash(keys[0]!);
      expect(await items(id)).toEqual([keys[1]]);
      expect((await restore(tk)).status).toBe(200);
      expect(await items(id)).toEqual(keys);
    });

    it("keeps the album order when several items are trashed then restored one by one", async () => {
      const { id, keys } = await mkAlbum("m2", ["1", "2", "3"]);
      const tks = [await trash(keys[0]!), await trash(keys[1]!), await trash(keys[2]!)];
      expect(await items(id)).toEqual([]);
      for (const tk of tks) expect((await restore(tk)).status).toBe(200);
      expect(await items(id)).toEqual(keys);
    });

    it("keeps the album order for non-adjacent items and for concurrent trash batches", async () => {
      const { id, keys } = await mkAlbum("m3", ["A", "B", "C", "D"]);
      const tks = await Promise.all([trash(keys[0]!), trash(keys[2]!)]);
      expect(await items(id)).toEqual([keys[1], keys[3]]);
      for (const tk of tks) expect((await restore(tk)).status).toBe(200);
      expect(await items(id)).toEqual(keys);
      // 逆順で戻しても同じ並びになる
      const again = await Promise.all([trash(keys[0]!), trash(keys[2]!)]);
      for (const tk of [...again].reverse()) await restore(tk);
      expect(await items(id)).toEqual(keys);
    });

    it("改行を含む key でも、ゴミ箱から元の場所とアルバムへ戻る", async () => {
      const { id, keys } = await mkAlbum("m6", ["line\nbreak", "ok"]);
      const tk = await trash(keys[0]!);
      expect(await items(id)).toEqual([keys[1]]);
      expect((await restore(tk)).status).toBe(200);
      expect(await items(id)).toEqual(keys);
      const f = await folders("a", "m6/");
      expect(f.items.map((i) => i.key)).toContain(keys[0]);
    });

    it("restores into every album the item was in", async () => {
      const x = await mkAlbum("m4", ["p", "q"]);
      const y = (await (await post("/v1/a/albums", { title: "m4b" })).json()) as { id: string };
      await post(`/v1/a/albums/${y.id}/items`, { keys: [x.keys[1]] });
      const tk = await trash(x.keys[1]!);
      expect(await items(x.id)).toEqual([x.keys[0]]);
      expect(await items(y.id)).toEqual([]);
      await restore(tk);
      expect(await items(x.id)).toEqual(x.keys);
      expect(await items(y.id)).toEqual([x.keys[1]]);
    });

    it("skips an album deleted between trash and restore", async () => {
      const { id, keys } = await mkAlbum("m5", ["a", "b"]);
      const tk = await trash(keys[0]!);
      expect((await api(`/v1/a/albums/${id}`, { method: "DELETE" })).status).toBeLessThan(300);
      const res = await restore(tk);
      expect(res.status).toBe(200);
      const after = await folders("a", "m5/");
      expect(after.items.map((i) => i.key)).toContain(keys[0]);
      expect((await api(`/v1/a/albums/${id}`)).status).toBe(404);
    });

    it("does not duplicate an item that is already back in the album at restore", async () => {
      const { id, keys } = await mkAlbum("m6", ["a", "b"]);
      const tk = await trash(keys[0]!);
      // 戻す前に同じ物が入り直した状態：実体を戻し、手動でアルバムへ追加する
      await env.LIB_A.put(keys[0]!, PNG);
      await env.LIB_A.delete(tk);
      await post(`/v1/a/albums/${id}/items`, { keys: [keys[0]] });
      expect((await restore(tk)).status).toBe(200);
      expect((await items(id)).filter((k) => k === keys[0])).toHaveLength(1);
    });

    const trashOrderOf = async (id: string) => {
      const f = (await (await env.META.get(".system/albums.json"))!.json()) as {
        albums: { id: string; trashOrder?: string[] }[];
      };
      return f.albums.find((a) => a.id === id)?.trashOrder;
    };
    // 期限切れ purge と同じ状態：.trash の実体だけ消える（控えは残る）
    const purge = (tk: string) => env.LIB_A.delete(tk);

    it("keeps the album order when 8 items are trashed concurrently then restored in turn", async () => {
      const { id, keys } = await mkAlbum(
        "m9",
        Array.from({ length: 10 }, (_, n) => String(n)),
      );
      const tks = await Promise.all(keys.slice(1, 9).map((k) => trash(k)));
      expect(await items(id)).toEqual([keys[0], keys[9]]);
      for (const tk of tks) expect((await restore(tk)).status).toBe(200);
      expect(await items(id)).toEqual(keys);
      expect(await trashOrderOf(id)).toBeUndefined();
    });

    it("drops purged and removed keys from trashOrder so it stays bounded", async () => {
      const { id, keys } = await mkAlbum("m10", ["a", "b", "c", "d"]);
      const ta = await trash(keys[0]!);
      expect(await trashOrderOf(id)).toEqual(keys.map((k) => `a:${k}`));
      // a は戻さないまま purge された
      await purge(ta);
      const tb = await trash(keys[1]!);
      // a は落ち、今ゴミ箱にいる b と残っている c, d だけが残る
      expect(await trashOrderOf(id)).toEqual(keys.slice(1).map((k) => `a:${k}`));
      // アルバムから外した物も落ちる
      await post(`/v1/a/albums/${id}/items/remove`, { keys: [keys[2]] });
      expect(await trashOrderOf(id)).toEqual([keys[1], keys[3]].map((k) => `a:${k}`));
      expect((await restore(tb)).status).toBe(200);
      expect(await items(id)).toEqual([keys[1], keys[3]]);
      expect(await trashOrderOf(id)).toBeUndefined();
    });

    it("keeps the slot of a restore whose file was already moved back when another edit prunes", async () => {
      const { id, keys } = await mkAlbum("m13", ["a", "b", "c", "d"]);
      const tb = await trash(keys[1]!);
      // 前回の restore はファイルを戻した後に落ちた状態
      await env.LIB_A.put(keys[1]!, PNG);
      await env.LIB_A.delete(tb);
      // 同じアルバムへの無関係な操作が刈り込みを走らせる
      await post(`/v1/a/albums/${id}/items/remove`, { keys: [keys[3]] });
      expect((await restore(tb)).status).toBe(200);
      expect(await items(id)).toEqual([keys[0], keys[1], keys[2]]);
    });

    it("keeps the slot of a resumed restore when another item is trashed in the same album", async () => {
      const { id, keys } = await mkAlbum("m14", ["a", "b", "c", "d"]);
      const tb = await trash(keys[1]!);
      await env.LIB_A.put(keys[1]!, PNG);
      await env.LIB_A.delete(tb);
      await trash(keys[3]!);
      expect((await restore(tb)).status).toBe(200);
      expect(await items(id)).toEqual([keys[0], keys[1], keys[2]]);
    });

    it("clears trashOrder when nothing is left in the trash", async () => {
      const { id, keys } = await mkAlbum("m11", ["a", "b"]);
      const ta = await trash(keys[0]!);
      await purge(ta);
      await post(`/v1/a/albums/${id}/items/remove`, { keys: [keys[1]] });
      expect(await trashOrderOf(id)).toBeUndefined();
    });

    it("restores into the right place in an album of 2000 items", async () => {
      const keys = Array.from({ length: 2000 }, (_, n) => `big/${String(n).padStart(4, "0")}.png`);
      const cur = await env.META.get(".system/albums.json");
      const file = (cur ? await cur.json() : { version: 1, albums: [] }) as {
        version: 1;
        albums: unknown[];
      };
      file.albums.push({
        id: "m12",
        title: "big",
        items: keys.map((key) => ({ key, lib: "a", createdAt: 1 })),
      });
      await env.META.put(".system/albums.json", JSON.stringify(file));
      for (const k of [keys[3]!, keys[1000]!, keys[1999]!]) await env.LIB_A.put(k, PNG);
      const tks = await Promise.all([keys[3]!, keys[1000]!, keys[1999]!].map((k) => trash(k)));
      // 一覧 API はページ分けされるので、albums.json を直接読む
      const keysOf = async () => {
        const f = (await (await env.META.get(".system/albums.json"))!.json()) as {
          albums: { id: string; items: { key: string }[] }[];
        };
        return f.albums.find((a) => a.id === "m12")!.items.map((i) => i.key);
      };
      expect((await keysOf()).length).toBe(1997);
      for (const tk of tks) await restore(tk);
      expect(await keysOf()).toEqual(keys);
    });

    it("leaves albums untouched when restoring an item trashed without a record", async () => {
      const { id, keys } = await mkAlbum("m7", ["a", "b"]);
      // 修正前にゴミ箱へ送った物：実体だけ .trash にあり、控えは無い。アルバムには別の物が入っている
      await env.LIB_A.put(".trash/123/m7/legacy.png", PNG);
      const before = await items(id);
      const res = await restore(".trash/123/m7/legacy.png");
      expect(res.status).toBe(200);
      expect(await items(id)).toEqual(before);
      expect(await items(id)).toEqual(keys);
      expect(await env.LIB_A.head("m7/legacy.png")).not.toBeNull();
      expect(await env.LIB_A.head(".trash/123/m7/legacy.png")).toBeNull();
    });

    it("resumes a restore whose file move already happened", async () => {
      const { id, keys } = await mkAlbum("m8", ["a", "b"]);
      const tk = await trash(keys[0]!);
      // 前回はファイルを戻した後にアルバム更新で失敗した状態を作る
      await env.LIB_A.put(keys[0]!, PNG);
      await env.LIB_A.delete(tk);
      expect(await items(id)).toEqual([keys[1]]);
      expect((await restore(tk)).status).toBe(200);
      expect(await items(id)).toEqual(keys);
      expect(
        await env.META.head(`.system/trash-albums/a/${tk.slice(".trash/".length)}.json`),
      ).toBeNull();
    });
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

describe("stale thumbnails", () => {
  const thumbKey = (k: string) => `.system/thumbs/a/${k}.webp`;
  const trashPurge = async () => {
    const ctx = createExecutionContext();
    const ctrl = {
      cron: "17 3 * * *",
      scheduledTime: Date.now(),
      noRetry: () => undefined,
    } as unknown as ScheduledController;
    await worker.scheduled(ctrl, env);
    await waitOnExecutionContext(ctx);
  };

  it("purge removes the thumbnail of an expired trash entry", async () => {
    await env.LIB_A.put(`.trash/${Date.now() - 31 * 86_400_000}/gone/old.png`, PNG);
    await env.META.put(thumbKey("gone/old.png"), "OLD");
    await trashPurge();
    expect(await env.META.head(thumbKey("gone/old.png"))).toBeNull();
  });

  it("purge removes an expired trash entry whose key contains a newline, and its thumbnail", async () => {
    // assertUserKey は改行を許すので、`.` が改行に当たらない正規表現だと永久に消えない
    const original = "nl/line1\nline2.png";
    const tk = `.trash/${Date.now() - 31 * 86_400_000}/${original}`;
    await env.LIB_A.put(tk, PNG);
    await env.META.put(thumbKey(original), "OLD");
    await trashPurge();
    expect(await env.LIB_A.head(tk)).toBeNull();
    expect(await env.META.head(thumbKey(original))).toBeNull();
  });

  it("purge keeps the thumbnail while a same-name object has been re-uploaded", async () => {
    await env.LIB_A.put(`.trash/${Date.now() - 31 * 86_400_000}/again/pic.png`, PNG);
    await env.LIB_A.put("again/pic.png", PNG);
    await env.META.put(thumbKey("again/pic.png"), "NEW");
    await trashPurge();
    expect(await env.META.head(thumbKey("again/pic.png"))).not.toBeNull();
  });

  it("purge keeps the thumbnail of a fresh trash entry (restore needs it)", async () => {
    await env.LIB_A.put(`.trash/${Date.now()}/keep/pic.png`, PNG);
    await env.META.put(thumbKey("keep/pic.png"), "KEEP");
    await trashPurge();
    expect(await env.META.head(thumbKey("keep/pic.png"))).not.toBeNull();
  });

  it("simple upload drops a stale thumbnail of the same name", async () => {
    await env.META.put(thumbKey("re/up.png"), "OLD");
    expect((await putObject("a", "re/up.png")).status).toBe(201);
    expect(await env.META.head(thumbKey("re/up.png"))).toBeNull();
  });

  it("multipart complete drops a stale thumbnail of the same name", async () => {
    await env.META.put(thumbKey("re/mp.mp4"), "OLD");
    const create = await api("/v1/a/objects/multipart", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key: "re/mp.mp4", contentType: "video/mp4" }),
    });
    const { uploadId } = (await create.json()) as { uploadId: string };
    const p = await api(
      `/v1/a/objects/multipart/part?key=${encodeURIComponent("re/mp.mp4")}&uploadId=${uploadId}&part=1`,
      {
        method: "PUT",
        headers: { "content-type": "application/octet-stream" },
        body: new Uint8Array([1, 2, 3]),
      },
    );
    const part = (await p.json()) as { partNumber: number; etag: string };
    const done = await api("/v1/a/objects/multipart/complete", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ key: "re/mp.mp4", uploadId, parts: [part] }),
    });
    expect(done.status).toBe(201);
    expect(await env.META.head(thumbKey("re/mp.mp4"))).toBeNull();
  });

  const post = (path: string, body: unknown) =>
    api(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });

  it("copy drops a stale thumbnail of the destination name", async () => {
    await env.LIB_A.put("cp/src.png", PNG);
    await env.META.put(thumbKey("cp/dst.png"), "OLD");
    const res = await post("/v1/ops/copy", {
      from: { lib: "a", key: "cp/src.png" },
      to: { lib: "a", key: "cp/dst.png" },
    });
    expect(res.status).toBe(200);
    expect(await env.META.head(thumbKey("cp/dst.png"))).toBeNull();
  });

  it("move drops a stale thumbnail of the destination name", async () => {
    await env.LIB_A.put("mv/src.png", PNG);
    await env.META.put(thumbKey("mv/dst.png"), "OLD");
    const res = await post("/v1/ops/move", {
      from: { lib: "a", key: "mv/src.png" },
      to: { lib: "a", key: "mv/dst.png" },
    });
    expect(res.status).toBe(200);
    expect(await env.META.head(thumbKey("mv/dst.png"))).toBeNull();
  });

  it("purge keeps the thumbnail when an expired and a fresh trash entry share a name", async () => {
    const oldKey = `.trash/${Date.now() - 31 * 86_400_000}/dup/pic.png`;
    const freshKey = `.trash/${Date.now()}/dup/pic.png`;
    await env.LIB_A.put(oldKey, PNG);
    await env.LIB_A.put(freshKey, PNG);
    await env.META.put(thumbKey("dup/pic.png"), "FRESH");
    await trashPurge();
    expect(await env.META.head(thumbKey("dup/pic.png"))).not.toBeNull();
    expect(await env.LIB_A.head(oldKey)).toBeNull();
    expect(await env.LIB_A.head(freshKey)).not.toBeNull();
  });

  it("purge deletes thumbnails before objects, so an interrupted run can be retried", async () => {
    const dieKey = `.trash/${Date.now() - 31 * 86_400_000}/die/pic.png`;
    await env.LIB_A.put(dieKey, PNG);
    await env.META.put(thumbKey("die/pic.png"), "OLD");
    const spy = vi.spyOn(env.LIB_A, "delete").mockRejectedValueOnce(new Error("boom"));
    try {
      await expect(purgeTrash(env)).rejects.toThrow();
    } finally {
      spy.mockRestore();
    }
    // 本体の削除で落ちても、サムネは先に消えている（孤児にならない）
    expect(await env.META.head(thumbKey("die/pic.png"))).toBeNull();
    await trashPurge();
    expect(await env.LIB_A.head(dieKey)).toBeNull();
  });

  it("a thumbnail delete failure does not turn a stored upload into a 5xx", async () => {
    const spy = vi.spyOn(env.META, "delete").mockRejectedValue(new Error("meta down"));
    try {
      const up = await putObject("a", "ok/up.png");
      expect(up.status).toBe(201);
      await env.LIB_A.put("ok/src.png", PNG);
      const cp = await post("/v1/ops/copy", {
        from: { lib: "a", key: "ok/src.png" },
        to: { lib: "a", key: "ok/cp.png" },
      });
      expect(cp.status).toBe(200);
      const mv = await post("/v1/ops/move", {
        from: { lib: "a", key: "ok/src.png" },
        to: { lib: "a", key: "ok/mv.png" },
      });
      expect(mv.status).toBe(200);
    } finally {
      spy.mockRestore();
    }
    expect(await env.LIB_A.head("ok/up.png")).not.toBeNull();
    expect(await env.LIB_A.head("ok/cp.png")).not.toBeNull();
    expect(await env.LIB_A.head("ok/mv.png")).not.toBeNull();
    expect(await env.LIB_A.head("ok/src.png")).toBeNull();
  });

  it("multipart complete still returns 201 when the thumbnail delete fails", async () => {
    const create = await post("/v1/a/objects/multipart", {
      key: "ok/mp.mp4",
      contentType: "video/mp4",
    });
    const { uploadId } = (await create.json()) as { uploadId: string };
    const p = await api(
      `/v1/a/objects/multipart/part?key=${encodeURIComponent("ok/mp.mp4")}&uploadId=${uploadId}&part=1`,
      {
        method: "PUT",
        headers: { "content-type": "application/octet-stream" },
        body: new Uint8Array([1, 2, 3]),
      },
    );
    const part = (await p.json()) as { partNumber: number; etag: string };
    const spy = vi.spyOn(env.META, "delete").mockRejectedValue(new Error("meta down"));
    try {
      const done = await post("/v1/a/objects/multipart/complete", {
        key: "ok/mp.mp4",
        uploadId,
        parts: [part],
      });
      expect(done.status).toBe(201);
    } finally {
      spy.mockRestore();
    }
    expect(await env.LIB_A.head("ok/mp.mp4")).not.toBeNull();
  });

  it("purge makes progress batch by batch even if a run dies midway", async () => {
    // 他のテストの残りより必ず先に並ぶよう、十分古い時刻にする
    const base = Date.now() - 90 * 86_400_000;
    const names = [0, 1, 2, 3, 4].map((i) => `batch/p${i}.png`);
    const trashKeys = names.map((n, i) => `.trash/${base + i}/${n}`);
    for (const [i, tk] of trashKeys.entries()) {
      await env.LIB_A.put(tk, PNG);
      await env.META.put(thumbKey(names[i]!), "OLD");
    }
    const orig = env.META.delete.bind(env.META);
    let calls = 0;
    const spy = vi.spyOn(env.META, "delete").mockImplementation(async (k) => {
      calls += 1;
      // 2件ずつの batch の 2 つ目で落とす
      if (calls === 3) throw new Error("subrequest limit");
      return orig(k);
    });
    try {
      await expect(purgeTrash(env, 2)).rejects.toThrow();
    } finally {
      spy.mockRestore();
    }
    // 済んだ batch は本体まで消え、落ちた batch 以降は残る
    expect(await env.LIB_A.head(trashKeys[0]!)).toBeNull();
    expect(await env.LIB_A.head(trashKeys[1]!)).toBeNull();
    expect(await env.LIB_A.head(trashKeys[2]!)).not.toBeNull();
    // 次の実行は残りだけを片付ける
    await purgeTrash(env, 2);
    for (const [i, tk] of trashKeys.entries()) {
      expect(await env.LIB_A.head(tk)).toBeNull();
      expect(await env.META.head(thumbKey(names[i]!))).toBeNull();
    }
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

  it("import drops a stale thumbnail and survives a thumbnail delete failure", async () => {
    await env.META.put(".system/thumbs/a/imports/th.png.webp", "OLD");
    fetchMock
      .get(REMOTE)
      .intercept({ path: "/th.png" })
      .reply(200, PNG, { headers: { "content-type": "image/png" } });
    expect((await importUrl(`${REMOTE}/th.png`)).status).toBe(201);
    expect(await env.META.head(".system/thumbs/a/imports/th.png.webp")).toBeNull();

    fetchMock
      .get(REMOTE)
      .intercept({ path: "/th2.png" })
      .reply(200, PNG, { headers: { "content-type": "image/png" } });
    const spy = vi.spyOn(env.META, "delete").mockRejectedValue(new Error("meta down"));
    try {
      expect((await importUrl(`${REMOTE}/th2.png`)).status).toBe(201);
    } finally {
      spy.mockRestore();
    }
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

/* ---------------- 一覧の索引（catalog） ---------------- */

// 既存のテストは毎回索引を作り直す設定(0)で走る。ここでは本番と同じ「使い回す」設定にする
const cachedEnv = (over: Partial<Env> = {}): Env =>
  ({ ...env, CATALOG_MAX_AGE_SECONDS: "300", ...over }) as Env;

interface Listing {
  sort: string;
  total: number;
  folders: string[];
  items: { key: string; size: number; thumbUrl: string | null; thumbStored: boolean }[];
  cursor: string | null;
}

async function listAll(query: string, e: Env = cachedEnv()): Promise<Listing["items"]> {
  const out: Listing["items"] = [];
  let cursor: string | null = null;
  do {
    const res = await direct(
      `/v1/a/folders?${query}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`,
      {},
      e,
    );
    expect(res.status).toBe(200);
    const page = (await res.json()) as Listing;
    out.push(...page.items);
    cursor = page.cursor;
  } while (cursor);
  return out;
}

const keysOf = async (query: string, e?: Env) => (await listAll(query, e)).map((i) => i.key);
const jsonPost = (path: string, body: unknown, e: Env = cachedEnv()) =>
  direct(
    path,
    { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) },
    e,
  );
// worker.fetch を直に呼ぶと content-length が付かないので、ここで付ける
const putBytes = (path: string, body: Uint8Array, headers: Record<string, string>) =>
  direct(
    path,
    { method: "PUT", headers: { "content-length": String(body.byteLength), ...headers }, body },
    cachedEnv(),
  );
const putVia = (key: string, body: Uint8Array = PNG, headers: Record<string, string> = {}) =>
  putBytes(`/v1/a/objects?key=${encodeURIComponent(key)}`, body, {
    "content-type": "image/png",
    ...headers,
  });
const putThumbVia = (key: string) =>
  putBytes(`/v1/a/thumb?key=${encodeURIComponent(key)}`, WEBP, { "content-type": "image/webp" });
/** 索引を今の R2 の中身で作り直す（毎回作り直す設定で 1 回読む） */
const rebuildNow = () => listAll("recursive=1&sort=new&prefix=__none__/", env as Env);

describe("一覧の索引", () => {
  it("作った後の一覧は、バケットを列挙し直さない", async () => {
    await rebuildNow();
    // 別の isolate が受けた時と同じく、手元の写しが無い所から読ませる
    resetCatalogMemory();
    const list = vi.spyOn(env.LIB_A, "list");
    try {
      const first = await direct("/v1/a/folders?recursive=1&sort=new", {}, cachedEnv());
      const page = (await first.json()) as Listing;
      expect(page.items.length).toBeGreaterThan(0);
      expect(page.total).toBeGreaterThanOrEqual(page.items.length);
      await direct(
        `/v1/a/folders?recursive=1&sort=new&cursor=${encodeURIComponent(page.cursor ?? "")}`,
        {},
        cachedEnv(),
      );
      expect(list).not.toHaveBeenCalled();
    } finally {
      list.mockRestore();
    }
  });

  it("Worker 経由の書き込みは、作り直さなくても次の一覧に出る", async () => {
    await rebuildNow();
    const list = vi.spyOn(env.LIB_A, "list");
    try {
      const q = "recursive=1&sort=name&prefix=cat1/";
      expect((await putVia("cat1/a.png")).status).toBe(201);
      expect((await putVia("cat1/b.png")).status).toBe(201);
      expect(await keysOf(q)).toEqual(["cat1/a.png", "cat1/b.png"]);

      const moved = await jsonPost("/v1/ops/move", {
        from: { lib: "a", key: "cat1/b.png" },
        to: { lib: "a", key: "cat1/c.png" },
      });
      expect(moved.status).toBe(200);
      const copied = await jsonPost("/v1/ops/copy", {
        from: { lib: "a", key: "cat1/a.png" },
        to: { lib: "a", key: "cat1/d.png" },
      });
      expect(copied.status).toBe(200);
      expect(await keysOf(q)).toEqual(["cat1/a.png", "cat1/c.png", "cat1/d.png"]);

      const trashed = await jsonPost("/v1/a/ops/trash", { key: "cat1/a.png" });
      const { trashKey } = (await trashed.json()) as { trashKey: string };
      expect(await keysOf(q)).toEqual(["cat1/c.png", "cat1/d.png"]);
      expect((await jsonPost("/v1/a/ops/restore", { trashKey })).status).toBe(200);
      expect(await keysOf(q)).toEqual(["cat1/a.png", "cat1/c.png", "cat1/d.png"]);
      expect(list).not.toHaveBeenCalled();
    } finally {
      list.mockRestore();
    }
  });

  it("サムネの有無は索引から答え、1 件ずつ確かめない", async () => {
    await rebuildNow();
    expect((await putVia("cat2/pic.png")).status).toBe(201);
    const q = "recursive=1&sort=name&prefix=cat2/";
    expect((await listAll(q))[0]?.thumbStored).toBe(false);
    expect((await putThumbVia("cat2/pic.png")).status).toBe(201);
    const head = vi.spyOn(env.META, "head");
    try {
      expect((await listAll(q))[0]?.thumbStored).toBe(true);
      expect(head).not.toHaveBeenCalled();
    } finally {
      head.mockRestore();
    }
    // 同名で上げ直すと古いサムネは消えるので、索引も「無い」に戻る
    const { trashKey } = (await (
      await jsonPost("/v1/a/ops/trash", { key: "cat2/pic.png" })
    ).json()) as { trashKey: string };
    expect(trashKey).toBeTruthy();
    expect((await putVia("cat2/pic.png", JPEG)).status).toBe(201);
    expect((await listAll(q))[0]?.thumbStored).toBe(false);
  });

  it("ゴミ箱から戻した物は、残っていたサムネごと索引に戻る", async () => {
    await rebuildNow();
    expect((await putVia("cat3/pic.png")).status).toBe(201);
    expect((await putThumbVia("cat3/pic.png")).status).toBe(201);
    const { trashKey } = (await (
      await jsonPost("/v1/a/ops/trash", { key: "cat3/pic.png" })
    ).json()) as { trashKey: string };
    await jsonPost("/v1/a/ops/restore", { trashKey });
    const q = "recursive=1&sort=name&prefix=cat3/";
    expect((await listAll(q)).map((i) => [i.key, i.thumbStored])).toEqual([["cat3/pic.png", true]]);
  });

  it("R2 に直接置かれた物は、作り直すまで出ず、古くなれば裏で作り直して次から出る", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    try {
      await rebuildNow();
      await env.LIB_A.put("cat4/direct.png", PNG);
      const q = "recursive=1&sort=name&prefix=cat4/";
      expect(await keysOf(q)).toEqual([]);
      // 引っ張って更新しても、作ったばかりの索引は作り直さない
      expect(await keysOf(`${q}&fresh=1`)).toEqual([]);

      vi.setSystemTime(Date.now() + 11_000);
      expect(await keysOf(`${q}&fresh=1`)).toEqual(["cat4/direct.png"]);

      await env.LIB_A.put("cat4/later.png", PNG);
      vi.setSystemTime(Date.now() + 301_000);
      // 古い索引のまま答え、作り直しは応答の後に走る
      expect(await keysOf(q)).toEqual(["cat4/direct.png"]);
      expect(await keysOf(q)).toEqual(["cat4/direct.png", "cat4/later.png"]);
    } finally {
      vi.useRealTimers();
      // 進めた時計で作った索引は「未来の物」になり、この後の作り直しを止めてしまう
      await env.META.delete(".system/catalog/a.json");
      resetCatalogMemory();
    }
  });

  it("日次の cron が索引を作り直す", async () => {
    await rebuildNow();
    await env.LIB_A.put("cat5/direct.png", PNG);
    const ctrl = {
      cron: "17 3 * * *",
      scheduledTime: Date.now(),
    } as unknown as ScheduledController;
    await worker.scheduled(ctrl, cachedEnv());
    expect(await keysOf("recursive=1&sort=name&prefix=cat5/")).toEqual(["cat5/direct.png"]);
  });

  it("索引への追記に失敗してもアップロードは成功し、その key を直に引けば見つかる", async () => {
    await rebuildNow();
    const real = env.META.put.bind(env.META);
    const spy = vi
      .spyOn(env.META, "put")
      .mockImplementation(((k: string, ...rest: unknown[]) =>
        k.startsWith(".system/catalog/")
          ? Promise.reject(new Error("meta down"))
          : (real as (...a: unknown[]) => unknown)(k, ...rest)) as typeof env.META.put);
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      expect((await putVia("cat6/up.png")).status).toBe(201);
      expect(log).toHaveBeenCalledWith("catalog_journal_failed", "a", expect.anything());
    } finally {
      spy.mockRestore();
      log.mockRestore();
    }
    // アプリが「上げた物が今あるか」を確かめる口（直下・key を接頭辞にする）
    const res = await direct("/v1/a/folders?prefix=cat6%2Fup.png&order=recent", {}, cachedEnv());
    expect(((await res.json()) as Listing).items.map((i) => i.key)).toEqual(["cat6/up.png"]);
  });

  it(".system と .trash を飛ばしても、その前後の名前の物は落とさない", async () => {
    const names = ["!bang.png", ".alpha.png", ".system0.png", ".tz.png", ".zeta.png", "~end.png"];
    for (const n of names) await env.LIB_A.put(n, PNG);
    await env.LIB_A.put(".trash/1/gone.png", PNG);
    await env.META.put(".system/thumbs/a/x.png.webp", WEBP);
    await rebuildNow();
    const all = await keysOf("recursive=1&sort=name");
    for (const n of names) expect(all, n).toContain(n);
    expect(all.some((k) => k.startsWith(".system/") || k.startsWith(".trash/"))).toBe(false);
    for (const n of names) await env.LIB_A.delete(n);
    await env.LIB_A.delete(".trash/1/gone.png");
  });

  it("1000 件を超えるフォルダの直下も、索引から全件を並べて返す", async () => {
    const N = 1003;
    for (let i = 0; i < N; i += 50) {
      await Promise.all(
        Array.from({ length: Math.min(50, N - i) }, (_, j) =>
          env.LIB_A.put(`catbig/${String(i + j).padStart(4, "0")}.png`, new Uint8Array(1)),
        ),
      );
    }
    await env.LIB_A.put("catbig/sub/inner.png", PNG);
    await env.LIB_A.put("catbig/empty/.keep", new Uint8Array(0));
    await rebuildNow();
    const first = await direct("/v1/a/folders?prefix=catbig%2F&sort=name", {}, cachedEnv());
    const page = (await first.json()) as Listing;
    expect(page.total).toBe(N);
    expect(page.folders).toEqual(["catbig/empty/", "catbig/sub/"]);
    const keys = await keysOf("prefix=catbig%2F&sort=name");
    expect(keys.length).toBe(N);
    expect(keys[0]).toBe("catbig/0000.png");
    expect(keys[N - 1]).toBe(`catbig/${String(N - 1).padStart(4, "0")}.png`);
    expect(new Set(keys).size).toBe(N);
  });

  it(
    "予約の接頭辞が 1 ページを超えても、その中へ入らずに飛ばして続きを拾う",
    { timeout: 60_000 },
    async () => {
      // META と同じバケットをライブラリにしている構成では、.system/ の下に本体と同じ数の
      // サムネがある。1000 件を超える分を飛ばせることを、list の呼ばれ方まで見て確かめる
      for (let i = 0; i < 1100; i += 100) {
        await Promise.all(
          Array.from({ length: 100 }, (_, j) =>
            env.LIB_A.put(
              `.system/skipme/${String(i + j).padStart(4, "0")}.webp`,
              new Uint8Array(1),
            ),
          ),
        );
      }
      await env.LIB_A.put("!before-system.png", PNG);
      await env.LIB_A.put("zz-after-system.png", PNG);
      const list = vi.spyOn(env.LIB_A, "list");
      try {
        await rebuildNow();
        const jumps = list.mock.calls.filter(
          ([o]) => typeof o?.startAfter === "string" && o.startAfter.startsWith(".system/"),
        );
        expect(jumps.length).toBeGreaterThanOrEqual(1);
        // 飛ばさなければ .system/ だけで 2 回余計に呼ぶ
        const within = list.mock.calls.filter(([o]) => !o?.prefix).length;
        const all = await keysOf("recursive=1&sort=name");
        expect(all).toContain("!before-system.png");
        expect(all).toContain("zz-after-system.png");
        expect(all.some((k) => k.startsWith(".system/"))).toBe(false);
        expect(within).toBeGreaterThan(0);
      } finally {
        list.mockRestore();
        await env.LIB_A.delete(["!before-system.png", "zz-after-system.png"]);
      }
    },
  );

  it("作り直すと、索引に入った追記は消え、一覧は変わらない", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    try {
      await rebuildNow();
      expect((await putVia("cat7/a.png")).status).toBe(201);
      expect((await putVia("cat7/b.png")).status).toBe(201);
      await jsonPost("/v1/a/ops/trash", { key: "cat7/a.png" });
      const journal = async () =>
        (await env.META.list({ prefix: ".system/catalog/a/j/" })).objects.length;
      expect(await journal()).toBeGreaterThanOrEqual(3);
      vi.setSystemTime(Date.now() + 60_000);
      const ctrl = {
        cron: "17 3 * * *",
        scheduledTime: Date.now(),
      } as unknown as ScheduledController;
      await worker.scheduled(ctrl, cachedEnv());
      expect(await journal()).toBe(0);
      // 追記が消えた後、手元の写しを持つ isolate も、持たない isolate も同じ一覧を返す
      expect(await keysOf("recursive=1&sort=name&prefix=cat7/")).toEqual(["cat7/b.png"]);
      resetCatalogMemory();
      expect(await keysOf("recursive=1&sort=name&prefix=cat7/")).toEqual(["cat7/b.png"]);
    } finally {
      vi.useRealTimers();
      await env.META.delete(".system/catalog/a.json");
      resetCatalogMemory();
    }
  });

  it("ゴミ箱の掃除が落ちても、cron は索引を作り直す", async () => {
    await rebuildNow();
    await env.LIB_A.put("cat8/direct.png", PNG);
    const spy = vi.spyOn(env.LIB_A, "delete").mockRejectedValue(new Error("boom"));
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    await env.LIB_A.put(`.trash/${Date.now() - 40 * 86_400_000}/cat8/old.png`, PNG);
    try {
      const ctrl = {
        cron: "17 3 * * *",
        scheduledTime: Date.now(),
      } as unknown as ScheduledController;
      await worker.scheduled(ctrl, cachedEnv());
      expect(log).toHaveBeenCalledWith("trash_purge_failed", expect.anything());
    } finally {
      spy.mockRestore();
      log.mockRestore();
    }
    expect(await keysOf("recursive=1&sort=name&prefix=cat8/")).toEqual(["cat8/direct.png"]);
  });

  it("索引が読めなくても、直下の一覧（上げた物の存在確認）は答える", async () => {
    await rebuildNow();
    expect((await putVia("cat9/up.png")).status).toBe(201);
    resetCatalogMemory();
    const real = env.META.get.bind(env.META);
    const spy = vi
      .spyOn(env.META, "get")
      .mockImplementation(((k: string, ...rest: unknown[]) =>
        k.startsWith(".system/catalog/")
          ? Promise.reject(new Error("meta down"))
          : (real as (...a: unknown[]) => unknown)(k, ...rest)) as typeof env.META.get);
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const res = await direct("/v1/a/folders?prefix=cat9%2Fup.png&order=recent", {}, cachedEnv());
      expect(res.status).toBe(200);
      expect(((await res.json()) as Listing).items.map((i) => i.key)).toEqual(["cat9/up.png"]);
    } finally {
      spy.mockRestore();
      log.mockRestore();
    }
  });

  it("戻す時にサムネの確認が落ちても、戻した事は成功で返り、一覧に出る", async () => {
    await rebuildNow();
    expect((await putVia("cat10/pic.png")).status).toBe(201);
    const { trashKey } = (await (
      await jsonPost("/v1/a/ops/trash", { key: "cat10/pic.png" })
    ).json()) as { trashKey: string };
    const real = env.META.head.bind(env.META);
    const spy = vi
      .spyOn(env.META, "head")
      .mockImplementation(((k: string) =>
        k.startsWith(".system/thumbs/")
          ? Promise.reject(new Error("meta down"))
          : real(k)) as typeof env.META.head);
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      expect((await jsonPost("/v1/a/ops/restore", { trashKey })).status).toBe(200);
    } finally {
      spy.mockRestore();
      log.mockRestore();
    }
    expect(await keysOf("recursive=1&sort=name&prefix=cat10/")).toEqual(["cat10/pic.png"]);
  });

  it("mkdir で作った空のフォルダが、大きいフォルダの段にも出る", async () => {
    await rebuildNow();
    expect((await jsonPost("/v1/a/ops/mkdir", { prefix: "catbig/made" })).status).toBe(201);
    const res = await direct("/v1/a/folders?prefix=catbig%2F&sort=name", {}, cachedEnv());
    expect(((await res.json()) as Listing).folders).toContain("catbig/made/");
  });
});

/* ---------------- 中身のハッシュと重複 ---------------- */

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const hashesFile = async () =>
  ((await (await env.META.get(".system/hashes-a.json"))?.json()) ?? { items: {} }) as {
    items: Record<string, { size: number; etag: string; sha256: string }>;
  };

/** 中身ごとに違うバイト列を作る（先頭は PNG の印）。同じ seed・長さなら同じ中身 */
const bytesOf = (seed: number, length = 64) =>
  new Uint8Array(length).map((_, i) => (i < 4 ? PNG[i]! : (seed * 31 + i * 7) % 251));

interface DupGroups {
  groups: { sha256: string; size: number; items: { key: string; size: number }[] }[];
  cursor: string | null;
  total: number;
  reclaimable: number;
  pending: number;
  skipped: number;
}

async function scanAll(e: Env = cachedEnv()) {
  let last = { pending: 1, hashed: 0, skipped: 0 };
  let hashed = 0;
  for (let i = 0; i < 50 && last.pending > 0; i++) {
    const res = await jsonPost("/v1/a/duplicates/scan", {}, e);
    expect(res.status).toBe(200);
    last = (await res.json()) as typeof last;
    hashed += last.hashed;
  }
  return { ...last, hashed };
}

async function duplicateGroups(e: Env = cachedEnv()): Promise<DupGroups> {
  const all: DupGroups["groups"] = [];
  let cursor: string | null = null;
  let page: DupGroups;
  do {
    const res = await direct(
      `/v1/a/duplicates?limit=2${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`,
      {},
      e,
    );
    expect(res.status).toBe(200);
    page = (await res.json()) as DupGroups;
    all.push(...page.groups);
    cursor = page.cursor;
  } while (cursor);
  return { ...page, groups: all };
}

const groupOf = (d: DupGroups, key: string) =>
  d.groups.find((g) => g.items.some((i) => i.key === key))?.items.map((i) => i.key);

describe("中身のハッシュの記録", () => {
  it("x-content-sha256 が中身と合う単発 PUT は記録され、合わない物は保存されない", async () => {
    await rebuildNow();
    const body = bytesOf(1);
    const sha = await sha256Hex(body);
    expect((await putVia("hash1/ok.png", body, { "x-content-sha256": sha })).status).toBe(201);
    const rec = (await hashesFile()).items["hash1/ok.png"];
    expect(rec?.sha256).toBe(sha);
    expect(rec?.etag).toBe((await env.LIB_A.head("hash1/ok.png"))?.etag);

    const wrong = await putVia("hash1/bad.png", body, { "x-content-sha256": "0".repeat(64) });
    expect(wrong.status).toBe(400);
    expect(await wrong.json()).toEqual({ error: "checksum_mismatch" });
    expect(await env.LIB_A.head("hash1/bad.png")).toBeNull();

    const malformed = await putVia("hash1/bad2.png", body, { "x-content-sha256": "xyz" });
    expect(malformed.status).toBe(400);
    expect(await env.LIB_A.head("hash1/bad2.png")).toBeNull();
  });

  it("ヘッダ無しの単発 PUT は今まで通り保存され、記録は増えない", async () => {
    expect((await putVia("hash2/plain.png", bytesOf(2))).status).toBe(201);
    expect((await hashesFile()).items["hash2/plain.png"]).toBeUndefined();
  });

  it("同時に記録しても、どれも消えない", async () => {
    const bodies = await Promise.all(
      Array.from({ length: 6 }, async (_, i) => {
        const body = bytesOf(100 + i);
        return { key: `hash3/${i}.png`, body, sha: await sha256Hex(body) };
      }),
    );
    const res = await Promise.all(
      bodies.map((b) => putVia(b.key, b.body, { "x-content-sha256": b.sha })),
    );
    expect(res.map((r) => r.status)).toEqual(Array(6).fill(201));
    const items = (await hashesFile()).items;
    for (const b of bodies) expect(items[b.key]?.sha256, b.key).toBe(b.sha);
  });

  it("記録の書き込みに失敗しても、アップロードは成功を返す", async () => {
    const real = env.META.put.bind(env.META);
    const spy = vi
      .spyOn(env.META, "put")
      .mockImplementation(((k: string, ...rest: unknown[]) =>
        k === ".system/hashes-a.json"
          ? Promise.resolve(null)
          : (real as (...a: unknown[]) => unknown)(k, ...rest)) as typeof env.META.put);
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const body = bytesOf(3);
      const res = await putVia("hash4/up.png", body, { "x-content-sha256": await sha256Hex(body) });
      expect(res.status).toBe(201);
      // 8 回とも etag の衝突で負けた時と同じ（put が null を返し続ける）
      expect(log).toHaveBeenCalledWith(
        "hash_record_failed",
        "a",
        "hash4/up.png",
        expect.anything(),
      );
    } finally {
      spy.mockRestore();
      log.mockRestore();
    }
    expect(await env.LIB_A.head("hash4/up.png")).not.toBeNull();
    expect((await hashesFile()).items["hash4/up.png"]).toBeUndefined();
  });

  it("ゴミ箱へ送った key の記録は消える", async () => {
    const body = bytesOf(4);
    await putVia("hash5/t.png", body, { "x-content-sha256": await sha256Hex(body) });
    expect((await hashesFile()).items["hash5/t.png"]).toBeDefined();
    expect((await jsonPost("/v1/a/ops/trash", { key: "hash5/t.png" })).status).toBe(200);
    expect((await hashesFile()).items["hash5/t.png"]).toBeUndefined();
  });
});

describe("重複の束", () => {
  const same = bytesOf(7, 80);

  it("名前もフォルダも違う同じ中身の 2 枚が 1 つの束になり、サイズだけ同じ物は入らない", async () => {
    await rebuildNow();
    expect((await putVia("dupA/first.png", same)).status).toBe(201);
    expect((await putVia("dupB/other-name.png", same)).status).toBe(201);
    // サイズは同じで中身が違う
    expect((await putVia("dupA/lookalike.png", bytesOf(8, 80))).status).toBe(201);
    expect((await putVia("dupA/unrelated.png", bytesOf(9, 81))).status).toBe(201);

    const scan = await scanAll();
    expect(scan.pending).toBe(0);
    const d = await duplicateGroups();
    expect(groupOf(d, "dupA/first.png")).toEqual(["dupA/first.png", "dupB/other-name.png"]);
    expect(groupOf(d, "dupA/lookalike.png")).toBeUndefined();
    const g = d.groups.find((x) => x.items.some((i) => i.key === "dupA/first.png"))!;
    expect(g.sha256).toBe(await sha256Hex(same));
    expect(g.size).toBe(80);
    expect(d.total).toBe(d.groups.length);
    expect(d.reclaimable).toBe(d.groups.reduce((n, x) => n + (x.items.length - 1) * x.size, 0));
    // etag(MD5) が違うと分かる物は、読んで計算しない
    expect((await hashesFile()).items["dupA/lookalike.png"]).toBeUndefined();
  });

  it("複数パートで上げた同じ中身の動画も束になる", async () => {
    const big = new Uint8Array(5 * 1024 * 1024 + 3).fill(9);
    const upload = async (key: string) => {
      const create = await jsonPost("/v1/a/objects/multipart", { key, contentType: "video/mp4" });
      const { uploadId } = (await create.json()) as { uploadId: string };
      const parts: { partNumber: number; etag: string }[] = [];
      for (const [n, body] of [
        [1, big.slice(0, 5 * 1024 * 1024)],
        [2, big.slice(5 * 1024 * 1024)],
      ] as const) {
        const res = await putBytes(
          `/v1/a/objects/multipart/part?key=${encodeURIComponent(key)}&uploadId=${uploadId}&part=${n}`,
          body,
          { "content-type": "application/octet-stream" },
        );
        parts.push((await res.json()) as { partNumber: number; etag: string });
      }
      const done = await jsonPost("/v1/a/objects/multipart/complete", { key, uploadId, parts });
      expect(done.status).toBe(201);
    };
    await upload("dupV/clip.mp4");
    expect((await putVia("dupV/single.mp4", big, { "content-type": "video/mp4" })).status).toBe(
      201,
    );
    expect((await scanAll()).pending).toBe(0);
    const d = await duplicateGroups();
    expect(groupOf(d, "dupV/clip.mp4")).toEqual(["dupV/clip.mp4", "dupV/single.mp4"]);
  });

  it("1 回で読む量に上限があり、残りは pending で返る。大きすぎる物は skipped に数える", async () => {
    const a = bytesOf(20, 4000);
    const b = bytesOf(21, 5000);
    for (const [k, body] of [
      ["dupL/a1.png", a],
      ["dupL/a2.png", a],
      ["dupL/b1.png", b],
      ["dupL/b2.png", b],
    ] as const) {
      expect((await putVia(k, body)).status).toBe(201);
    }
    const tight = cachedEnv({ DUP_SCAN_BYTES: "9000", DUP_MAX_OBJECT_BYTES: "4500" });
    const first = (await (await jsonPost("/v1/a/duplicates/scan", {}, tight)).json()) as {
      pending: number;
      hashed: number;
      skipped: number;
    };
    // 5000 バイトの 2 件は上限超え。4000 バイトの 2 件は 1 回で読める
    expect(first.skipped).toBe(2);
    expect(first.pending).toBe(0);
    const d = await duplicateGroups(tight);
    expect(groupOf(d, "dupL/a1.png")).toEqual(["dupL/a1.png", "dupL/a2.png"]);
    expect(groupOf(d, "dupL/b1.png")).toBeUndefined();
    expect(d.skipped).toBe(2);

    const tiny = cachedEnv({ DUP_SCAN_BYTES: "5000" });
    const step = (await (await jsonPost("/v1/a/duplicates/scan", {}, tiny)).json()) as {
      pending: number;
      hashed: number;
    };
    expect(step.hashed).toBe(1);
    expect(step.pending).toBe(1);
    expect((await scanAll(tiny)).pending).toBe(0);
    expect(groupOf(await duplicateGroups(), "dupL/b1.png")).toEqual(["dupL/b1.png", "dupL/b2.png"]);
  });

  it("1 回で読む件数にも上限があり、区切りごとに記録が残る", async () => {
    const body = bytesOf(70, 33);
    for (const k of ["dupN/1.png", "dupN/2.png", "dupN/3.png"]) {
      expect((await putVia(k, body)).status).toBe(201);
    }
    const one = cachedEnv({ DUP_SCAN_OBJECTS: "1" });
    const step = (await (await jsonPost("/v1/a/duplicates/scan", {}, one)).json()) as {
      pending: number;
      hashed: number;
    };
    expect(step.hashed).toBe(1);
    expect(step.pending).toBe(2);
    // 1 件ぶんはもう記録されていて、次の呼び出しは残りから進む
    expect(
      Object.keys((await hashesFile()).items).filter((k) => k.startsWith("dupN/")).length,
    ).toBe(1);
    expect((await scanAll(one)).pending).toBe(0);
    expect(groupOf(await duplicateGroups(), "dupN/1.png")).toEqual([
      "dupN/1.png",
      "dupN/2.png",
      "dupN/3.png",
    ]);
  });

  it("読み取り専用のライブラリでも束は見られ、知らないライブラリは 404", async () => {
    expect((await direct("/v1/b/duplicates", {}, cachedEnv())).status).toBe(200);
    expect((await direct("/v1/nope/duplicates", {}, cachedEnv())).status).toBe(404);
    expect((await api("/v1/a/duplicates", { headers: { authorization: "Bearer x" } })).status).toBe(
      401,
    );
  });
});

describe("アップロード前の照会", () => {
  it("サイズだけなら件数を、sha256 付きなら中身が同じ物を返す", async () => {
    await rebuildNow();
    const body = bytesOf(30, 123);
    expect((await putVia("chk/stored.png", body)).status).toBe(201);
    expect((await putVia("chk/same-size.png", bytesOf(31, 123))).status).toBe(201);
    const res = await jsonPost("/v1/a/objects/check", {
      items: [
        { size: 123 },
        { size: 123, sha256: await sha256Hex(body) },
        { size: 123, sha256: await sha256Hex(bytesOf(32, 123)) },
        { size: 999_999 },
      ],
    });
    expect(res.status).toBe(200);
    const out = (await res.json()) as {
      results: { sizeMatches: number; matches: { key: string; url: string }[] }[];
      pending: number;
    };
    expect(out.pending).toBe(0);
    expect(out.results.map((r) => r.sizeMatches)).toEqual([2, 2, 2, 0]);
    expect(out.results.map((r) => r.matches.map((m) => m.key))).toEqual([
      [],
      ["chk/stored.png"],
      [],
      [],
    ]);
    expect(out.results[1]!.matches[0]!.url).toMatch(/^https:\/\/example\.test\/m\/a\//);
  });

  it("ゴミ箱の物は相手にしない", async () => {
    const body = bytesOf(33, 222);
    await putVia("chk/gone.png", body);
    await jsonPost("/v1/a/ops/trash", { key: "chk/gone.png" });
    const res = await jsonPost("/v1/a/objects/check", {
      items: [{ size: 222, sha256: await sha256Hex(body) }],
    });
    const out = (await res.json()) as { results: { sizeMatches: number; matches: unknown[] }[] };
    expect(out.results[0]).toEqual({ sizeMatches: 0, matches: [] });
  });

  it("おかしな入力は 400", async () => {
    for (const items of [
      "x",
      [{ size: -1 }],
      [{ size: 1.5 }],
      [{ size: 1, sha256: "zz" }],
      Array.from({ length: 1001 }, () => ({ size: 1 })),
    ]) {
      expect((await jsonPost("/v1/a/objects/check", { items })).status).toBe(400);
    }
  });
});

describe("重複として消す", () => {
  const post = (path: string, body: unknown) => jsonPost(path, body);
  const albumKeys = async (id: string) =>
    (
      (await (await direct(`/v1/a/albums/${id}`, {}, cachedEnv())).json()) as {
        items: { key: string }[];
      }
    ).items.map((i) => i.key);
  const mkAlbum = async (title: string, keys: string[]) => {
    const { id } = (await (await post("/v1/a/albums", { title })).json()) as { id: string };
    expect((await post(`/v1/a/albums/${id}/items`, { keys })).status).toBe(200);
    return id;
  };

  it("消す側だけが入っていたアルバムには残す側が同じ位置で入り、両方入っていた所は消す側だけ外れる", async () => {
    await rebuildNow();
    const body = bytesOf(40, 300);
    for (const k of ["dd1/keep.png", "dd1/drop.png"]) await putVia(k, body);
    for (const k of ["dd1/x.png", "dd1/y.png"]) await putVia(k, bytesOf(41, 12));
    const only = await mkAlbum("dd1-only", ["dd1/x.png", "dd1/drop.png", "dd1/y.png"]);
    const both = await mkAlbum("dd1-both", ["dd1/keep.png", "dd1/x.png", "dd1/drop.png"]);

    const res = await post("/v1/a/ops/trash", { key: "dd1/drop.png", duplicateOf: "dd1/keep.png" });
    expect(res.status).toBe(200);
    const { trashKey } = (await res.json()) as { trashKey: string };
    expect(trashKey).toMatch(/^\.trash\/\d+\/dd1\/drop\.png$/);
    expect(await env.LIB_A.head("dd1/drop.png")).toBeNull();
    expect(await env.LIB_A.head(trashKey)).not.toBeNull();
    expect(await albumKeys(only)).toEqual(["dd1/x.png", "dd1/keep.png", "dd1/y.png"]);
    expect(await albumKeys(both)).toEqual(["dd1/keep.png", "dd1/x.png"]);
    expect(await keysOf("recursive=1&sort=name&prefix=dd1/")).toEqual([
      "dd1/keep.png",
      "dd1/x.png",
      "dd1/y.png",
    ]);

    // 戻した物はライブラリに戻るだけで、アルバムは残す側が持ち続ける
    expect((await post("/v1/a/ops/restore", { trashKey })).status).toBe(200);
    expect(await env.LIB_A.head("dd1/drop.png")).not.toBeNull();
    expect(await albumKeys(only)).toEqual(["dd1/x.png", "dd1/keep.png", "dd1/y.png"]);
    expect(await albumKeys(both)).toEqual(["dd1/keep.png", "dd1/x.png"]);
  });

  it("中身が違う物・残す側が無い物・自分自身は断り、何も動かさない", async () => {
    await putVia("dd2/a.png", bytesOf(50, 77));
    await putVia("dd2/b.png", bytesOf(51, 77));
    const notDup = await post("/v1/a/ops/trash", { key: "dd2/a.png", duplicateOf: "dd2/b.png" });
    expect(notDup.status).toBe(409);
    expect(await notDup.json()).toEqual({ error: "not_duplicate" });
    const missing = await post("/v1/a/ops/trash", {
      key: "dd2/a.png",
      duplicateOf: "dd2/none.png",
    });
    expect(missing.status).toBe(409);
    expect(await missing.json()).toEqual({ error: "keeper_missing" });
    expect(
      (await post("/v1/a/ops/trash", { key: "dd2/a.png", duplicateOf: "dd2/a.png" })).status,
    ).toBe(400);
    expect(await env.LIB_A.head("dd2/a.png")).not.toBeNull();
    expect(await env.LIB_A.head("dd2/b.png")).not.toBeNull();
  });

  it("互いを残す側にして同時に消しても、少なくとも片方が残る", async () => {
    const body = bytesOf(60, 90);
    await putVia("dd3/a.png", body);
    await putVia("dd3/b.png", body);
    const res = await Promise.all([
      post("/v1/a/ops/trash", { key: "dd3/a.png", duplicateOf: "dd3/b.png" }),
      post("/v1/a/ops/trash", { key: "dd3/b.png", duplicateOf: "dd3/a.png" }),
    ]);
    expect(res.map((r) => r.status).filter((s) => s !== 200 && s !== 409)).toEqual([]);
    const alive = (
      await Promise.all(["dd3/a.png", "dd3/b.png"].map((k) => env.LIB_A.head(k)))
    ).filter(Boolean).length;
    expect(alive).toBeGreaterThanOrEqual(1);
    // 索引も実物と同じ物を指す
    const listed = await keysOf("recursive=1&sort=name&prefix=dd3/");
    for (const k of ["dd3/a.png", "dd3/b.png"]) {
      expect(listed.includes(k), k).toBe((await env.LIB_A.head(k)) !== null);
    }
  });

  it("残す側を別の操作が消している最中でも、アルバムは無い物を指さない", async () => {
    // A を「B を残して」消すのと、B を「C を残して」消すのが重なる。A が入っていたアルバムが
    // ゴミ箱にある B を指したままになってはいけない
    for (let round = 0; round < 4; round++) {
      const p = `dd4-${round}`;
      const body = bytesOf(80 + round, 95);
      for (const k of ["a", "b", "c"]) await putVia(`${p}/${k}.png`, body);
      const album = await mkAlbum(p, [`${p}/a.png`]);
      await Promise.all([
        post("/v1/a/ops/trash", { key: `${p}/a.png`, duplicateOf: `${p}/b.png` }),
        post("/v1/a/ops/trash", { key: `${p}/b.png`, duplicateOf: `${p}/c.png` }),
      ]);
      const keys = await albumKeys(album);
      expect(keys.length, p).toBe(1);
      for (const k of keys) expect(await env.LIB_A.head(k), `${p}: ${k}`).not.toBeNull();
    }
  });

  it("残す側が、アルバムを書く直前に消えていたら、消した物を戻して断る", async () => {
    const body = bytesOf(90, 97);
    await putVia("dd5/a.png", body);
    await putVia("dd5/b.png", body);
    const album = await mkAlbum("dd5", ["dd5/a.png"]);
    // 移した後の確認までは残す側があり、アルバムを書く時には無い、という順を作る
    const real = env.LIB_A.head.bind(env.LIB_A);
    let seen = 0;
    const spy = vi
      .spyOn(env.LIB_A, "head")
      .mockImplementation(((k: string) =>
        k === "dd5/b.png" && ++seen > 2
          ? Promise.resolve(null)
          : real(k)) as typeof env.LIB_A.head);
    try {
      const res = await post("/v1/a/ops/trash", { key: "dd5/a.png", duplicateOf: "dd5/b.png" });
      expect(res.status).toBe(409);
      expect(await res.json()).toEqual({ error: "keeper_missing" });
    } finally {
      spy.mockRestore();
    }
    expect(await env.LIB_A.head("dd5/a.png")).not.toBeNull();
    expect(await albumKeys(album)).toEqual(["dd5/a.png"]);
    expect(await keysOf("recursive=1&sort=name&prefix=dd5/")).toEqual(["dd5/a.png", "dd5/b.png"]);
  });

  it("読み取り専用のライブラリでは消せない", async () => {
    const res = await post("/v1/b/ops/trash", { key: "ro/keep.jpg", duplicateOf: "ro/x.jpg" });
    expect(res.status).toBe(403);
  });
});
