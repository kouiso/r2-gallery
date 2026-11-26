import { createExecutionContext, env, SELF, waitOnExecutionContext } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

import worker, { type Env } from "./index";
import { encodeSig, SIG_BYTES } from "./lib/similar/core";
import { shardOf } from "./lib/similar/store";
import { resetSimilarMemory } from "./routes/similar";

declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    LIB_A: R2Bucket;
    LIB_B: R2Bucket;
  }
}

/*
 * 見た目の照合の読み取り・署名の受け取りの口（/similar/status・todo・signatures・一覧・relabel）。
 *
 * テストのファイルどうしは同じ R2 を同時に使う（isolatedStorage を切ってある）。ライブラリ a には
 * 他のファイルが絶えず物を足し、a 全体の件数を数えるテストもあるので、ここでは a に物を置かない。
 * 他のファイルがほとんど使わない LIB_B の一部（接頭辞）だけが見える「仮のライブラリ」を場面ごとに作り、
 * 署名・ハッシュ・索引の置き場もそのライブラリ専用にする（件数をそのまま比べられる）。
 */

/** 仮のライブラリの物を置くバケット */
const bucket = () => env.LIB_B;

const ORIGIN = "https://example.test";
const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/* ---------------- 仮のライブラリ ---------------- */

const TRASHED = /^\.trash\/\d+\//;

/**
 * LIB_B のうち prefix の下だけが見えるバケット。一覧を作る時の列挙を接頭辞に絞り、
 * それ以外の呼び出しは実物へそのまま渡す。over で一部の呼び出しを差し替えられる。
 */
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

interface LibOpts {
  readOnly?: boolean;
  over?: Partial<R2Bucket>;
  vars?: Partial<Env>;
}

