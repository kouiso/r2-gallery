import { createExecutionContext, env, SELF, waitOnExecutionContext } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";

import worker, { type Env } from "./index";
import { purgeTrash } from "./lib/objects";
import { encodeSig, SIG_BYTES } from "./lib/similar/core";
import { shardOf } from "./lib/similar/store";

declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    LIB_A: R2Bucket;
    LIB_B: R2Bucket;
  }
}

/*
 * まとめてゴミ箱へ送る口（/similar/trash）と直後の取り消し（/similar/undo）。
 *
 * テストのファイルどうしは同じ R2 を同時に使うので、場面ごとに LIB_B の接頭辞だけが見える
 * 仮のライブラリを作る（similar.test.ts と同じ作り。a 全体を数えるテストを乱さない）。
 * albums.json は全ライブラリで 1 つで、index.test.ts には件数をそのまま比べる・条件なしで書き戻す
 * テストがある。同じファイルを使うと互いのアルバムを数えたり消したりするので、このファイルの
 * アルバムは META の別の名前に置く（Worker から見た置き場の名前だけを差し替える）。
 */

const ORIGIN = "https://example.test";
const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const ALBUMS_REAL = ".system/albums.json";
const ALBUMS = ".system/albums.similar-trash-test.json";
const TRASHED = /^\.trash\/\d+\//;

/** 仮のライブラリの物を置くバケット */
const bucket = () => env.LIB_B;

function scopedBucket(prefix: string, over: Partial<R2Bucket> = {}): R2Bucket {
  const real = bucket();
  const belongs = (k: string) => k.replace(TRASHED, "").startsWith(prefix);
  return new Proxy(real, {
    get(target, prop) {
      if (prop in over) return over[prop as keyof R2Bucket];
      if (prop === "list") {
        return async (o: R2ListOptions = {}) => {
          const p = o.prefix ?? "";
          if (prefix.startsWith(p)) return target.list({ ...o, prefix });
          const page = await target.list(o);
          return {
            ...page,
            objects: page.objects.filter((x) => belongs(x.key)),
            delimitedPrefixes: page.delimitedPrefixes.filter(belongs),
          };
        };
      }
      const v = Reflect.get(target, prop) as unknown;
      return typeof v === "function" ? (v as (...a: unknown[]) => unknown).bind(target) : v;
    },
  });
}

const BY_KEY = new Set(["get", "put", "head", "delete"]);

/**
 * albums.json だけを ALBUMS へ読み替える META。over で get/put/head/delete を差し替えられる
 * （差し替えた関数には読み替えた後の名前が渡る）。元の関数は呼ぶたびに引くので、
 * vi.spyOn(env.META, ...) の見張りもそのまま効く。
 */
function isolatedMeta(over: Partial<R2Bucket> = {}): R2Bucket {
  const rename = (k: unknown) => (k === ALBUMS_REAL ? ALBUMS : k);
  return new Proxy(env.META, {
    get(target, prop) {
      if (typeof prop === "string" && BY_KEY.has(prop)) {
        return (k: unknown, ...rest: unknown[]) => {
          const fn = (over[prop as keyof R2Bucket] ?? Reflect.get(target, prop)) as (
            ...a: unknown[]
          ) => unknown;
          return fn.call(target, rename(k), ...rest);
        };
      }
      const v = Reflect.get(target, prop) as unknown;
      return typeof v === "function" ? (v as (...a: unknown[]) => unknown).bind(target) : v;
    },
  });
}

interface LibOpts {
  over?: Partial<R2Bucket>;
  meta?: Partial<R2Bucket>;
  vars?: Partial<Env>;
}

function libEnv(id: string, o: LibOpts = {}): Env {
  const binding = `LIB_${id.toUpperCase()}`;
  return {
    ...env,
    LIBRARIES: JSON.stringify([
      { id: "a", binding: "LIB_A", title: "Test A" },
      { id: "b", binding: "LIB_B", title: "Test B", readOnly: true },
      { id, binding, title: id },
    ]),
    [binding]: scopedBucket(`${id}/`, o.over),
    META: isolatedMeta(o.meta),
    ...o.vars,
  } as Env;
}

