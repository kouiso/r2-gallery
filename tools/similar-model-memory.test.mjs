import v8 from "node:v8";
import vm from "node:vm";
import { describe, expect, it } from "vitest";
import { loadCatalog, resetCatalogMemory } from "../worker/src/lib/catalog.ts";
import { similarLimits } from "../worker/src/lib/env.ts";
import { encodeSig, PARAMS, setGroupPeakProbe, SIG_BYTES } from "../worker/src/lib/similar/core.ts";
import {
  loadAllShards,
  loadHashesCached,
  resetSimilarStoreMemory,
  shardOf,
} from "../worker/src/lib/similar/store.ts";
import { buildModel, handleSimilar, resetSimilarMemory } from "../worker/src/routes/similar.ts";

/*
 * GET /similar が既定の上限（SIMILAR_MAX_NODES）ちょうどのライブラリで、一覧・32 の置き場・ハッシュの記録・
 * 束ねる途中の物を持っても Worker の isolate（128 MB）に収まること。
 *
 * 前の版はハッシュの記録を空にし、署名を乱数にして（束が 0 組）、groupNodes に入る瞬間だけを測っていた。
 * 本物のライブラリでは、ハッシュの記録（5 万件で JSON 9 MB、読み解くと 11 MB）を isolate に置き、
 * groupNodes の中で並べ替えの写し・多重索引・輝度の和を作るので、それより約 25 MB 多かった
 * （上限 5 万件で山が約 100 MB、2 つの段を同時に読むと約 145 MB）。
 * ここでは md5 の etag・長めの key・全件のハッシュの記録・3% の同じ中身の写し・30% のほぼ同じ物の塊を
 * 持つライブラリを作り、groupNodes の中の一番重い所（setGroupPeakProbe）で測る。
 * 一覧・置き場・ハッシュの記録は本物の読み込み（loadCatalog・loadAllShards・loadHashesCached）で、
 * R2 の代わりに JSON を返す META から読む。Worker のテスト（workerd）では記憶を測れないので、
 * Node の heap と ArrayBuffer の量で測る（読み込み途中の JSON の文字列は数えていない）。
 */

v8.setFlagsFromString("--expose-gc");
const gc = vm.runInNewContext("gc");

const LIB = "mem";
// 他の常駐物（isolate の土台、読み込み途中の JSON、応答の途中の物、同時に走る別のリクエスト）の分を残す
const BUDGET_MB = 96;

const usedMb = () => {
  gc();
  gc();
  const m = process.memoryUsage();
  return (m.heapUsed + m.arrayBuffers) / 1048576;
};

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const hex = (rnd, n) => {
  let s = "";
  for (let i = 0; i < n; i++) s += Math.floor(rnd() * 16).toString(16);
  return s;
};

/** R2 に置かれた物の代わり。Buffer で持ち、読むたびに Worker と同じく文字列にして読み解かせる */
function fakeLibrary(n, { clusterFrac = 0.3, exactFrac = 0.03 } = {}) {
  const rnd = mulberry32(n + 7);
  const items = [];
  const hashes = {};
  const shards = Array.from({ length: 32 }, () => ({}));
  const now = Date.now();
  let baseSig = null;
  let left = 0;
  let prev = null;
  for (let i = 0; i < n; i++) {
    const ymd = new Date(now - i * 600_000).toISOString().slice(0, 10).replace(/-/g, "");
    const key = `DCIM/Camera/${ymd.slice(0, 4)}/${ymd.slice(4, 6)}/IMG_${ymd}_${String(i).padStart(6, "0")}.jpg`;
    const etag = hex(rnd, 32);
    let size = 1_500_000 + Math.floor(rnd() * 4_000_000);
    let sha = hex(rnd, 64);
    if (prev && rnd() < exactFrac) {
      size = prev.size;
      sha = prev.sha;
    }
    items.push([key, size, now - i * 600_000, etag, 1]);
    hashes[key] = { size, etag, sha256: sha };
    let sig;
    if (left > 0 && baseSig) {
      // 塊の一員: 先頭の物から pHash を 1 ビットだけ変えた物（ほぼ同じ）
      sig = baseSig.slice();
      sig[0] ^= 1 << Math.floor(rnd() * 8);
      left--;
    } else {
      sig = new Uint8Array(SIG_BYTES);
      for (let k = 0; k < 292; k++) sig[k] = Math.floor(rnd() * 256);
      sig.set([15, 192, 11, 208, 0], 292);
      if (rnd() < clusterFrac / 3) {
        baseSig = sig;
        left = 1 + Math.floor(rnd() * 3);
      } else baseSig = null;
    }
    shards[shardOf(key)][key] = [etag, encodeSig(sig), "t", 4032, 3024];
    prev = { size, sha };
  }
  const files = new Map();
  const put = (k, obj) => files.set(k, Buffer.from(JSON.stringify(obj)));
  put(`.system/catalog/${LIB}.json`, { version: 1, startedAt: now, items });
  shards.forEach((s, k) =>
    put(`.system/similar/${LIB}/${String(k).padStart(2, "0")}.json`, {
      version: 1,
      alg: PARAMS.alg,
      items: s,
    }),
  );
  put(`.system/hashes-${LIB}.json`, { version: 1, items: hashes });
  const META = {
    get: async (key, opts) => {
      const buf = files.get(key);
      if (!buf) return null;
      const etag = `e-${key}`;
      if (opts?.onlyIf?.etagDoesNotMatch === etag) return { key, etag };
      return {
        key,
        etag,
        body: true,
        text: async () => buf.toString("utf8"),
        json: async () => JSON.parse(buf.toString("utf8")),
      };
    },
    head: async () => null,
    list: async () => ({ objects: [], truncated: false, delimitedPrefixes: [] }),
  };
  return {
    META,
    LIBRARIES: JSON.stringify([{ id: LIB, binding: "LIB_MEM", title: LIB }]),
    LIB_MEM: {},
    SIGNING_SECRET: "memory-test",
    CATALOG_MAX_AGE_SECONDS: "999999",
    ...(process.env.MAX_NODES ? { SIMILAR_MAX_NODES: process.env.MAX_NODES } : {}),
  };
}