/** id の名前で、LIB_B の `${id}/` の下だけを持つ書き込みできるライブラリを足した env */
function libEnv(id: string, o: LibOpts = {}): Env {
  const binding = `LIB_${id.toUpperCase()}`;
  return {
    ...env,
    LIBRARIES: JSON.stringify([
      { id: "a", binding: "LIB_A", title: "Test A" },
      { id: "b", binding: "LIB_B", title: "Test B", readOnly: true },
      { id, binding, title: id, ...(o.readOnly ? { readOnly: true } : {}) },
    ]),
    [binding]: scopedBucket(`${id}/`, o.over),
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

async function ok<T>(res: Response | Promise<Response>): Promise<T> {
  const r = await res;
  const text = await r.text();
  expect(r.status, text).toBe(200);
  return JSON.parse(text) as T;
}

/* ---------------- 絵と署名 ---------------- */

/** 先頭が PNG の印と IHDR（寸法）で、残りは seed ごとに違うバイト列。64 バイトを超えない */
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

/** SOF0 だけを持つ最小の JPEG の頭 */
function jpegBytes(w: number, h: number, seed: number): Uint8Array {
  const b = new Uint8Array(36);
  b.set([0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 3]);
  for (let i = 12; i < b.length; i++) b[i] = (seed * 17 + i * 5) % 251;
  return b;
}

async function put(key: string, body: Uint8Array): Promise<string> {
  const o = await bucket().put(key, body);
  return o!.etag;
}

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

/** 署名の中身。絵を作らずに、判定に効く欄を直接決める（しきい値の検証は core.test.ts が持つ） */
interface Look {
  p: Uint8Array;
  d: Uint8Array;
  m: Uint8Array;
  grid: Uint8Array;
  color: Uint8Array;
}

/** seed ごとにハッシュが互いに遠い絵。格子は左右で値が違う（反転と見分けるため） */
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
const withCell = (g: Uint8Array, k: number, delta: number) => {
  const out = Uint8Array.from(g);
  out[k] = out[k]! + delta;
  return out;
};
const flipGrid = (g: Uint8Array) =>
  Uint8Array.from({ length: 256 }, (_, k) => g[(k & ~15) | (15 - (k & 15))]!);
const swapColor = (c: Uint8Array) =>
  Uint8Array.from({ length: 12 }, (_, i) => c[(Math.floor(i / 3) ^ 1) * 3 + (i % 3)]!);

/** 左右反転した絵: 自分の pHash が相手の反転 pHash と同じになる */
const mirrorOf = (l: Look): Look => ({
  p: l.m,
  d: flipBits(l.d, 20),
  m: l.p,
  grid: flipGrid(l.grid),
  color: swapColor(l.color),
});
/** 32px より大きい描き足し: ハッシュは近いが格子の 1 マスが大きく違う → similar */
const similarOf = (l: Look): Look => ({
  ...l,
  p: flipBits(l.p, 6),
  d: flipBits(l.d, 6),
  m: flipBits(l.m, 6),
  grid: withCell(l.grid, 0, 40),
});
/** 格子の 1 マスだけ少し違う: same のまま。寸法と形式が同じなら差分かも */
const tweakOf = (l: Look): Look => ({ ...l, grid: withCell(l.grid, 0, 8) });

function sigOf(l: Look, o: { w?: number; h?: number; flags?: number } = {}): string {
  const s = new Uint8Array(SIG_BYTES);
  s.set(l.p, 0);
  s.set(l.d, 8);
  s.set(l.m, 16);
  s.set(l.grid, 24);
  s.set(l.color, 280);
  const w = o.w ?? 100;
  const h = o.h ?? 100;
  s.set([w >> 8, w & 255, h >> 8, h & 255], 292);
  s[296] = o.flags ?? 0;
  return encodeSig(s);
}

interface SigResult {
  stored: number;
  stale: number;
  failRecorded: number;
}

/** key ごとに今の etag を付けて署名を送る（200 件ずつ） */
async function sign(e: Env, lib: string, list: [string, string][], src: "t" | "o" = "t") {
  const total: SigResult = { stored: 0, stale: 0, failRecorded: 0 };
  for (let i = 0; i < list.length; i += 200) {
    const items = await Promise.all(
      list.slice(i, i + 200).map(async ([key, sig]) => ({
        key,
        etag: (await bucket().head(key))!.etag,
        src,
        sig,
      })),
    );
    const r = await ok<SigResult>(post(e, `/v1/${lib}/similar/signatures`, { alg: "vs1", items }));
    total.stored += r.stored;
    total.stale += r.stale;
    total.failRecorded += r.failRecorded;
  }
  return total;
}

async function scanHashes(e: Env, lib: string) {
  for (let i = 0; i < 30; i++) {
    const r = await ok<{ pending: number }>(post(e, `/v1/${lib}/duplicates/scan`, {}));
    if (r.pending === 0) return;
  }
  throw new Error("hash scan did not finish");
}

const shardPath = (lib: string, n: number) =>
  `.system/similar/${lib}/${String(n).padStart(2, "0")}.json`;

async function shardItems(lib: string, key: string): Promise<Record<string, unknown[]>> {
  const o = await env.META.get(shardPath(lib, shardOf(key)));
  return o ? ((await o.json()) as { items: Record<string, unknown[]> }).items : {};
}

/** 同じ置き場に入る key を n 個作る */
function keysInShard(base: string, n: number, shard?: number, ext = "png"): string[] {
  const out: string[] = [];
  const want = shard ?? shardOf(`${base}0.${ext}`);
  for (let i = 0; out.length < n; i++) {
    const k = `${base}${i}.${ext}`;
    if (shardOf(k) === want) out.push(k);
  }
  return out;
}

/* ---------------- 応答の形 ---------------- */

interface TodoPage {
  shard: number;
  items: {
    key: string;
    etag: string;
    size: number;
    ext: string;
    url: string;
    thumbUrl: string;
    thumbStored: boolean;
  }[];
  next: string | null;
  pendingInShard: number;
}

interface Status {
  alg: string;
  params: string;
  images: number;
  signed: number;
  failed: number;
  flat: number;
  pending: number;
  pendingWithThumb: number;
  pendingNoThumb: number;
  pendingBytesEstimate: number;
}

interface Item {
  key: string;
  url: string;
  size: number;
  match: string;
  ph?: number;
  dh?: number;
  variant: boolean;
  ow?: number;
  oh?: number;
}
interface SimGroup {
  id: string;
  tier: string;
  reclaim: number;
  items: Item[];
  more: number;
}
interface SimPage {
  groups: SimGroup[];
  cursor: string | null;
  total: number;
  summary: {
    dup: { groups: number; items: number; reclaimable: number };
    similar: { groups: number; items: number };
    crowded: number;
    coverage: { images: number; signed: number; pending: number; failed: number; flat: number };
    hashPending: number;
    hashSkipped: number;
  };
}

const todo = (e: Env, lib: string, q: string) =>
  ok<TodoPage>(call(e, `/v1/${lib}/similar/todo?${q}`));
const status = (e: Env, lib: string) => ok<Status>(call(e, `/v1/${lib}/similar/status`));

async function allGroups(e: Env, lib: string, tab: string, limit = 100): Promise<SimPage> {
  const groups: SimGroup[] = [];
  let cursor: string | null = null;
  let page: SimPage;
  do {
    page = await ok<SimPage>(
      call(
        e,
        `/v1/${lib}/similar?tab=${tab}&limit=${limit}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`,
      ),
    );
    groups.push(...page.groups);
    cursor = page.cursor;
  } while (cursor);
  return { ...page, groups };
}

const shape = (g: SimGroup) => g.items.map((i) => [i.key, i.match, i.variant]);

/* ---------------- todo / signatures ---------------- */

describe("署名が無い物の一覧と署名の受け取り", () => {
  const lib = "sq";
  const e = libEnv(lib);
  const sig = sigOf(look(100));

  it("置き場ごとに key の順で返し、after で続きが取れる（途中で署名が入っても飛ばさない）", async () => {
    const keys = keysInShard("sq/page/", 5);
    const n = shardOf(keys[0]!);
    for (const [i, k] of keys.entries()) await put(k, pngBytes(10, 10, i));
    // 同じ置き場の動画・別の置き場の画像は出ない
    const video = keysInShard("sq/page/v", 1, n, "mp4")[0]!;
    await put(video, pngBytes(10, 10, 99));
    const other = keysInShard("sq/page/o", 1, (n + 1) % 32)[0]!;
    await put(other, pngBytes(10, 10, 98));

    const seen: string[] = [];
    let after = "";
    for (let round = 0; round < 10; round++) {
      const page = await todo(e, lib, `shard=${n}&limit=2${after ? `&after=${after}` : ""}`);
      expect(page.shard).toBe(n);
      expect(page.pendingInShard).toBe(5);
      expect(page.items.length).toBeLessThanOrEqual(2);
      seen.push(...page.items.map((i) => i.key));
      if (!page.next) break;
      after = encodeURIComponent(page.next);
    }
    expect(seen).toEqual([...keys].sort());

    const first = await todo(e, lib, `shard=${n}&limit=2`);
    const it0 = first.items[0]!;
    expect(it0.etag).toBe((await bucket().head(it0.key))!.etag);
    expect(it0.size).toBe(40);
    expect(it0.ext).toBe("png");
    expect(it0.thumbStored).toBe(false);
    expect(it0.url).toMatch(/^https:\/\/example\.test\/m\/sq\//);
    // 1 ページ目の先頭に署名が入っても、続き（after）は残りを飛ばさない
    expect((await sign(e, lib, [[it0.key, sig]])).stored).toBe(1);
    const second = await todo(
      e,
      lib,
      `shard=${n}&limit=2&after=${encodeURIComponent(first.next!)}`,
    );
    expect(second.items.map((i) => i.key)).toEqual([...keys].sort().slice(2, 4));
    expect(second.pendingInShard).toBe(4);
  });

  it("置き場の番号が無い・範囲外なら 400", async () => {
    for (const q of ["", "shard=32", "shard=-1", "shard=x", "shard=001"]) {
      expect((await call(e, `/v1/${lib}/similar/todo?${q}`)).status, q).toBe(400);
    }
  });

  it("中身が変わって etag が変わると記録は無効になり、残りに戻る", async () => {
    const key = "sq/etag/a.png";
    await put(key, pngBytes(10, 10, 1));
    const n = shardOf(key);
    expect((await sign(e, lib, [[key, sig]])).stored).toBe(1);
    expect((await todo(e, lib, `shard=${n}`)).items.map((i) => i.key)).not.toContain(key);
    const newEtag = await put(key, pngBytes(10, 10, 2));
    const back = (await todo(e, lib, `shard=${n}`)).items.find((i) => i.key === key);
    expect(back?.etag).toBe(newEtag);
  });

  it("失敗の印を置いた物は残りに出ず、別の端末の失敗で有効な署名を潰さない", async () => {
    const [bad, good] = keysInShard("sq/fail/", 2);
    await put(bad!, pngBytes(10, 10, 3));
    await put(good!, pngBytes(10, 10, 4));
    const etag = async (k: string) => (await bucket().head(k))!.etag;
    const r = await ok<SigResult>(
      post(e, `/v1/${lib}/similar/signatures`, {
        alg: "vs1",
        items: [{ key: bad, etag: await etag(bad!), fail: "decode" }],
      }),
    );
    expect(r).toEqual({ stored: 0, stale: 0, failRecorded: 1 });
    const n = shardOf(bad!);
    expect((await todo(e, lib, `shard=${n}`)).items.map((i) => i.key)).not.toContain(bad);
    expect((await shardItems(lib, bad!))[bad!]).toEqual([await etag(bad!), null, "decode"]);

    expect((await sign(e, lib, [[good!, sig]])).stored).toBe(1);
    const again = await ok<SigResult>(
      post(e, `/v1/${lib}/similar/signatures`, {
        alg: "vs1",
        items: [{ key: good, etag: await etag(good!), src: "t", fail: "too_large" }],
      }),
    );
    expect(again.failRecorded).toBe(0);
    expect((await shardItems(lib, good!))[good!]![1]).toBe(sig);
  });

  it("算法の版違いは 409、壊れた入力は 400 で何も置かず、etag 違いは stale と数えて置かない", async () => {
    const key = "sq/bad/a.png";
    const etag = await put(key, pngBytes(10, 10, 5));
    const good = { key, etag, src: "t", sig };
    for (const alg of ["vs0", undefined]) {
      const res = await post(e, `/v1/${lib}/similar/signatures`, { alg, items: [good] });
      expect(res.status).toBe(409);
      expect(await res.json()).toEqual({ error: "alg_mismatch" });
    }
    const zeroW = sigOf(look(100), { w: 0 });
    const cases: unknown[] = [
      "x",
      Array.from({ length: 201 }, () => good),
      [good, { ...good, sig: sig.slice(0, -4) }],
      [good, { ...good, sig: "!".repeat(396) }],
      [good, { ...good, sig: zeroW }],
      [good, { ...good, key: "sq/bad/clip.mp4" }],
      [good, { key, etag }],
      [{ ...good, fail: "decode" }],
      [{ key, etag, sig }],
      [{ ...good, src: "x" }],
      [{ key, etag, fail: "nope" }],
      [good, good],
      [{ ...good, key: "../x.png" }],
      [{ ...good, key: ".system/x.png" }],
      [{ ...good, etag: "" }],
    ];
    for (const items of cases) {
      const res = await post(e, `/v1/${lib}/similar/signatures`, { alg: "vs1", items });
      expect(res.status, JSON.stringify(items).slice(0, 120)).toBe(400);
    }
    // 壊れた 1 件と一緒に送った正しい物も置かない
    expect((await shardItems(lib, key))[key]).toBeUndefined();

    const stale = await ok<SigResult>(
      post(e, `/v1/${lib}/similar/signatures`, {
        alg: "vs1",
        items: [
          { ...good, etag: '"0000"' },
          { ...good, key: "sq/bad/none.png" },
        ],
      }),
    );
    expect(stale).toEqual({ stored: 0, stale: 2, failRecorded: 0 });
    expect((await shardItems(lib, key))[key]).toBeUndefined();
  });

  it("元の寸法は原本の先頭を読んで取る。読んだ物の etag が違えば置かない", async () => {
    const png = "sq/dims/a.png";
    const jpg = "sq/dims/b.jpg";
    const junk = "sq/dims/c.jpg";
    await put(png, pngBytes(640, 480, 6));
    await put(jpg, jpegBytes(300, 200, 7));
    await put(
      junk,
      pngBytes(10, 10, 8).map((v, i) => (i < 8 ? 0 : v)),
    );
    expect((await sign(e, lib, [[png, sig]], "o")).stored).toBe(1);
    expect((await sign(e, lib, [[jpg, sig]])).stored).toBe(1);
    expect((await sign(e, lib, [[junk, sig]])).stored).toBe(1);
    const at = async (k: string) => (await shardItems(lib, k))[k]!;
    expect(await at(png)).toEqual([(await bucket().head(png))!.etag, sig, "o", 640, 480]);
    expect((await at(jpg)).slice(2)).toEqual(["t", 300, 200]);
    expect((await at(junk)).slice(2)).toEqual(["t", 0, 0]);

    // 一覧を作った後に中身が入れ替わった（先頭を読んだ物の etag が違う）
    const swapped = "sq/dims/d.png";
    await put(swapped, pngBytes(50, 50, 9));
    const realGet = bucket().get.bind(bucket());
    const racing = libEnv(lib, {
      over: {
        get: ((k: string, o?: R2GetOptions) =>
          realGet(k === swapped ? png : k, o)) as unknown as R2Bucket["get"],
      },
    });
    expect(await sign(racing, lib, [[swapped, sig]])).toEqual({
      stored: 0,
      stale: 1,
      failRecorded: 0,
    });
    expect((await shardItems(lib, swapped))[swapped]).toBeUndefined();
  });

  it("同じ置き場へ同時に送っても、全部残る", async () => {
    const keys = keysInShard("sq/race/", 4);
    for (const [i, k] of keys.entries()) await put(k, pngBytes(10, 10, 20 + i));
    const res = await Promise.all(keys.map((k) => sign(e, lib, [[k, sig]])));
    expect(res.map((r) => r.stored)).toEqual([1, 1, 1, 1]);
    const items = await shardItems(lib, keys[0]!);
    for (const k of keys) expect(items[k]?.[1], k).toBe(sig);
  });

  it("書く時に、一覧に無い・etag の合わない記録を落とす", async () => {
    const [gone, changed, fresh] = keysInShard("sq/prune/", 3);
    for (const [i, k] of [gone!, changed!, fresh!].entries())
      await put(k, pngBytes(10, 10, 30 + i));
    expect((await sign(e, lib, [[gone!, sig]])).stored).toBe(1);
    expect((await sign(e, lib, [[changed!, sig]])).stored).toBe(1);
    expect(Object.keys(await shardItems(lib, gone!))).toEqual(
      expect.arrayContaining([gone, changed]),
    );
    await bucket().delete(gone!);
    await put(changed!, pngBytes(10, 10, 40));
    expect((await sign(e, lib, [[fresh!, sig]])).stored).toBe(1);
    const items = await shardItems(lib, fresh!);
    expect(items[fresh!]).toBeDefined();
    expect(items[gone!]).toBeUndefined();
    expect(items[changed!]).toBeUndefined();
  });

  it("読み取り専用のライブラリでも署名を受け付ける（書くのは META だけ）", async () => {
    const key = "simro/sig/a.png";
    await env.LIB_B.put(key, pngBytes(30, 20, 50));
    const etag = (await env.LIB_B.head(key))!.etag;
    const r = await ok<SigResult>(
      post(env as Env, "/v1/b/similar/signatures", {
        alg: "vs1",
        items: [{ key, etag, src: "t", sig }],
      }),
    );
    expect(r).toEqual({ stored: 1, stale: 0, failRecorded: 0 });
    expect((await shardItems("b", key))[key]).toEqual([etag, sig, "t", 30, 20]);
    expect((await call(env as Env, "/v1/b/similar/status")).status).toBe(200);
  });
});

/* ---------------- status ---------------- */

describe("照合の進み具合", () => {
  const lib = "ss";
  const e = libEnv(lib);

  it("画像だけを数え、残りの通信量はサムネの有無で見積もる", async () => {
    const withThumb = ["ss/t1.png", "ss/t2.png", "ss/t3.jpg"];
    for (const [i, k] of withThumb.entries()) {
      await put(k, pngBytes(10, 10, i, 30));
      await env.META.put(`.system/thumbs/${lib}/${k}.webp`, new Uint8Array([1, 2, 3]));
    }
    await put("ss/n1.png", pngBytes(10, 10, 10, 40));
    await put("ss/n2.png", pngBytes(10, 10, 11, 50));
    await put("ss/clip.mp4", pngBytes(10, 10, 12, 60));

    expect(await status(e, lib)).toEqual({
      alg: "vs1",
      params: "p1",
      images: 5,
      signed: 0,
      failed: 0,
      flat: 0,
      pending: 5,
      pendingWithThumb: 3,
      pendingNoThumb: 2,
      pendingBytesEstimate: 3 * 40960 + 90,
      sigBatch: 200,
      trashBatch: 40,
    });
    // env で下げた件数をアプリに伝える（アプリは固定の上限ではなくこれで分けて送る）
    const lowered = { ...e, SIMILAR_SIG_BATCH: "50", SIMILAR_TRASH_BATCH: "10" } as Env;
    expect(await status(lowered, lib)).toMatchObject({ sigBatch: 50, trashBatch: 10 });

    await sign(e, lib, [
      ["ss/t1.png", sigOf(look(200))],
      ["ss/n1.png", sigOf(look(201), { flags: 1 })],
    ]);
    await ok(
      post(e, `/v1/${lib}/similar/signatures`, {
        alg: "vs1",
        items: [
          { key: "ss/t2.png", etag: (await bucket().head("ss/t2.png"))!.etag, fail: "decode" },
        ],
      }),
    );
    expect(await status(e, lib)).toMatchObject({
      images: 5,
      signed: 2,
      flat: 1,
      failed: 1,
      pending: 2,
      pendingWithThumb: 1,
      pendingNoThumb: 1,
      pendingBytesEstimate: 40960 + 50,
    });
  });
});

/* ---------------- 束の一覧 ---------------- */

describe("重複と似ている写真の束", () => {
  const lib = "sg";
  const e = libEnv(lib);
  const L1 = look(1);
  const L2 = look(2);
  const L3 = look(3);
  const members2 = Array.from({ length: 61 }, (_, i) => `sg/g2/m${String(i).padStart(2, "0")}.png`);

  beforeAll(async () => {
    // g1: 残す物（大きい PNG）と、同じファイル・ほぼ同じ・差分かも・反転・似ている
    const keep = pngBytes(2000, 1500, 1, 60);
    await put("sg/g1/a-keep.png", keep);
    await put("sg/g1/b-copy.png", keep);
    await put("sg/g1/c-same.jpg", jpegBytes(1000, 750, 3));
    await put("sg/g1/d-variant.png", pngBytes(2000, 1500, 4, 50));
    await put("sg/g1/e-mirror.png", pngBytes(1000, 750, 5, 45));
    await put("sg/g1/f-similar.png", pngBytes(1000, 750, 6, 46));
    // g2: 62 枚の束（1 束で返すのは 60 枚まで）
    await put("sg/g2/k.png", pngBytes(1200, 900, 7, 60));
    for (const [i, k] of members2.entries()) await put(k, pngBytes(600, 450, 100 + i, 40));
    // g3: 小さい束
    await put("sg/g3/k.png", pngBytes(800, 600, 8, 60));
    await put("sg/g3/s.png", pngBytes(400, 300, 9, 40));
    // g4: 同じ中身の動画（見た目の署名は持たない）
    await put("sg/g4/v1.mp4", pngBytes(1, 1, 10, 30));
    await put("sg/g4/v2.mp4", pngBytes(1, 1, 10, 30));
    // g5: 単色・まだ照合していない・読めなかった
    await put("sg/g5/flat.png", pngBytes(100, 100, 11, 33));
    await put("sg/g5/pending.png", pngBytes(100, 100, 12, 34));
    await put("sg/g5/failed.png", pngBytes(100, 100, 13, 35));

    await sign(e, lib, [
      ["sg/g1/a-keep.png", sigOf(L1)],
      ["sg/g1/b-copy.png", sigOf(L1)],
      ["sg/g1/c-same.jpg", sigOf(L1)],
      ["sg/g1/d-variant.png", sigOf(tweakOf(L1))],
      ["sg/g1/e-mirror.png", sigOf(mirrorOf(L1))],
      ["sg/g1/f-similar.png", sigOf(similarOf(L1))],
      ["sg/g2/k.png", sigOf(L2)],
      ...members2.map((k): [string, string] => [k, sigOf(L2)]),
      ["sg/g3/k.png", sigOf(L3)],
      ["sg/g3/s.png", sigOf(L3)],
      ["sg/g5/flat.png", sigOf(look(4), { flags: 1 })],
    ]);
    await ok(
      post(e, `/v1/${lib}/similar/signatures`, {
        alg: "vs1",
        items: [
          {
            key: "sg/g5/failed.png",
            etag: (await bucket().head("sg/g5/failed.png"))!.etag,
            fail: "decode",
          },
        ],
      }),
    );
    await scanHashes(e, lib);
  });

  it("重複の束: 残す物・同じファイル・ほぼ同じ・差分かも・反転に分け、空けられる量の順に並ぶ", async () => {
    const page = await allGroups(e, lib, "dup");
    expect(page.groups.map((g) => [g.id, g.tier, g.reclaim])).toEqual([
      ["sg/g2/k.png", "dup", 61 * 40],
      // 反転と差分かもは別の絵のことがあるので、空けられる量に数えない
      ["sg/g1/a-keep.png", "dup", 60 + 36],
      ["sg/g3/k.png", "dup", 40],
      ["sg/g4/v1.mp4", "dup", 30],
    ]);
    const g1 = page.groups[1]!;
    expect(shape(g1)).toEqual([
      ["sg/g1/a-keep.png", "keeper", false],
      ["sg/g1/b-copy.png", "identical", false],
      ["sg/g1/c-same.jpg", "same", false],
      ["sg/g1/d-variant.png", "same", true],
      ["sg/g1/e-mirror.png", "mirror", false],
    ]);
    const keeper = g1.items[0]!;
    expect([keeper.ow, keeper.oh, keeper.size]).toEqual([2000, 1500, 60]);
    expect(keeper.url).toMatch(/^https:\/\/example\.test\/m\/sg\//);
    expect(g1.items[2]!.ph).toBe(0);
    expect(g1.items[2]!.dh).toBe(0);
    expect(page.total).toBe(4);
    expect(page.summary).toEqual({
      dup: { groups: 4, items: 61 + 4 + 1 + 1, reclaimable: 61 * 40 + 96 + 40 + 30 },
      similar: { groups: 1, items: 1 },
      crowded: 0,
      coverage: { images: 73, signed: 71, pending: 1, failed: 1, flat: 1 },
      hashPending: 0,
      hashSkipped: 0,
    });
  });

  it("似ている束は別の段に分かれ、同じ残す物の key を id に持つ", async () => {
    const page = await allGroups(e, lib, "similar");
    expect(page.groups.map((g) => [g.id, g.tier])).toEqual([["sg/g1/a-keep.png", "similar"]]);
    expect(shape(page.groups[0]!)).toEqual([
      ["sg/g1/a-keep.png", "keeper", false],
      ["sg/g1/f-similar.png", "similar", false],
    ]);
    expect(page.groups[0]!.reclaim).toBe(46);
  });

  it("1 束で返すのは 60 枚までで、残りの数は more に入る", async () => {
    const page = await ok<SimPage>(call(e, `/v1/${lib}/similar?tab=dup&limit=1`));
    const g2 = page.groups[0]!;
    expect(g2.id).toBe("sg/g2/k.png");
    expect(g2.items.length).toBe(60);
    expect(g2.more).toBe(2);
    expect(g2.items.slice(1).every((i) => i.match === "same" && !i.variant)).toBe(true);
  });

  it("カーソルで 1 束ずつたどっても、まとめて取った時と同じ並び", async () => {
    const one = await allGroups(e, lib, "dup", 1);
    const all = await allGroups(e, lib, "dup", 100);
    expect(one.groups.map((g) => g.id)).toEqual(all.groups.map((g) => g.id));
    const first = await ok<SimPage>(call(e, `/v1/${lib}/similar?tab=dup`));
    expect(first.groups.length).toBe(4);
    expect(first.cursor).toBeNull();
  });

  it("同じ中身の束（/duplicates）は、全部が重複の段に残す物と同じファイルとして出る", async () => {
    const dups: { items: { key: string }[] }[] = [];
    let cursor: string | null = null;
    do {
      const page: { groups: { items: { key: string }[] }[]; cursor: string | null } = await ok(
        call(e, `/v1/${lib}/duplicates${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`),
      );
      dups.push(...page.groups);
      cursor = page.cursor;
    } while (cursor);
    expect(dups.length).toBe(2);
    const sim = await allGroups(e, lib, "dup");
    for (const d of dups) {
      const keys = d.items.map((i) => i.key);
      const g = sim.groups.find((x) => x.items.some((i) => i.key === keys[0]));
      expect(g, keys.join()).toBeDefined();
      const labels = keys.map((k) => g!.items.find((i) => i.key === k)?.match).sort();
      expect(labels).toEqual(["identical", "keeper"]);
    }
  });

  it("動画は同じ中身の束にだけ出て、似ている段には出ない", async () => {
    const dup = await allGroups(e, lib, "dup");
    const videos = dup.groups.filter((g) => g.items.some((i) => i.key.endsWith(".mp4")));
    expect(videos.map(shape)).toEqual([
      [
        ["sg/g4/v1.mp4", "keeper", false],
        ["sg/g4/v2.mp4", "identical", false],
      ],
    ]);
    expect(videos[0]!.items[0]!.ow).toBeUndefined();
    const sim = await allGroups(e, lib, "similar");
    expect(sim.groups.flatMap((g) => g.items).some((i) => i.key.endsWith(".mp4"))).toBe(false);
  });

  it("おかしな問い合わせは 400、束ねる数が多すぎれば 413、鍵が無ければ 401、知らないライブラリは 404", async () => {
    expect((await call(e, `/v1/${lib}/similar?tab=all`)).status).toBe(400);
    expect((await call(e, `/v1/${lib}/similar?tab=dup&cursor=xyz`)).status).toBe(400);
    // 上限は配備し直さないと変わらないので、束ねた結果の写しの鍵には入っていない。写しを捨ててから試す
    resetSimilarMemory();
    const tiny = libEnv(lib, { vars: { SIMILAR_MAX_NODES: "3" } });
    const big = await call(tiny, `/v1/${lib}/similar?tab=dup`);
    expect(big.status).toBe(413);
    expect(await big.json()).toEqual({ error: "too_many_for_similar" });
    for (const path of [
      "/v1/a/similar",
      "/v1/a/similar/status",
      "/v1/a/similar/todo?shard=0",
      "/v1/a/similar/relabel",
    ]) {
      const res = await SELF.fetch(`${ORIGIN}${path}`, {
        method: path.endsWith("relabel") ? "POST" : "GET",
      });
      expect(res.status, path).toBe(401);
    }
    const noAuth = await SELF.fetch(`${ORIGIN}/v1/a/similar/signatures`, {
      method: "POST",
      headers: { authorization: "Bearer wrong" },
      body: "{}",
    });
    expect(noAuth.status).toBe(401);
    for (const path of ["/v1/nope/similar", "/v1/nope/similar/status"]) {
      expect((await call(env as Env, path)).status, path).toBe(404);
    }
    expect(
      (await post(env as Env, "/v1/nope/similar/signatures", { alg: "vs1", items: [] })).status,
    ).toBe(404);
  });

  it("残す物を変えると、各員を新しい残す物と比べ直す", async () => {
    interface Labels {
      labels: Record<string, { match: string | null; ph?: number; dh?: number; variant?: boolean }>;
    }
    const r = await ok<Labels>(
      post(e, `/v1/${lib}/similar/relabel`, {
        keep: "sg/g1/d-variant.png",
        keys: [
          "sg/g1/a-keep.png",
          "sg/g1/b-copy.png",
          "sg/g1/c-same.jpg",
          "sg/g1/d-variant.png",
          "sg/g1/e-mirror.png",
          "sg/g1/f-similar.png",
          "sg/g3/k.png",
          "sg/g1/none.png",
        ],
      }),
    );
    const m = (k: string) => r.labels[k];
    // 同じ寸法・同じ形式なのに格子が少し違う → 差分かも
    expect(m("sg/g1/a-keep.png")).toMatchObject({ match: "same", variant: true, ph: 0 });
    expect(m("sg/g1/b-copy.png")).toMatchObject({ match: "same", variant: true });
    expect(m("sg/g1/c-same.jpg")).toMatchObject({ match: "same", variant: false });
    expect(m("sg/g1/d-variant.png")).toEqual({ match: "keeper" });
    expect(m("sg/g1/e-mirror.png")).toMatchObject({ match: "mirror" });
    expect(m("sg/g1/f-similar.png")).toMatchObject({ match: "similar", ph: 6, dh: 6 });
    expect(m("sg/g3/k.png")).toEqual({ match: null });
    expect(m("sg/g1/none.png")).toEqual({ match: null });

    const exact = await ok<Labels>(
      post(e, `/v1/${lib}/similar/relabel`, {
        keep: "sg/g1/b-copy.png",
        keys: ["sg/g1/a-keep.png"],
      }),
    );
    expect(exact.labels["sg/g1/a-keep.png"]).toMatchObject({ match: "identical", variant: false });

    const missing = await post(e, `/v1/${lib}/similar/relabel`, {
      keep: "sg/g1/none.png",
      keys: ["sg/g1/a-keep.png"],
    });
    expect(missing.status).toBe(409);
    expect(await missing.json()).toEqual({ error: "keeper_missing" });
    for (const keys of [[], "x", Array.from({ length: 61 }, (_, i) => `sg/x${i}.png`)]) {
      const res = await post(e, `/v1/${lib}/similar/relabel`, { keep: "sg/g1/a-keep.png", keys });
      expect(res.status).toBe(400);
    }
  });
});

describe("消した後もカーソルがずれない", () => {
  const lib = "sd";
  const e = libEnv(lib);

  it("「この束より後」で続きを探すので、前の束が消えても次の束を飛ばさない", async () => {
    // 空けられる量: A 120 > B 80 > C 40
    const plan: [string, number, number][] = [
      ["A", 3, 11],
      ["B", 2, 12],
      ["C", 1, 13],
    ];
    const list: [string, string][] = [];
    for (const [name, members, seed] of plan) {
      const s = sigOf(look(seed));
      const k = `sd/${name}/k.png`;
      await put(k, pngBytes(1000, 1000, seed, 60));
      list.push([k, s]);
      for (let i = 0; i < members; i++) {
        const m = `sd/${name}/m${i}.png`;
        await put(m, pngBytes(500, 500, seed * 10 + i, 40));
        list.push([m, s]);
      }
    }
    await sign(e, lib, list);
    const first = await ok<SimPage>(call(e, `/v1/${lib}/similar?tab=dup&limit=1`));
    expect(first.groups.map((g) => g.id)).toEqual(["sd/A/k.png"]);
    expect(first.total).toBe(3);
    // 1 ページ目の束を消してから続きを取る。位置の番号で続けると C へ飛んでしまう
    for (let i = 0; i < 3; i++) await bucket().delete(`sd/A/m${i}.png`);
    const next = await ok<SimPage>(
      call(e, `/v1/${lib}/similar?tab=dup&limit=1&cursor=${encodeURIComponent(first.cursor!)}`),
    );
    expect(next.groups.map((g) => g.id)).toEqual(["sd/B/k.png"]);
    expect(next.total).toBe(2);
    const last = await ok<SimPage>(
      call(e, `/v1/${lib}/similar?tab=dup&limit=1&cursor=${encodeURIComponent(next.cursor!)}`),
    );
    expect(last.groups.map((g) => g.id)).toEqual(["sd/C/k.png"]);
    expect(last.cursor).toBeNull();
  });
});

describe("署名の置き場は少しずつ書き直す", () => {
  const lib = "sw";
  // 置き場を読んでから書き終えるまでの間を数える（その間、読み解いた置き場の中身を持っている）
  const open = new Set<string>();
  let most = 0;
  const shardPrefix = `.system/similar/${lib}/`;
  const meta = new Proxy(env.META, {
    get(target, prop) {
      const v = Reflect.get(target, prop) as unknown;
      if (typeof v !== "function") return v;
      if (prop === "get") {
        return async (k: string, ...rest: unknown[]) => {
          if (k.startsWith(shardPrefix)) {
            open.add(k);
            most = Math.max(most, open.size);
          }
          return (v as (...a: unknown[]) => unknown).call(target, k, ...rest);
        };
      }
      if (prop === "put") {
        return async (k: string, ...rest: unknown[]) => {
          try {
            return await (v as (...a: unknown[]) => Promise<unknown>).call(target, k, ...rest);
          } finally {
            open.delete(k);
          }
        };
      }
      return (v as (...a: unknown[]) => unknown).bind(target);
    },
  });
  const e = { ...libEnv(lib), META: meta } as Env;

  it("200 件がほぼ全部の置き場に散っても、同時に持つ置き場は 2 つまで", async () => {
    const keys = Array.from({ length: 200 }, (_, i) => `${lib}/p${i}.png`);
    for (const [i, k] of keys.entries()) await put(k, pngBytes(64, 48, i));
    const touched = new Set(keys.map(shardOf));
    expect(touched.size).toBeGreaterThan(24);
    open.clear();
    most = 0;
    const r = await sign(
      e,
      lib,
      keys.map((k, i) => [k, sigOf(look(i))]),
    );
    expect(r).toEqual({ stored: 200, stale: 0, failRecorded: 0 });
    // 全部を同時に書くと、触れた置き場の数（ほぼ 32）だけ同時に持っていた
    expect(most).toBeGreaterThan(0);
    expect(most).toBeLessThanOrEqual(2);
    for (const k of keys) expect((await shardItems(lib, k))[k]).toBeDefined();
  });
});