async function call(e: Env, path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  if (!headers.has("authorization")) headers.set("authorization", "Bearer test-access-token");
  const ctx = createExecutionContext();
  const res = await worker.fetch(new Request(`${ORIGIN}${path}`, { ...init, headers }), e, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

const post = (e: Env, path: string, body: unknown) =>
  call(e, path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

async function ok<T>(res: Response | Promise<Response>, status = 200): Promise<T> {
  const r = await res;
  const text = await r.text();
  expect(r.status, text).toBe(status);
  return JSON.parse(text) as T;
}

/* ---------------- 物と署名 ---------------- */

function pngBytes(w: number, h: number, seed: number, length = 40): Uint8Array {
  const b = new Uint8Array(length);
  b.set(PNG_MAGIC, 0);
  b.set([0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52], 8);
  const dv = new DataView(b.buffer);
  dv.setUint32(16, w);
  dv.setUint32(20, h);
  for (let i = 24; i < length; i++) b[i] = (seed * 31 + i * 7) % 251;
  return b;
}

const put = async (key: string, body: Uint8Array) => (await bucket().put(key, body))!.etag;
const exists = async (key: string) => (await bucket().head(key)) !== null;

function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

interface Look {
  p: Uint8Array;
  d: Uint8Array;
  m: Uint8Array;
  grid: Uint8Array;
  color: Uint8Array;
}

function look(seed: number): Look {
  const rnd = mulberry32(seed * 7919 + 17);
  const bytes = () => Uint8Array.from({ length: 8 }, () => Math.floor(rnd() * 256));
  return {
    p: bytes(),
    d: bytes(),
    m: bytes(),
    grid: Uint8Array.from({ length: 256 }, (_, k) => 30 + (k & 15) * 12 + ((k >> 4) % 3)),
    color: Uint8Array.from([10, 20, 30, 200, 210, 220, 60, 70, 80, 150, 160, 170]),
  };
}

const flipBits = (b: Uint8Array, n: number) => {
  const out = Uint8Array.from(b);
  for (let i = 0; i < n; i++) out[i >> 3] = out[i >> 3]! ^ (0x80 >> (i & 7));
  return out;
};
const mirrorOf = (l: Look): Look => ({
  p: l.m,
  d: flipBits(l.d, 20),
  m: l.p,
  grid: Uint8Array.from({ length: 256 }, (_, k) => l.grid[(k & ~15) | (15 - (k & 15))]!),
  color: Uint8Array.from({ length: 12 }, (_, i) => l.color[(Math.floor(i / 3) ^ 1) * 3 + (i % 3)]!),
});
const similarOf = (l: Look): Look => {
  const grid = Uint8Array.from(l.grid);
  grid[0] = grid[0]! + 40;
  return { ...l, p: flipBits(l.p, 6), d: flipBits(l.d, 6), m: flipBits(l.m, 6), grid };
};

function sigOf(l: Look): string {
  const s = new Uint8Array(SIG_BYTES);
  s.set(l.p, 0);
  s.set(l.d, 8);
  s.set(l.m, 16);
  s.set(l.grid, 24);
  s.set(l.color, 280);
  s.set([0, 100, 0, 100], 292);
  return encodeSig(s);
}

async function sign(e: Env, lib: string, list: [string, string][]) {
  const items = await Promise.all(
    list.map(async ([key, sig]) => ({
      key,
      etag: (await bucket().head(key))!.etag,
      src: "t",
      sig,
    })),
  );
  const r = await ok<{ stored: number }>(
    post(e, `/v1/${lib}/similar/signatures`, { alg: "vs1", items }),
  );
  expect(r.stored).toBe(list.length);
}

/* ---------------- アルバムとゴミ箱 ---------------- */

interface RawAlbum {
  id: string;
  items: { key: string; lib: string }[];
  trashOrder?: string[];
}

async function rawAlbum(id: string): Promise<RawAlbum> {
  const data = (await (await env.META.get(ALBUMS))!.json()) as { albums: RawAlbum[] };
  return data.albums.find((a) => a.id === id)!;
}
const albumKeys = async (id: string) => (await rawAlbum(id)).items.map((i) => i.key);
const albumJson = async (id: string) => JSON.stringify(await rawAlbum(id));

async function mkAlbum(e: Env, lib: string, title: string, keys: string[]): Promise<string> {
  const { id } = await ok<{ id: string }>(post(e, `/v1/${lib}/albums`, { title }), 201);
  await ok(post(e, `/v1/${lib}/albums/${id}/items`, { keys }));
  return id;
}

async function sidecars(lib: string): Promise<string[]> {
  const listed = await env.META.list({ prefix: `.system/trash-albums/${lib}/` });
  return listed.objects.map((o) => o.key);
}

/** ゴミ箱に残っている key の写し（他のファイルの物も混ざるので全部たどって探す） */
async function trashedCopies(key: string): Promise<string[]> {
  const out: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await bucket().list({ prefix: ".trash/", cursor });
    for (const o of page.objects) if (o.key.replace(TRASHED, "") === key) out.push(o.key);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return out;
}

const sidecarPath = (lib: string, trashKey: string) =>
  `.system/trash-albums/${lib}/${trashKey.replace(/^\.trash\//, "")}.json`;

type TrashResult =
  | { key: string; ok: true; trashKey: string; kind: string }
  | { key: string; ok: false; error: string; trashKey?: string };
type UndoResult =
  | { trashKey: string; ok: true; key: string }
  | { trashKey: string; ok: false; error: string; status: number };

const trash = (e: Env, lib: string, items: { key: string; keep: string }[]) =>
  ok<{ results: TrashResult[] }>(post(e, `/v1/${lib}/similar/trash`, { items })).then(
    (r) => r.results,
  );
const undo = (e: Env, lib: string, trashKeys: string[]) =>
  ok<{ results: UndoResult[] }>(post(e, `/v1/${lib}/similar/undo`, { trashKeys })).then(
    (r) => r.results,
  );
const trashKeyOf = (r: TrashResult) => {
  expect(r.ok, JSON.stringify(r)).toBe(true);
  return (r as { trashKey: string }).trashKey;
};

/* ---------------- テスト ---------------- */

describe("同じファイルをまとめてゴミ箱へ", () => {
  const lib = "ti";
  const e = libEnv(lib);
  const id = (k: string) => `${lib}:${k}`;
  const K = "ti/keep.png";
  const D1 = "ti/d1.png";
  const D2 = "ti/d2.png";
  let a1 = "";
  let a2 = "";
  let a3 = "";
  let trashD1 = "";

  it("ファイルを移し、消した物の位置に残す物を入れ、並びの控えでは消した物の直後に残す物を置く", async () => {
    const same = pngBytes(500, 500, 1, 50);
    for (const k of [K, D1, D2]) await put(k, same);
    for (const [i, k] of ["ti/x.png", "ti/y.png", "ti/z.png"].entries()) {
      await put(k, pngBytes(10, 10, 10 + i));
    }
    a1 = await mkAlbum(e, lib, "ti-1", ["ti/x.png", D1, "ti/y.png"]);
    a2 = await mkAlbum(e, lib, "ti-2", [K, D1]);
    a3 = await mkAlbum(e, lib, "ti-3", [D2, "ti/z.png"]);

    const results = await trash(e, lib, [
      { key: D1, keep: K },
      { key: D2, keep: K },
    ]);
    expect(results.map((r) => [r.key, r.ok, r.ok && r.kind])).toEqual([
      [D1, true, "identical"],
      [D2, true, "identical"],
    ]);
    trashD1 = trashKeyOf(results[0]!);
    expect(trashD1).toMatch(/^\.trash\/\d+\/ti\/d1\.png$/);
    expect(await exists(D1)).toBe(false);
    expect(await exists(D2)).toBe(false);
    expect(await exists(trashD1)).toBe(true);
    expect(await exists(K)).toBe(true);

    expect(await albumKeys(a1)).toEqual(["ti/x.png", K, "ti/y.png"]);
    // 残す物が既に居たアルバムでは、消した物を外すだけ（同じ絵を 2 回並べない）
    expect(await albumKeys(a2)).toEqual([K]);
    expect(await albumKeys(a3)).toEqual([K, "ti/z.png"]);
    for (const [album, gone] of [
      [a1, D1],
      [a3, D2],
    ] as const) {
      const order = (await rawAlbum(album)).trashOrder!;
      expect(order.indexOf(id(K)), order.join()).toBe(order.indexOf(id(gone)) + 1);
    }

    const sidecar = (await (await env.META.get(sidecarPath(lib, trashD1)))!.json()) as {
      albumId: string;
      keeper: string;
      keeperAdded: boolean;
      exact: boolean;
    }[];
    expect(sidecar.map((m) => [m.albumId, m.keeper, m.keeperAdded, m.exact])).toEqual([
      [a1, K, true, true],
      [a2, K, false, true],
    ]);
  });

  it("同じファイルとして消した物は、ゴミ箱から戻してもアルバムへは戻らず、残す物が残る", async () => {
    expect(trashD1).not.toBe("");
    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey: trashD1 }));
    expect(await exists(D1)).toBe(true);
    expect(await albumKeys(a1)).toEqual(["ti/x.png", K, "ti/y.png"]);
    expect(await albumKeys(a2)).toEqual([K]);
    expect(await env.META.head(sidecarPath(lib, trashD1))).toBeNull();
  });
});

describe("似ている物をゴミ箱へ送ってから戻す", () => {
  const lib = "tr";
  const e = libEnv(lib);

  it("ゴミ箱から戻すと元の位置へ戻り、残す物もアルバムに残る", async () => {
    const L = look(20);
    const K = "tr/keep.png";
    const S = "tr/similar.png";
    const M = "tr/mirror.png";
    await put(K, pngBytes(800, 600, 1, 50));
    await put(S, pngBytes(800, 600, 2, 44));
    await put(M, pngBytes(800, 600, 3, 45));
    await put("tr/a.png", pngBytes(10, 10, 4));
    await put("tr/b.png", pngBytes(10, 10, 5));
    await sign(e, lib, [
      [K, sigOf(L)],
      [S, sigOf(similarOf(L))],
      [M, sigOf(mirrorOf(L))],
    ]);
    const album = await mkAlbum(e, lib, "tr-1", ["tr/a.png", S, "tr/b.png"]);
    const other = await mkAlbum(e, lib, "tr-2", [M]);

    const results = await trash(e, lib, [
      { key: S, keep: K },
      { key: M, keep: K },
    ]);
    expect(results.map((r) => r.ok && r.kind)).toEqual(["similar", "mirror"]);
    expect(await albumKeys(album)).toEqual(["tr/a.png", K, "tr/b.png"]);
    expect(await albumKeys(other)).toEqual([K]);

    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey: trashKeyOf(results[0]!) }));
    expect(await albumKeys(album)).toEqual(["tr/a.png", S, K, "tr/b.png"]);
    expect(await exists(S)).toBe(true);
    expect(await exists(K)).toBe(true);
  });
});

describe("消した直後の取り消し", () => {
  const lib = "tu";
  const e = libEnv(lib);

  it("消す前のアルバムにそのまま戻し、消した時に入れた残す物を外す", async () => {
    const L = look(30);
    const K = "tu/keep.png";
    const V = "tu/same.png";
    const W = "tu/copy.png";
    const keep = pngBytes(800, 600, 1, 50);
    await put(K, keep);
    await put(W, keep);
    await put(V, pngBytes(400, 300, 2, 44));
    await put("tu/a.png", pngBytes(10, 10, 3));
    await put("tu/b.png", pngBytes(10, 10, 4));
    await sign(e, lib, [
      [K, sigOf(L)],
      [V, sigOf(L)],
    ]);
    const u1 = await mkAlbum(e, lib, "tu-1", ["tu/a.png", V, "tu/b.png"]);
    const u2 = await mkAlbum(e, lib, "tu-2", [K, V]);
    const u3 = await mkAlbum(e, lib, "tu-3", [W, "tu/a.png"]);
    const before = await Promise.all([u1, u2, u3].map(albumJson));

    const results = await trash(e, lib, [
      { key: V, keep: K },
      { key: W, keep: K },
    ]);
    expect(results.map((r) => r.ok && r.kind)).toEqual(["same", "identical"]);
    expect(await albumKeys(u1)).toEqual(["tu/a.png", K, "tu/b.png"]);
    expect(await albumKeys(u2)).toEqual([K]);
    expect(await albumKeys(u3)).toEqual([K, "tu/a.png"]);
    expect((await sidecars(lib)).length).toBe(2);

    const keys = results.map(trashKeyOf);
    const bogus = ".trash/1/tu/none.png";
    const back = await undo(e, lib, [...keys, bogus]);
    expect(back.slice(0, 2)).toEqual([
      { trashKey: keys[0], ok: true, key: V },
      { trashKey: keys[1], ok: true, key: W },
    ]);
    expect(back[2]).toMatchObject({ trashKey: bogus, ok: false });
    expect((back[2] as { status: number }).status).toBeGreaterThanOrEqual(400);

    // 取り消しはちょうど逆の操作: アルバムは消す前と 1 バイトも違わない
    expect(await Promise.all([u1, u2, u3].map(albumJson))).toEqual(before);
    for (const k of [V, W, K]) expect(await exists(k), k).toBe(true);
    for (const t of keys) expect(await exists(t), t).toBe(false);
    expect(await sidecars(lib)).toEqual([]);
    const listed = await ok<{ items: { key: string }[] }>(
      call(e, `/v1/${lib}/folders?prefix=${lib}/&recursive=1&sort=name`),
    );
    expect(listed.items.map((i) => i.key)).toEqual(expect.arrayContaining([V, W]));
  });
});

