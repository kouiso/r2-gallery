import v8 from "node:v8";
import vm from "node:vm";
import { describe, expect, it, vi } from "vitest";
import { loadCatalog } from "../worker/src/lib/catalog.ts";
import { similarLimits } from "../worker/src/lib/env.ts";
import { encodeSig, PARAMS, SIG_BYTES } from "../worker/src/lib/similar/core.ts";
import {
  loadAllShards,
  resetSimilarStoreMemory,
  shardOf,
} from "../worker/src/lib/similar/store.ts";
import { buildModel, resetSimilarMemory } from "../worker/src/routes/similar.ts";

/*
 * GET /similar が既定の上限（SIMILAR_MAX_NODES）ちょうどのライブラリで、一覧・32 の置き場・束ねる途中の物を
 * 持っても Worker の isolate（128 MB）に収まること。上限を 15 万件にしていた時は 10 万件で約 130 MB に届き、
 * 413 で断る前に isolate ごと落ちていた。
 * 一覧と置き場は本物の読み込み（loadCatalog・loadAllShards）で、R2 の代わりに JSON を返す META から読む。
 * Worker のテスト（workerd）では記憶を測れないので、Node の heap と ArrayBuffer の量で測る。
 */

v8.setFlagsFromString("--expose-gc");
const gc = vm.runInNewContext("gc");

const LIB = "mem";
// 他の常駐物（isolate の土台、応答の途中の物、同時に走る別のリクエスト）の分を残す
const BUDGET_MB = 96;

const usedMb = () => {
  gc();
  gc();
  const m = process.memoryUsage();
  return (m.heapUsed + m.arrayBuffers) / 1048576;
};

// buildModel が groupNodes を呼ぶ瞬間の量（その時は節・表・在りかが全部生きている）
let peakMb = 0;
vi.mock(import("../worker/src/lib/similar/core.ts"), async (importOriginal) => {
  const real = await importOriginal();
  return {
    ...real,
    groupNodes: (nodes, table) => {
      peakMb = Math.max(peakMb, usedMb());
      return real.groupNodes(nodes, table);
    },
  };
});

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

/** R2 に置かれた物の代わり。文字列のまま持ち、読むたびに Worker と同じく JSON を読み解かせる */
function fakeLibrary(n) {
  const rnd = mulberry32(n);
  const files = new Map();
  const items = [];
  const shards = Array.from({ length: 32 }, () => ({}));
  const now = Date.now();
  for (let i = 0; i < n; i++) {
    const key = `photos/${2000 + (i % 25)}/${String(i % 500).padStart(4, "0")}/IMG_${i}.jpg`;
    const etag = Math.floor(rnd() * 2 ** 52)
      .toString(16)
      .padStart(14, "0")
      .concat(i.toString(16).padStart(18, "0"));
    items.push([key, 1_000_000 + i, now - i * 1000, etag, 1]);
    const sig = new Uint8Array(SIG_BYTES);
    for (let k = 0; k < 292; k++) sig[k] = Math.floor(rnd() * 256);
    sig.set([2, 0, 1, 128, 0], 292);
    shards[shardOf(key)][key] = [etag, encodeSig(sig), "t", 4032, 3024];
  }
  files.set(`.system/catalog/${LIB}.json`, JSON.stringify({ version: 1, startedAt: now, items }));
  shards.forEach((s, k) => {
    files.set(
      `.system/similar/${LIB}/${String(k).padStart(2, "0")}.json`,
      JSON.stringify({ version: 1, alg: PARAMS.alg, items: s }),
    );
  });
  const body = (key, text) => ({
    key,
    etag: `e-${key}`,
    body: true,
    text: async () => text,
    json: async () => JSON.parse(text),
  });
  const META = {
    get: async (key) => (files.has(key) ? body(key, files.get(key)) : null),
    list: async () => ({ objects: [], truncated: false, delimitedPrefixes: [] }),
  };
  return {
    env: { META, LIBRARIES: JSON.stringify([{ id: LIB, binding: "LIB_MEM", title: LIB }]) },
  };
}

describe("GET /similar の束ねる途中の記憶", () => {
  it("既定の上限ちょうどの節の数でも isolate の上限に収まり、1 件多ければ節を作る前に 413 で断る", async () => {
    const { maxNodes } = similarLimits(
      process.env.MAX_NODES ? { SIMILAR_MAX_NODES: process.env.MAX_NODES } : {},
    );
    const { env } = fakeLibrary(maxNodes);
    resetSimilarMemory();
    const before = usedMb();

    const catalog = await loadCatalog(env, LIB, /* bucket */ {});
    const shards = await loadAllShards(env, LIB);
    const hashes = { version: 1, items: {} };
    const loaded = usedMb() - before;
    // 束ねる途中の山（節・署名の表・有効な署名の在りか）は終わると捨てられるので、
    // 終わった後ではなく途中の量を測る。groupNodes に入る直前が一番多い
    peakMb = 0;
    const model = buildModel(catalog, shards, hashes, 1 << 30, maxNodes);
    const building = peakMb - before;
    // GET /similar は一覧・置き場・束ねた結果を isolate に置いたまま次のリクエストへ使い回す
    const retained = usedMb() - before;
    console.log(
      `similar model at ${maxNodes} nodes: loaded +${Math.round(loaded)} MB, ` +
        `while building +${Math.round(building)} MB, retained +${Math.round(retained)} MB ` +
        `(dup groups ${model.dup.length}, similar groups ${model.similar.length})`,
    );
    expect(catalog.rows.size).toBe(maxNodes);
    expect(shards.reduce((s, x) => s + x.count, 0)).toBe(maxNodes);
    expect(building).toBeGreaterThan(loaded);
    expect(building).toBeLessThan(BUDGET_MB);
    expect(retained).toBeLessThan(BUDGET_MB);

    // 1 件でも上限を超えれば、節と署名の表を作る前に断る
    expect(() => buildModel(catalog, shards, hashes, 1 << 30, maxNodes - 1)).toThrow(
      expect.objectContaining({ status: 413, code: "too_many_for_similar" }),
    );
    resetSimilarStoreMemory();
  }, 120_000);
});