const limits = () =>
  similarLimits(process.env.MAX_NODES ? { SIMILAR_MAX_NODES: process.env.MAX_NODES } : {});

describe("GET /similar の束ねる途中の記憶", () => {
  it("既定の上限ちょうどの画像の数でも、groupNodes の中の山まで isolate の予算に収まる", async () => {
    const { maxNodes } = limits();
    const env = fakeLibrary(maxNodes);
    resetSimilarMemory();
    resetCatalogMemory();
    const before = usedMb();

    const catalog = await loadCatalog(env, LIB, env.LIB_MEM);
    const shards = await loadAllShards(env, LIB);
    const hashes = (await loadHashesCached(env, LIB)).data;
    const loaded = usedMb() - before;
    // 束ねる途中の山（節・署名の表・多重索引・並べ替えの写し）は終わると捨てられるので途中で測る
    let peak = 0;
    setGroupPeakProbe(() => {
      peak = Math.max(peak, usedMb() - before);
    });
    let model;
    try {
      model = buildModel(catalog, shards, hashes, 1 << 30, maxNodes);
    } finally {
      setGroupPeakProbe(null);
    }
    // GET /similar は一覧・置き場・ハッシュの記録・束ねた結果を isolate に置いたまま使い回す
    const retained = usedMb() - before;
    console.log(
      `similar model at ${maxNodes} images: loaded +${Math.round(loaded)} MB, ` +
        `peak in groupNodes +${Math.round(peak)} MB, retained +${Math.round(retained)} MB ` +
        `(dup groups ${model.dup.length}, similar groups ${model.similar.length})`,
    );
    expect(catalog.rows.size).toBe(maxNodes);
    expect(shards.reduce((s, x) => s + x.count, 0)).toBe(maxNodes);
    // 塊とハッシュの記録が本当に効いている（乱数の署名・空の記録で測ると軽く出る）
    expect(model.dup.length).toBeGreaterThan(maxNodes / 20);
    expect(Object.keys(hashes.items).length).toBe(maxNodes);
    expect(peak).toBeGreaterThan(loaded);
    expect(peak).toBeLessThan(BUDGET_MB);
    expect(retained).toBeLessThan(BUDGET_MB);

    // 節の数が上限を超えれば、節と署名の表を作る前に断る
    expect(() => buildModel(catalog, shards, hashes, 1 << 30, Math.floor(maxNodes / 2))).toThrow(
      expect.objectContaining({ status: 413, code: "too_many_for_similar" }),
    );
    resetSimilarStoreMemory();
    resetCatalogMemory();
  }, 180_000);

  it("アプリが 2 つの段を同時に読んでも、読み込みと束ねるのは 1 組だけ", async () => {
    const { maxNodes } = limits();
    const env = fakeLibrary(maxNodes);
    resetSimilarMemory();
    resetCatalogMemory();
    const before = usedMb();
    let peak = 0;
    let builds = 0;
    setGroupPeakProbe(() => {
      builds++;
      peak = Math.max(peak, usedMb() - before);
    });
    let pages;
    try {
      const get = (tab) =>
        handleSimilar(env, "https://example.test", LIB, new URL(`https://x/?tab=${tab}&limit=5`), {
          waitUntil: () => undefined,
        }).then((r) => r.json());
      pages = await Promise.all([get("dup"), get("similar")]);
    } finally {
      setGroupPeakProbe(null);
    }
    console.log(`two concurrent GET /similar at ${maxNodes} images: peak +${Math.round(peak)} MB`);
    // 山の印は 1 回の束ねで 2 回呼ばれる。2 回束ねていれば 4 回になる
    expect(builds).toBe(2);
    expect(pages[0].summary).toEqual(pages[1].summary);
    expect(pages[0].groups.length).toBe(5);
    expect(peak).toBeLessThan(BUDGET_MB);
    resetSimilarMemory();
    resetCatalogMemory();
  }, 180_000);

  it("上限を超えるライブラリは、署名とハッシュの記録を読む前に 413 で断る", async () => {
    const env = { ...fakeLibrary(1200), SIMILAR_MAX_NODES: "1000" };
    resetSimilarMemory();
    resetCatalogMemory();
    const read = [];
    const get = env.META.get;
    env.META.get = (key, opts) => {
      read.push(key);
      return get(key, opts);
    };
    await expect(
      handleSimilar(env, "https://example.test", LIB, new URL("https://x/?tab=dup"), undefined),
    ).rejects.toMatchObject({ status: 413, code: "too_many_for_similar" });
    expect(read.filter((k) => k.includes("/similar/") || k.includes("hashes-"))).toEqual([]);
    resetSimilarMemory();
    resetCatalogMemory();
  }, 60_000);
});