describe("断る場合", () => {
  const lib = "te";
  const e = libEnv(lib);

  it("中身も見た目も確かめ直し、合わない物・自分自身・同じ回で消す残す物・無い物は動かさない", async () => {
    const K = "te/keep.png";
    await put(K, pngBytes(800, 600, 1, 50));
    await put("te/a.png", pngBytes(800, 600, 2, 41));
    await put("te/b.png", pngBytes(800, 600, 3, 42));
    await put("te/unsigned.png", pngBytes(800, 600, 4, 43));
    await put("te/changed.png", pngBytes(800, 600, 5, 44));
    const same = pngBytes(800, 600, 6, 45);
    for (const k of ["te/e.png", "te/f.png", "te/g.png"]) await put(k, same);
    await put("te/h.png", pngBytes(800, 600, 7, 46));
    await put("te/i.png", pngBytes(800, 600, 8, 47));
    await sign(e, lib, [
      [K, sigOf(look(40))],
      ["te/a.png", sigOf(look(41))],
      ["te/b.png", sigOf(look(42))],
      ["te/changed.png", sigOf(look(40))],
    ]);
    // 署名を作った後で中身が入れ替わった
    await put("te/changed.png", pngBytes(800, 600, 9, 44));

    const results = await trash(e, lib, [
      { key: "te/a.png", keep: "te/b.png" },
      { key: "te/unsigned.png", keep: K },
      { key: "te/changed.png", keep: K },
      { key: "te/e.png", keep: "te/f.png" },
      { key: "te/f.png", keep: "te/g.png" },
      { key: "te/h.png", keep: "te/h.png" },
      { key: "te/i.png", keep: "te/none.png" },
      { key: "te/ghost.png", keep: K },
    ]);
    expect(results.map((r) => [r.key, r.ok ? r.kind : r.error])).toEqual([
      ["te/a.png", "not_similar"],
      ["te/unsigned.png", "stale_signature"],
      ["te/changed.png", "stale_signature"],
      ["te/e.png", "keeper_targeted"],
      ["te/f.png", "identical"],
      ["te/h.png", "same_key"],
      ["te/i.png", "keeper_missing"],
      ["te/ghost.png", "source_not_found"],
    ]);
    for (const k of ["te/a.png", "te/unsigned.png", "te/changed.png", "te/e.png", "te/h.png"]) {
      expect(await exists(k), k).toBe(true);
    }
    expect(await exists("te/i.png")).toBe(true);
    expect(await exists("te/f.png")).toBe(false);
    expect(await exists("te/g.png")).toBe(true);
  });
});

describe("残す物が途中で消える", () => {
  const lib = "tk";

  // n 回目以降の head で残す物が無いと答えるライブラリ（別の操作が同じ時に残す物を消した）
  const vanishing = (keeper: string, fromCall: number) => {
    let calls = 0;
    const realHead = bucket().head.bind(bucket());
    return libEnv(lib, {
      over: {
        head: ((k: string) =>
          k === keeper && ++calls >= fromCall
            ? Promise.resolve(null)
            : realHead(k)) as R2Bucket["head"],
      },
    });
  };

  for (const [when, fromCall] of [
    ["移した直後の確認で", 2],
    ["アルバムを書く直前に", 3],
  ] as const) {
    it(`${when}残す物が無ければ、移した物を戻し、アルバムも控えも残さない`, async () => {
      const p = `tk/${fromCall}`;
      const K = `${p}/keep.png`;
      const D = `${p}/dup.png`;
      const body = pngBytes(500, 500, fromCall, 50);
      await put(K, body);
      await put(D, body);
      await put(`${p}/x.png`, pngBytes(10, 10, 20 + fromCall));
      const album = await mkAlbum(libEnv(lib), lib, p, [`${p}/x.png`, D]);
      const before = await albumJson(album);

      const results = await trash(vanishing(K, fromCall), lib, [{ key: D, keep: K }]);
      expect(results).toEqual([{ key: D, ok: false, error: "keeper_missing" }]);
      expect(await exists(D)).toBe(true);
      expect(await albumJson(album)).toBe(before);
      expect(await sidecars(lib)).toEqual([]);
      expect(await trashedCopies(D)).toEqual([]);
    });
  }
});

describe("アルバムを書けない", () => {
  const lib = "tf";

  it("全部を元へ戻して albums_failed を返し、控えを残さない", async () => {
    const e = libEnv(lib);
    const K = "tf/keep.png";
    const body = pngBytes(500, 500, 1, 50);
    for (const k of [K, "tf/d1.png", "tf/d2.png"]) await put(k, body);
    const album = await mkAlbum(e, lib, "tf-1", ["tf/d1.png", "tf/d2.png"]);
    const before = await albumJson(album);

    const realPut = env.META.put.bind(env.META);
    const failing = libEnv(lib, {
      meta: {
        put: ((k: string, ...rest: unknown[]) =>
          k === ALBUMS
            ? Promise.reject(new Error("albums down"))
            : (realPut as (...a: unknown[]) => Promise<R2Object | null>)(
                k,
                ...rest,
              )) as R2Bucket["put"],
      },
    });
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    let results: TrashResult[];
    try {
      results = await trash(failing, lib, [
        { key: "tf/d1.png", keep: K },
        { key: "tf/d2.png", keep: K },
      ]);
    } finally {
      log.mockRestore();
    }
    expect(results).toEqual([
      { key: "tf/d1.png", ok: false, error: "albums_failed" },
      { key: "tf/d2.png", ok: false, error: "albums_failed" },
    ]);
    for (const k of ["tf/d1.png", "tf/d2.png", K]) expect(await exists(k), k).toBe(true);
    expect(await albumJson(album)).toBe(before);
    expect(await sidecars(lib)).toEqual([]);
  });
});

describe("まとめて書く", () => {
  const lib = "tw";
  // 索引を作り直さずに使い回す（本番と同じ）。消した物が一覧から外れるのは追記のおかげだと確かめる
  const e = libEnv(lib, { vars: { CATALOG_MAX_AGE_SECONDS: "300" } });

  it("アルバムの書き込みは 1 回で、索引とハッシュの記録から消した物が外れ、見た目の署名は残る", async () => {
    const K = "tw/keep.png";
    const dups = Array.from({ length: 6 }, (_, i) => `tw/d${i}.png`);
    const body = pngBytes(500, 500, 1, 50);
    for (const k of [K, ...dups]) await put(k, body);
    const sig = sigOf(look(50));
    await sign(e, lib, [
      [K, sig],
      [dups[0]!, sig],
    ]);
    const w1 = await mkAlbum(e, lib, "tw-1", [dups[0]!, dups[1]!]);
    const w2 = await mkAlbum(e, lib, "tw-2", [dups[2]!, dups[3]!]);
    const w3 = await mkAlbum(e, lib, "tw-3", [dups[4]!, dups[5]!, K]);
    for (let i = 0; i < 20; i++) {
      const r = await ok<{ pending: number }>(post(e, `/v1/${lib}/duplicates/scan`, {}));
      if (r.pending === 0) break;
    }
    const hashes = async () =>
      (
        (await (await env.META.get(`.system/hashes-${lib}.json`))!.json()) as {
          items: Record<string, unknown>;
        }
      ).items;
    expect(Object.keys(await hashes()).sort()).toEqual([K, ...dups].sort());
    const listing = async () =>
      (
        await ok<{ items: { key: string }[] }>(
          call(e, `/v1/${lib}/folders?prefix=${lib}/&recursive=1&sort=name`),
        )
      ).items.map((i) => i.key);
    expect(await listing()).toEqual([K, ...dups].sort());

    // 他のファイルのテストも同じ albums.json を書くので、条件付きの書き込みで負けた回は数えない
    const realPut = env.META.put.bind(env.META);
    let albumWrites = 0;
    const spy = vi.spyOn(env.META, "put").mockImplementation((async (
      k: string,
      ...rest: unknown[]
    ) => {
      const r = await (realPut as (...a: unknown[]) => Promise<R2Object | null>)(k, ...rest);
      if (k === ALBUMS && r) albumWrites++;
      return r;
    }) as typeof env.META.put);
    let results: TrashResult[];
    try {
      results = await trash(
        e,
        lib,
        dups.map((key) => ({ key, keep: K })),
      );
    } finally {
      spy.mockRestore();
    }
    expect(results.every((r) => r.ok)).toBe(true);
    expect(albumWrites).toBe(1);
    for (const w of [w1, w2, w3]) expect(await albumKeys(w)).toEqual([K]);

    expect(Object.keys(await hashes())).toEqual([K]);
    expect(await listing()).toEqual([K]);
    const shard = (await (await env.META.get(
      `.system/similar/${lib}/${String(shardOf(dups[0]!)).padStart(2, "0")}.json`,
    ))!.json()) as { items: Record<string, unknown> };
    expect(shard.items[dups[0]!]).toBeDefined();
  });
});

describe("入力の検査と権限", () => {
  const lib = "tv";
  const e = libEnv(lib);
  const item = { key: "tv/a.png", keep: "tv/b.png" };

  it("件数の上限を超える・形が崩れていれば 400 で、何も動かさない", async () => {
    await put("tv/a.png", pngBytes(10, 10, 1));
    for (const items of [
      [],
      "x",
      Array.from({ length: 41 }, (_, i) => ({ key: `tv/${i}.png`, keep: "tv/b.png" })),
      [item, item],
      [{ key: "../a.png", keep: "tv/b.png" }],
      [{ key: "tv/a.png", keep: ".trash/1/tv/b.png" }],
      [{ key: "tv/a.png" }],
    ]) {
      const res = await post(e, `/v1/${lib}/similar/trash`, { items });
      expect(res.status, JSON.stringify(items).slice(0, 80)).toBe(400);
      expect(await res.json()).toEqual({ error: "bad_items" });
    }
    const two = libEnv(lib, { vars: { SIMILAR_TRASH_BATCH: "2" } });
    const over = await post(two, `/v1/${lib}/similar/trash`, {
      items: [item, { key: "tv/c.png", keep: "tv/b.png" }, { key: "tv/d.png", keep: "tv/b.png" }],
    });
    expect(over.status).toBe(400);
    for (const trashKeys of [
      [],
      "x",
      ["tv/a.png"],
      [".trash/1/.system/x.png"],
      [".trash/1/tv/a.png", ".trash/1/tv/a.png"],
      Array.from({ length: 41 }, (_, i) => `.trash/1/tv/${i}.png`),
    ]) {
      const res = await post(e, `/v1/${lib}/similar/undo`, { trashKeys });
      expect(res.status, JSON.stringify(trashKeys).slice(0, 80)).toBe(400);
    }
    expect(await exists("tv/a.png")).toBe(true);
  });

  it("読み取り専用のライブラリは 403、鍵が無ければ 401、知らないライブラリは 404", async () => {
    const ro = await post(env as Env, "/v1/b/similar/trash", {
      items: [{ key: "ro/keep.jpg", keep: "ro/other.jpg" }],
    });
    expect(ro.status).toBe(403);
    const roUndo = await post(env as Env, "/v1/b/similar/undo", {
      trashKeys: [".trash/1/ro/keep.jpg"],
    });
    expect(roUndo.status).toBe(403);
    for (const path of ["/v1/a/similar/trash", "/v1/a/similar/undo"]) {
      const res = await SELF.fetch(`${ORIGIN}${path}`, { method: "POST", body: "{}" });
      expect(res.status, path).toBe(401);
    }
    expect((await post(env as Env, "/v1/nope/similar/trash", { items: [item] })).status).toBe(404);
  });
});

describe("移動が途中で止まる", () => {
  const quiet = () => vi.spyOn(console, "error").mockImplementation(() => undefined);

  it("取り消しで写しは戻せたのにゴミ箱側を消せなくても、戻ったとしてアルバムと一覧へ戻す", async () => {
    const lib = "tg";
    // 索引を使い回す（本番と同じ）。一覧に戻ったかを追記で確かめるため
    const vars = { CATALOG_MAX_AGE_SECONDS: "300" } as Partial<Env>;
    const e = libEnv(lib, { vars });
    const K = "tg/keep.png";
    const X = "tg/x.png";
    const body = pngBytes(500, 500, 1, 50);
    await put(K, body);
    await put(X, body);
    await put("tg/a.png", pngBytes(10, 10, 2));
    await put("tg/b.png", pngBytes(10, 10, 3));
    const album = await mkAlbum(e, lib, "tg-1", ["tg/a.png", X, "tg/b.png"]);
    const before = await albumJson(album);
    const [r] = await trash(e, lib, [{ key: X, keep: K }]);
    const tk = trashKeyOf(r!);

    const realDelete = bucket().delete.bind(bucket());
    let failed = 0;
    const flaky = libEnv(lib, {
      vars,
      over: {
        // 写しの後のゴミ箱側の削除だけが一時的に失敗する（消し直しも 1 回失敗する）
        delete: ((k: string | string[]) => {
          if (k === tk && failed < 2) {
            failed++;
            return Promise.reject(new Error("transient r2 delete error"));
          }
          return realDelete(k);
        }) as R2Bucket["delete"],
      },
    });
    const log = quiet();
    let first: UndoResult[];
    try {
      first = await undo(flaky, lib, [tk]);
    } finally {
      log.mockRestore();
    }
    expect(first).toEqual([{ trashKey: tk, ok: true, key: X }]);
    expect(await exists(X)).toBe(true);
    expect(await albumJson(album)).toBe(before);
    expect(await sidecars(lib)).toEqual([]);
    const listed = await ok<{ items: { key: string }[] }>(
      call(e, `/v1/${lib}/folders?prefix=${lib}/&recursive=1&sort=name`),
    );
    expect(listed.items.map((i) => i.key)).toContain(X);
    // 消し直しにも失敗して残った写しは、ゴミ箱の画面から戻すと片付く（409 で行き詰まらない）
    expect(await exists(tk)).toBe(true);
    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey: tk }));
    expect(await exists(tk)).toBe(false);
    expect(await albumJson(album)).toBe(before);
  });

  it("同じ中身の写しがゴミ箱に残っていても、やり直し（/ops/restore）で戻せる", async () => {
    const lib = "tx";
    const e = libEnv(lib);
    const K = "tx/keep.png";
    const X = "tx/x.png";
    const body = pngBytes(500, 500, 1, 50);
    await put(K, body);
    await put(X, body);
    await put("tx/a.png", pngBytes(10, 10, 2));
    const album = await mkAlbum(e, lib, "tx-1", ["tx/a.png", X]);
    const [r] = await trash(e, lib, [{ key: X, keep: K }]);
    const tk = trashKeyOf(r!);
    // 前回の戻しが「元の key へ写した所」で止まった状態を作る
    await bucket().put(X, (await (await bucket().get(tk))!.arrayBuffer()) as ArrayBuffer);
    expect(await exists(tk)).toBe(true);

    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey: tk }));
    expect(await exists(X)).toBe(true);
    expect(await exists(tk)).toBe(false);
    // 中身が同じとして消した物なので、残す物が居るアルバムへは戻らない（従来の決まり）
    expect(await albumKeys(album)).toEqual(["tx/a.png", K]);
    expect(await sidecars(lib)).toEqual([]);
  });

  it("ゴミ箱へ写した後で元を消せなかった物は、ゴミ箱に写しを残さず move_failed を返す", async () => {
    const lib = "ty";
    const e = libEnv(lib);
    const K = "ty/keep.png";
    const X = "ty/x.png";
    const body = pngBytes(500, 500, 1, 50);
    await put(K, body);
    await put(X, body);
    const album = await mkAlbum(e, lib, "ty-1", [X]);
    const realDelete = bucket().delete.bind(bucket());
    let failed = false;
    const flaky = libEnv(lib, {
      over: {
        delete: ((k: string | string[]) => {
          if (k === X && !failed) {
            failed = true;
            return Promise.reject(new Error("transient r2 delete error"));
          }
          return realDelete(k);
        }) as R2Bucket["delete"],
      },
    });
    const log = quiet();
    let r: TrashResult[];
    try {
      r = await trash(flaky, lib, [{ key: X, keep: K }]);
    } finally {
      log.mockRestore();
    }
    expect(r).toEqual([{ key: X, ok: false, error: "move_failed" }]);
    expect(await exists(X)).toBe(true);
    expect(await albumKeys(album)).toEqual([X]);
    expect(await trashedCopies(X)).toEqual([]);
    expect(await sidecars(lib)).toEqual([]);
  });
});

describe("同じ中身の写しの片方にしか署名が無い", () => {
  const lib = "tq";
  const e = libEnv(lib);

  it("一覧と同じく集まりの署名で比べ、署名の無い古い写しも消せる", async () => {
    const L = look(40);
    const K = "tq/keep.png";
    const X1 = "tq/x1.png";
    const X2 = "tq/x2.png";
    await put(K, pngBytes(800, 600, 1, 50));
    const copy = pngBytes(400, 300, 2, 44);
    // 古い方（X1）はサムネが無く署名も無い。新しい方（X2）だけが署名を持つ
    await put(X1, copy);
    await put(X2, copy);
    await sign(e, lib, [
      [K, sigOf(L)],
      [X2, sigOf(L)],
    ]);
    for (let i = 0; i < 20; i++) {
      const r = await ok<{ pending: number }>(post(e, `/v1/${lib}/duplicates/scan`, {}));
      if (!r.pending) break;
    }
    const page = await ok<{
      groups: { id: string; items: { key: string; match: string; ow?: number }[] }[];
    }>(call(e, `/v1/${lib}/similar?tab=dup`));
    const g = page.groups.find((x) => x.id === K)!;
    expect(g.items.map((i) => [i.key, i.match])).toEqual([
      [K, "keeper"],
      [X1, "same"],
      [X2, "same"],
    ]);
    // 寸法は同じ中身の一員の物を使う（X1 自身の記録は無い）
    expect(g.items.find((i) => i.key === X1)!.ow).toBe(400);

    const r = await trash(e, lib, [
      { key: X1, keep: K },
      { key: X2, keep: K },
    ]);
    expect(r.map((x) => [x.key, x.ok && x.kind])).toEqual([
      [X1, "same"],
      [X2, "same"],
    ]);
  });
});

describe("同じアルバムで 2 回に分けて消し、片方だけ取り消す", () => {
  const lib = "tz";
  const e = libEnv(lib);
  const K = "tz/keep.png";
  const X = "tz/x.png";
  const Y = "tz/y.png";

  it("後で消した物の代わりの残す物は外さず、両方を取り消すと消す前と同じになる", async () => {
    const body = pngBytes(500, 500, 1, 50);
    for (const k of [K, X, Y]) await put(k, body);
    await put("tz/a.png", pngBytes(10, 10, 2));
    await put("tz/b.png", pngBytes(10, 10, 3));
    const album = await mkAlbum(e, lib, "tz-1", ["tz/a.png", X, Y, "tz/b.png"]);
    const before = await albumJson(album);
    const [r1] = await trash(e, lib, [{ key: X, keep: K }]);
    const [r2] = await trash(e, lib, [{ key: Y, keep: K }]);
    expect(await albumKeys(album)).toEqual(["tz/a.png", K, "tz/b.png"]);

    await undo(e, lib, [trashKeyOf(r1!)]);
    // Y はまだゴミ箱にいて、アルバムでは K が代わりを務めている
    expect(await albumKeys(album)).toEqual(["tz/a.png", X, K, "tz/b.png"]);

    await undo(e, lib, [trashKeyOf(r2!)]);
    expect(await albumJson(album)).toBe(before);
    expect(await sidecars(lib)).toEqual([]);
  });

  it("順を逆にして取り消しても、消す前と同じになる", async () => {
    const album = await mkAlbum(e, lib, "tz-2", ["tz/a.png", X, Y, "tz/b.png"]);
    const before = await albumJson(album);
    const [r1] = await trash(e, lib, [{ key: X, keep: K }]);
    const [r2] = await trash(e, lib, [{ key: Y, keep: K }]);
    await undo(e, lib, [trashKeyOf(r2!)]);
    expect(await albumKeys(album)).toEqual(["tz/a.png", K, Y, "tz/b.png"]);
    await undo(e, lib, [trashKeyOf(r1!)]);
    expect(await albumJson(album)).toBe(before);
  });

  it("同じ中身の物をゴミ箱の画面から戻すと、残す物はそのアルバムに居続け、後の取り消しでも外れない", async () => {
    const album = await mkAlbum(e, lib, "tz-3", ["tz/a.png", X, Y]);
    const [r1] = await trash(e, lib, [{ key: X, keep: K }]);
    const [r2] = await trash(e, lib, [{ key: Y, keep: K }]);
    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey: trashKeyOf(r2!) }));
    // Y は中身が同じで K が居るのでアルバムへは戻らない。このアルバムでは K が Y の代わりにずっと居る
    expect(await albumKeys(album)).toEqual(["tz/a.png", K]);
    expect((await rawAlbum(album)) as unknown as Record<string, unknown>).not.toHaveProperty(
      "keeperFor",
    );
    await undo(e, lib, [trashKeyOf(r1!)]);
    // X の取り消しは X を戻すだけ。K を外すと、Y も K もアルバムから消えてしまう
    expect(await albumKeys(album)).toEqual(["tz/a.png", X, K]);
    expect(await exists(Y)).toBe(true);
  });
});

describe("同じ回で消した物の片方をゴミ箱の画面から戻してから、直後の取り消し", () => {
  const lib = "tj";
  const e = libEnv(lib);

  it("戻した物の代わりの残す物は残り、取り消した物は元の位置へ戻る", async () => {
    const K = "tj/keep.png";
    const X = "tj/x.png";
    const Y = "tj/y.png";
    const body = pngBytes(500, 500, 1, 50);
    for (const k of [K, X, Y]) await put(k, body);
    await put("tj/a.png", pngBytes(10, 10, 2));
    await put("tj/b.png", pngBytes(10, 10, 3));
    const album = await mkAlbum(e, lib, "tj-1", ["tj/a.png", X, Y, "tj/b.png"]);
    const r = await trash(e, lib, [
      { key: X, keep: K },
      { key: Y, keep: K },
    ]);
    const tkX = trashKeyOf(r[0]!);
    const tkY = trashKeyOf(r[1]!);
    expect(await albumKeys(album)).toEqual(["tj/a.png", K, "tj/b.png"]);

    // 別の端末（ゴミ箱の画面）から Y だけを戻す
    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey: tkY }));
    expect(await albumKeys(album)).toEqual(["tj/a.png", K, "tj/b.png"]);

    // 6 秒の「元に戻す」はこの回の受け取りを全部送る（Y は既に戻っているので 404）
    const u = await undo(e, lib, [tkX, tkY]);
    expect(u.map((x) => x.ok)).toEqual([true, false]);
    expect(await albumKeys(album)).toEqual(["tj/a.png", X, K, "tj/b.png"]);
    for (const k of [K, X, Y]) expect(await exists(k), k).toBe(true);
    expect(await sidecars(lib)).toEqual([]);
  });
});

describe("残す物がいったんアルバムから外れても、代わりの控えは残る", () => {
  const lib = "tc";
  const e = libEnv(lib);

  const setup = async (p: string, extra: string[] = []) => {
    const K = `${p}/keep.png`;
    const X = `${p}/x.png`;
    const body = pngBytes(500, 500, 1, 50);
    for (const k of [K, X, ...extra]) await put(k, body);
    await put(`${p}/a.png`, pngBytes(10, 10, 2));
    await put(`${p}/b.png`, pngBytes(10, 10, 3));
    return { K, X };
  };

  it("残す物を 1 件ずつゴミ箱へ送って戻してから取り消すと、消す前と同じになる", async () => {
    const p = "tc/1";
    const { K, X } = await setup(p);
    const album = await mkAlbum(e, lib, "tc-1", [`${p}/a.png`, X, `${p}/b.png`]);
    const before = await albumKeys(album);
    const [r] = await trash(e, lib, [{ key: X, keep: K }]);
    expect(await albumKeys(album)).toEqual([`${p}/a.png`, K, `${p}/b.png`]);
    // 使う人から見れば何もしていない: 残す物をゴミ箱へ送ってすぐ戻す
    const { trashKey } = await ok<{ trashKey: string }>(
      post(e, `/v1/${lib}/ops/trash`, { key: K }),
    );
    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey }));
    expect(await albumKeys(album)).toEqual([`${p}/a.png`, K, `${p}/b.png`]);

    expect((await undo(e, lib, [trashKeyOf(r!)])).map((x) => x.ok)).toEqual([true]);
    expect(await albumKeys(album)).toEqual(before);
  });

  it("残す物を続けて別の残す物で消し、新しい方から両方を取り消すと、消す前と同じになる", async () => {
    const p = "tc/2";
    const J = `${p}/j.png`;
    const { K, X } = await setup(p, [J]);
    const album = await mkAlbum(e, lib, "tc-2", [`${p}/a.png`, X, `${p}/b.png`]);
    const before = await albumKeys(album);
    const [r1] = await trash(e, lib, [{ key: X, keep: K }]);
    const [r2] = await trash(e, lib, [{ key: K, keep: J }]);
    expect(await albumKeys(album)).toEqual([`${p}/a.png`, J, `${p}/b.png`]);
    expect((await undo(e, lib, [trashKeyOf(r2!)])).map((x) => x.ok)).toEqual([true]);
    expect(await albumKeys(album)).toEqual([`${p}/a.png`, K, `${p}/b.png`]);
    expect((await undo(e, lib, [trashKeyOf(r1!)])).map((x) => x.ok)).toEqual([true]);
    expect(await albumKeys(album)).toEqual(before);
  });

  it("残す物がゴミ箱のまま purge されれば、代わりの控えは畳まれる", async () => {
    const p = "tc/3";
    const J = `${p}/j.png`;
    const { K, X } = await setup(p, [J]);
    const album = await mkAlbum(e, lib, "tc-3", [`${p}/a.png`, X, `${p}/b.png`]);
    await trash(e, lib, [{ key: X, keep: K }]);
    const [r2] = await trash(e, lib, [{ key: K, keep: J }]);
    const keeperFor = async () =>
      ((await rawAlbum(album)) as unknown as { keeperFor?: Record<string, string[]> }).keeperFor;
    expect(await keeperFor()).toEqual({
      [`${lib}:${K}`]: [`${lib}:${X}`],
      [`${lib}:${J}`]: [`${lib}:${K}`],
    });
    // K を期限切れで消した（控えは消さない purge と同じ）。次に album を書く操作で畳まれる
    await bucket().delete(trashKeyOf(r2!));
    const other = `${p}/b.png`;
    const { trashKey } = await ok<{ trashKey: string }>(
      post(e, `/v1/${lib}/ops/trash`, { key: other }),
    );
    expect(await keeperFor()).toBeUndefined();
    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey }));
  });
});

describe("まとめて消した残す物で、古い口（duplicateOf）からも消す", () => {
  const lib = "th";
  const e = libEnv(lib);

  it("先にまとめて消した物を取り消しても、残す物は後で消した物の代わりとしてアルバムに残る", async () => {
    const K = "th/keep.png";
    const X = "th/x.png";
    const Y = "th/y.png";
    const body = pngBytes(500, 500, 1, 50);
    for (const k of [K, X, Y]) await put(k, body);
    await put("th/a.png", pngBytes(10, 10, 2));
    const album = await mkAlbum(e, lib, "th-1", ["th/a.png", X, Y]);
    const [r1] = await trash(e, lib, [{ key: X, keep: K }]);
    await ok(post(e, `/v1/${lib}/ops/trash`, { key: Y, duplicateOf: K }));
    expect(await albumKeys(album)).toEqual(["th/a.png", K]);
    expect((await rawAlbum(album)) as unknown as Record<string, unknown>).not.toHaveProperty(
      "keeperFor",
    );
    expect((await undo(e, lib, [trashKeyOf(r1!)])).map((x) => x.ok)).toEqual([true]);
    // Y は控えなしでゴミ箱に居る。アルバムでの Y の居場所は K だけ
    expect(await albumKeys(album)).toEqual(["th/a.png", X, K]);
  });
});

describe("取り消しでアルバムを書けない", () => {
  const lib = "tb";
  const quiet = () => vi.spyOn(console, "error").mockImplementation(() => undefined);
  const realPut = env.META.put.bind(env.META);
  /** albums.json の書き込みを先頭から fails 回だけ失敗させる */
  const albumsDown = (fails: number) => {
    let n = 0;
    return libEnv(lib, {
      meta: {
        put: ((k: string, ...rest: unknown[]) => {
          if (k === ALBUMS && n++ < fails) return Promise.reject(new Error("META unavailable"));
          return (realPut as (...a: unknown[]) => Promise<R2Object | null>)(k, ...rest);
        }) as R2Bucket["put"],
      },
    });
  };
  const setup = async (p: string) => {
    const e = libEnv(lib);
    const K = `${p}/keep.png`;
    const X = `${p}/x.png`;
    const body = pngBytes(500, 500, p.length, 50);
    await put(K, body);
    await put(X, body);
    await put(`${p}/a.png`, pngBytes(10, 10, 2));
    const album = await mkAlbum(e, lib, p, [`${p}/a.png`, X]);
    const before = await albumJson(album);
    const [r] = await trash(e, lib, [{ key: X, keep: K }]);
    return { e, X, album, before, tk: trashKeyOf(r!) };
  };

  it("一時的な失敗なら、同じ呼び出しの中で試し直してアルバムまで戻す", async () => {
    const { X, album, before, tk } = await setup("tb/1");
    const log = quiet();
    let u: UndoResult[];
    try {
      u = await undo(albumsDown(2), lib, [tk]);
    } finally {
      log.mockRestore();
    }
    expect(u).toEqual([{ trashKey: tk, ok: true, key: X }]);
    expect(await albumJson(album)).toBe(before);
    expect((await sidecars(lib)).filter((s) => s.includes("/tb/1/"))).toEqual([]);
  });

  it("続けて失敗したら albums_failed を返し、同じ受け取りでもう一度呼べばアルバムまで戻る", async () => {
    const { e, X, album, before, tk } = await setup("tb/2");
    const log = quiet();
    let u: UndoResult[];
    try {
      u = await undo(albumsDown(100), lib, [tk]);
    } finally {
      log.mockRestore();
    }
    expect(u).toEqual([{ trashKey: tk, ok: false, error: "albums_failed", status: 503 }]);
    // ファイルは戻っている。控えは残っているので、呼び直し（アプリが行う）でアルバムだけ直る
    expect(await exists(X)).toBe(true);
    expect((await sidecars(lib)).filter((s) => s.includes("/tb/2/"))).toHaveLength(1);
    expect(await undo(e, lib, [tk])).toEqual([{ trashKey: tk, ok: true, key: X }]);
    expect(await albumJson(album)).toBe(before);
    expect((await sidecars(lib)).filter((s) => s.includes("/tb/2/"))).toEqual([]);
  });
});

describe("まとめて消す時に戻すのも失敗する", () => {
  const lib = "tp";
  const quiet = () => vi.spyOn(console, "error").mockImplementation(() => undefined);

  const failing = (X: string, putFails: number) => {
    const realPut = env.META.put.bind(env.META);
    const realBPut = bucket().put.bind(bucket());
    let n = 0;
    return libEnv(lib, {
      meta: {
        put: ((k: string, ...rest: unknown[]) =>
          k === ALBUMS
            ? Promise.reject(new Error("META unavailable"))
            : (realPut as (...a: unknown[]) => Promise<R2Object | null>)(
                k,
                ...rest,
              )) as R2Bucket["put"],
      },
      over: {
        put: ((k: string, ...rest: unknown[]) => {
          if (k === X && n++ < putFails) return Promise.reject(new Error("R2 unavailable"));
          return (realBPut as (...a: unknown[]) => Promise<R2Object | null>)(k, ...rest);
        }) as R2Bucket["put"],
      },
    });
  };

  it("戻す写しが一時的に失敗しても試し直して元の key へ戻し、albums_failed を返す", async () => {
    const e = libEnv(lib);
    const K = "tp/1/keep.png";
    const X = "tp/1/x.png";
    const body = pngBytes(500, 500, 1, 50);
    await put(K, body);
    await put(X, body);
    const album = await mkAlbum(e, lib, "tp-1", [X]);
    const before = await albumJson(album);
    const log = quiet();
    let r: TrashResult[];
    try {
      r = await trash(failing(X, 1), lib, [{ key: X, keep: K }]);
    } finally {
      log.mockRestore();
    }
    expect(r).toEqual([{ key: X, ok: false, error: "albums_failed" }]);
    expect(await exists(X)).toBe(true);
    expect(await trashedCopies(X)).toEqual([]);
    expect(await albumJson(album)).toBe(before);
  });

  it("戻せなければ put_back_failed とゴミ箱の key を返し、控えを残してゴミ箱から戻せる", async () => {
    const e = libEnv(lib);
    const K = "tp/2/keep.png";
    const X = "tp/2/x.png";
    const body = pngBytes(500, 500, 2, 50);
    await put(K, body);
    await put(X, body);
    const album = await mkAlbum(e, lib, "tp-2", [X]);
    const before = await albumJson(album);
    const log = quiet();
    let r: TrashResult[];
    try {
      r = await trash(failing(X, 100), lib, [{ key: X, keep: K }]);
    } finally {
      log.mockRestore();
    }
    expect(r).toEqual([
      { key: X, ok: false, error: "put_back_failed", trashKey: expect.stringMatching(TRASHED) },
    ]);
    const tk = (r[0] as { trashKey: string }).trashKey;
    expect(await exists(X)).toBe(false);
    const listed = await ok<{ items: { key: string; trashKey: string }[] }>(
      call(e, `/v1/${lib}/trash`),
    );
    expect(listed.items.filter((i) => i.key === X).map((i) => i.trashKey)).toEqual([tk]);
    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey: tk }));
    expect(await exists(X)).toBe(true);
    expect(await albumJson(album)).toBe(before);
  });
});

describe("1 件ずつのゴミ箱で元の物が無い", () => {
  const lib = "to";
  const e = libEnv(lib);

  it("404 を返し、アルバムの控えを残さない", async () => {
    const X = "to/x.png";
    await put(X, pngBytes(10, 10, 1));
    await mkAlbum(e, lib, "to-1", [X]);
    // 別の口（/ops/move・別の端末のゴミ箱）が先に動かした
    await bucket().delete(X);
    const res = await post(e, `/v1/${lib}/ops/trash`, { key: X });
    expect(res.status).toBe(404);
    expect(await sidecars(lib)).toEqual([]);
  });
});

describe("同じアルバムから何百件も消しても、1 回の外部呼び出しは増え続けない", () => {
  const lib = "tn";
  // Worker が R2 に出す呼び出しを数える（本番では 1 リクエスト 1000 回が上限）
  const COUNTED = new Set(["get", "put", "head", "delete", "list", "createMultipartUpload"]);
  let calls = 0;
  const counted = (b: R2Bucket): R2Bucket =>
    new Proxy(b, {
      get(target, prop) {
        const v = Reflect.get(target, prop) as unknown;
        if (typeof v !== "function") return v;
        return (...a: unknown[]) => {
          if (COUNTED.has(String(prop))) calls++;
          return (v as (...a: unknown[]) => unknown).apply(target, a);
        };
      },
    });
  const base = libEnv(lib);
  const e = {
    ...base,
    LIB_TN: counted(base.LIB_TN as R2Bucket),
    META: counted(base.META),
  } as Env;

  it("消した物の跡がアルバムに溜まっても、後の回の呼び出しは最初の回とほぼ同じ", async () => {
    const BATCH = 40;
    const N = BATCH * 5;
    const d = (i: number) => `${lib}/d${i}.png`;
    const k = (i: number) => `${lib}/k${i}.png`;
    for (let i = 0; i < N; i++) {
      const body = pngBytes(10, 10, i, 48);
      await put(d(i), body);
      await put(k(i), body);
    }
    const album = await mkAlbum(
      e,
      lib,
      "tn-1",
      Array.from({ length: N }, (_, i) => d(i)),
    );
    // アプリは中身の確認を終えてから束を出す
    for (let i = 0; i < 20; i++) {
      const r = await ok<{ pending: number }>(post(e, `/v1/${lib}/duplicates/scan`, {}));
      if (r.pending === 0) break;
    }
    const perBatch: number[] = [];
    for (let b = 0; b < N / BATCH; b++) {
      const items = Array.from({ length: BATCH }, (_, j) => ({
        key: d(b * BATCH + j),
        keep: k(b * BATCH + j),
      }));
      calls = 0;
      const results = await trash(e, lib, items);
      perBatch.push(calls);
      expect(
        results.every((r) => r.ok),
        JSON.stringify(results),
      ).toBe(true);
    }
    expect(await albumKeys(album)).toEqual(Array.from({ length: N }, (_, i) => k(i)));
    // 跡 1 件ごとに head すると、前の回 1 回につき 80 回ずつ増えていた
    const growth = perBatch[perBatch.length - 1]! - perBatch[0]!;
    expect(growth, perBatch.join()).toBeLessThanOrEqual(perBatch.length * 2);
    // env.ts の上限 40 件の根拠（1 件あたり約 12 回）に収まる
    expect(Math.max(...perBatch), perBatch.join()).toBeLessThanOrEqual(BATCH * 13);
  }, 120_000);
});

describe("アルバムの跡を確かめる外部呼び出しには上限がある", () => {
  // Worker が R2 に出す呼び出しを数える（本番では 1 リクエスト 1000 回が上限）
  const COUNTED = new Set(["get", "put", "head", "delete", "list", "createMultipartUpload"]);
  let calls = 0;
  const counted = (b: R2Bucket): R2Bucket =>
    new Proxy(b, {
      get(target, prop) {
        const v = Reflect.get(target, prop) as unknown;
        if (typeof v !== "function") return v;
        return (...a: unknown[]) => {
          if (COUNTED.has(String(prop))) calls++;
          return (v as (...a: unknown[]) => unknown).apply(target, a);
        };
      },
    });
  // 本番の上限（150・80）を超える数の跡を置くと、同じ R2 を使う他のテストのファイルが遅れて落ちる。
  // 上限を env で下げ、その数を超える跡で打ち切りを確かめる（上限そのものは定数なので数だけの話）
  const BUDGET = 12;
  const countedEnv = (lib: string, o: LibOpts = {}) => {
    const base = libEnv(lib, { ...o, vars: { TRASH_PROBE_BUDGET: String(BUDGET), ...o.vars } });
    const binding = `LIB_${lib.toUpperCase()}`;
    return {
      ...base,
      [binding]: counted(base[binding] as R2Bucket),
      META: counted(base.META),
    } as Env;
  };
  const ghostId = (lib: string, g: number) => `${lib}:${lib}/ghost${g}.png`;

  /**
   * アルバムに live 件の物と ghosts 件の跡（並びの控え）を置く。跡は floors 個の送った時刻に散らし、
   * どれも所属の控えを持つ。purged なら .trash の実体を置かない（この直しより前の purge は控えを残した）
   */
  async function seed(lib: string, live: number, ghosts: number, floors: number, purged: boolean) {
    const items = [];
    for (let i = 0; i < live; i++) {
      const key = `${lib}/live${i}.png`;
      await put(key, pngBytes(10, 10, i));
      items.push({ key, lib, createdAt: 1 });
    }
    const order = items.map((i) => `${lib}:${i.key}`);
    const base = Date.now() - 1000 * 1000;
    for (let g = 0; g < ghosts; g++) {
      const ts = base + (g % floors);
      const key = `${lib}/ghost${g}.png`;
      order.splice(Math.min(order.length, g * 2), 0, ghostId(lib, g));
      await env.META.put(
        `.system/trash-albums/${lib}/${ts}/${key}.json`,
        JSON.stringify([{ albumId: `${lib}-album`, item: { key, lib, createdAt: 1 } }]),
      );
      if (!purged) await bucket().put(`.trash/${ts}/${key}`, new Uint8Array([9]));
    }
    const data = ((await (await env.META.get(ALBUMS))?.json()) as
      { version: 1; albums: unknown[] } | undefined) ?? { version: 1, albums: [] };
    data.albums.push({ id: `${lib}-album`, title: lib, items, trashOrder: order });
    await env.META.put(ALBUMS, JSON.stringify(data));
    return `${lib}-album`;
  }
  const ghostsLeft = async (lib: string, album: string, ghosts: number) => {
    const order = new Set((await rawAlbum(album)).trashOrder ?? []);
    return Array.from({ length: ghosts }, (_, g) => ghostId(lib, g)).filter((id) => order.has(id))
      .length;
  };
  /** 跡の無いアルバムで同じ 1 件を消した時の呼び出しの数（跡の分を差し引くための基準） */
  const plainTrashCalls = async (lib: string) => {
    await seed(lib, 2, 0, 1, true);
    calls = 0;
    await ok(post(countedEnv(lib), `/v1/${lib}/ops/trash`, { key: `${lib}/live0.png` }));
    return calls;
  };

  it("purge 済みの跡がいくらあっても書き込みは上限の内で通り、書くたびに跡が減って無くなる", async () => {
    const lib = "tq";
    const G = 40;
    const plain = await plainTrashCalls("tq0");
    const album = await seed(lib, 8, G, 4, true);
    const e = countedEnv(lib);
    const left = [G];
    for (let i = 0; i < 8 && left[left.length - 1]! > 0; i++) {
      calls = 0;
      await ok(post(e, `/v1/${lib}/ops/trash`, { key: `${lib}/live${i}.png` }));
      // 跡を確かめる分は上限まで（跡 1 件ごとに head していた時は、跡の数だけ増えた）
      expect(calls - plain, `${calls} - ${plain}`).toBeLessThanOrEqual(BUDGET);
      left.push(await ghostsLeft(lib, album, G));
    }
    // 1 回で全部は確かめないが、書くたびに落ちて、最後は無くなる
    expect(left[left.length - 1], left.join()).toBe(0);
    for (let i = 1; i < left.length; i++) expect(left[i]!, left.join()).toBeLessThan(left[i - 1]!);
  }, 60_000);

  it("1 件ずつ消した跡（送った時刻が全部違う）がいくらあっても上限の内で通り、跡は残す", async () => {
    const lib = "ts1";
    const G = 30;
    const plain = await plainTrashCalls("ts0");
    const album = await seed(lib, 4, G, G, false);
    calls = 0;
    await ok(post(countedEnv(lib), `/v1/${lib}/ops/trash`, { key: `${lib}/live0.png` }));
    expect(calls - plain, `${calls} - ${plain}`).toBeLessThanOrEqual(BUDGET);
    // 確かめきれなかった跡も「まだ戻せる」として残す（落とすと、戻した時に元の位置へ戻らない）
    expect(await ghostsLeft(lib, album, G)).toBe(G);
  }, 60_000);

  it("まとめて消す口は、albums.json の競合でやり直しても跡を確かめ直さない", async () => {
    /** 40 組を置いたアルバム（跡は ghosts 件）で、1 回競合させて 40 件を消した時の呼び出しの数 */
    const run = async (lib: string, ghosts: number) => {
      const album = await seed(lib, 0, ghosts, ghosts || 1, false);
      const pairs: { key: string; keep: string }[] = [];
      const data = (await (await env.META.get(ALBUMS))!.json()) as { albums: RawAlbum[] };
      const a = data.albums.find((x) => x.id === album)!;
      for (let i = 0; i < 40; i++) {
        const body = pngBytes(20, 20, 1000 + i, 64);
        await put(`${lib}/d${i}.png`, body);
        await put(`${lib}/k${i}.png`, body);
        a.items.push({ key: `${lib}/d${i}.png`, lib });
        pairs.push({ key: `${lib}/d${i}.png`, keep: `${lib}/k${i}.png` });
      }
      await env.META.put(ALBUMS, JSON.stringify(data));
      const plain = libEnv(lib);
      for (let i = 0; i < 10; i++) {
        const r = await ok<{ pending: number }>(post(plain, `/v1/${lib}/duplicates/scan`, {}));
        if (r.pending === 0) break;
      }
      // アプリは 2 つの塊を同時に送るので、albums.json の書き込みが 1 回負ける
      let conflicts = 1;
      const realPut = env.META.put.bind(env.META);
      const e = countedEnv(lib, {
        meta: {
          put: ((k: string, ...rest: unknown[]) => {
            if (k === ALBUMS && conflicts > 0) {
              conflicts--;
              return Promise.resolve(null);
            }
            return (realPut as (...x: unknown[]) => Promise<R2Object | null>)(k, ...rest);
          }) as R2Bucket["put"],
        },
      });
      calls = 0;
      const results = await trash(e, lib, pairs);
      expect(
        results.every((r) => r.ok),
        JSON.stringify(results),
      ).toBe(true);
      expect(conflicts).toBe(0);
      expect(await ghostsLeft(lib, album, ghosts)).toBe(ghosts);
      return calls;
    };
    const plain = await run("tr0", 0);
    const many = await run("tr", 30);
    // 跡 1 件ごとに数えていた時は、競合 1 回で跡の分を 2 回払っていた（この数で 60 回余り多い）
    expect(many - plain, `${many} - ${plain}`).toBeLessThanOrEqual(BUDGET);
    // 本番の上限（40 件、跡を確かめる分 80 回）でも 1000 回に届かない
    expect(plain + 80).toBeLessThan(1000);
  }, 60_000);

  it("期限切れの purge は、ゴミ箱の本体と一緒にアルバムの所属の控えも消す", async () => {
    const lib = "tu";
    const old = Date.now() - 40 * 86_400_000;
    const fresh = Date.now() - 1000;
    for (const ts of [old, fresh]) {
      await bucket().put(`.trash/${ts}/${lib}/x.png`, new Uint8Array([1]));
      await env.META.put(sidecarPath(lib, `.trash/${ts}/${lib}/x.png`), "[]");
    }
    const only = {
      ...libEnv(lib),
      LIBRARIES: JSON.stringify([{ id: lib, binding: `LIB_${lib.toUpperCase()}`, title: lib }]),
    } as Env;
    await purgeTrash(only);
    expect(await exists(`.trash/${old}/${lib}/x.png`)).toBe(false);
    expect(await exists(`.trash/${fresh}/${lib}/x.png`)).toBe(true);
    expect(await sidecars(lib)).toEqual([sidecarPath(lib, `.trash/${fresh}/${lib}/x.png`)]);
  });
});

describe("ゴミ箱の間に同じ key の別の物がサムネを置いた", () => {
  const lib = "tw";
  const e = libEnv(lib);
  const thumb = (k: string) => `.system/thumbs/${lib}/${k}.webp`;
  const WEBP = Uint8Array.from([
    ...[0x52, 0x49, 0x46, 0x46, 4, 0, 0, 0, 0x57, 0x45, 0x42, 0x50],
    ...new Array<number>(8).fill(0),
  ]);
  const putThumb = (k: string) =>
    call(e, `/v1/${lib}/thumb?key=${encodeURIComponent(k)}`, {
      method: "PUT",
      headers: { "content-type": "image/webp", "content-length": String(WEBP.length) },
      body: WEBP,
    });
  const upload = (k: string, body: Uint8Array) =>
    call(e, `/v1/${lib}/objects?key=${encodeURIComponent(k)}`, {
      method: "PUT",
      headers: { "content-type": "image/png", "content-length": String(body.length) },
      body,
    });
  const trashOne = async (k: string) =>
    (await ok<{ trashKey: string }>(post(e, `/v1/${lib}/ops/trash`, { key: k }))).trashKey;
  const thumbStored = async (k: string) => {
    const todo = await ok<{ items: { key: string; thumbStored: boolean }[] }>(
      call(e, `/v1/${lib}/similar/todo?shard=${shardOf(k)}`),
    );
    return todo.items.find((i) => i.key === k)?.thumbStored;
  };

  it("戻した物には後の物のサムネを付けずに消し、送る前に置いたサムネはそのまま使う", async () => {
    const K = `${lib}/k.png`;
    await ok(upload(K, pngBytes(30, 30, 1, 60)), 201);
    await ok(putThumb(K), 201);
    const first = await trashOne(K);
    // 同じ名前で別の絵を上げ、そのサムネを置いてから、その物もゴミ箱へ送る
    await ok(upload(K, pngBytes(30, 30, 2, 60)), 201);
    await ok(putThumb(K), 201);
    await trashOne(K);
    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey: first }));
    expect(await env.META.head(thumb(K))).toBeNull();
    expect(await thumbStored(K)).toBe(false);

    const M = `${lib}/m.png`;
    await ok(upload(M, pngBytes(30, 30, 3, 60)), 201);
    await ok(putThumb(M), 201);
    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey: await trashOne(M) }));
    expect(await env.META.head(thumb(M))).not.toBeNull();
    expect(await thumbStored(M)).toBe(true);
  });
});

describe("ゴミ箱へ送った物の見た目の署名", () => {
  const lib = "tv";
  const e = libEnv(lib);

  it("同じ置き場へ別の署名を送っても消えず、ゴミ箱から戻すと照合済みのまま", async () => {
    const X = `${lib}/x.png`;
    await put(X, pngBytes(40, 40, 7, 60));
    let other = "";
    for (let i = 0; !other; i++) {
      if (shardOf(`${lib}/o${i}.png`) === shardOf(X)) other = `${lib}/o${i}.png`;
    }
    await put(other, pngBytes(40, 40, 8, 60));
    await sign(e, lib, [[X, sigOf(look(1))]]);
    const { trashKey } = await ok<{ trashKey: string }>(
      post(e, `/v1/${lib}/ops/trash`, { key: X }),
    );
    await sign(e, lib, [[other, sigOf(look(2))]]);
    await ok(post(e, `/v1/${lib}/ops/restore`, { trashKey }));
    const todo = await ok<{ items: { key: string }[] }>(
      call(e, `/v1/${lib}/similar/todo?shard=${shardOf(X)}`),
    );
    expect(todo.items.map((i) => i.key)).not.toContain(X);
  });
});
