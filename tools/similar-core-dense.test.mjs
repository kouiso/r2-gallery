import { describe, expect, it } from "vitest";
import { PARAMS, groupNodes, newSigTable } from "../worker/src/lib/similar/core.ts";

/*
 * 見た目が近い物が数千枚かたまったライブラリ（書類のスキャン、同じアプリの画面写真、連写）で、
 * 束ねる作業と記憶が節の数に比例すること。全部の組を先に作ると、かたまりの大きさの 2 乗になり、
 * 4000 枚で 800 万組・1 GB を超えて Worker の上限（128 MB）に届く。
 * 記憶の山は Node の最大 RSS で測るので、Worker のテスト（workerd）ではなくここに置く。
 */

const RANDOM = 50_000;
const CLUSTER = 3_000;

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

const u32 = (rnd) => Math.floor(rnd() * 4294967296) >>> 0;

/** 64 bit の上下を、ばらばらの k bit だけ反転する */
function flipBits(rnd, hi, lo, k) {
  const done = new Set();
  while (done.size < k) done.add(Math.floor(rnd() * 64));
  for (const b of done) {
    if (b < 32) hi = (hi ^ (1 << b)) >>> 0;
    else lo = (lo ^ (1 << (b - 32))) >>> 0;
  }
  return [hi, lo];
}

function denseLibrary() {
  const rnd = mulberry32(4000);
  const n = RANDOM + CLUSTER;
  const t = newSigTable(n);
  const nodes = [];
  const base = { p: [u32(rnd), u32(rnd)], d: [u32(rnd), u32(rnd)], m: [u32(rnd), u32(rnd)] };
  for (let i = 0; i < n; i++) {
    const inCluster = i >= RANDOM;
    // かたまりの物は 1 枚の基から p/d/m を 3 bit ずつずらし、格子はばらばら（似ているが、ほぼ同じではない）
    const [pHi, pLo] = inCluster ? flipBits(rnd, ...base.p, 3) : [u32(rnd), u32(rnd)];
    const [dHi, dLo] = inCluster ? flipBits(rnd, ...base.d, 3) : [u32(rnd), u32(rnd)];
    const [mHi, mLo] = inCluster ? flipBits(rnd, ...base.m, 3) : [u32(rnd), u32(rnd)];
    t.pHi[i] = pHi;
    t.pLo[i] = pLo;
    t.dHi[i] = dHi;
    t.dLo[i] = dLo;
    t.mHi[i] = mHi;
    t.mLo[i] = mLo;
    for (let k = 0; k < 256; k++) t.grid[i * 256 + k] = Math.floor(rnd() * 256);
    for (let k = 0; k < 12; k++) t.color[i * 12 + k] = inCluster ? 100 : Math.floor(rnd() * 256);
    t.w[i] = 512;
    t.h[i] = 384;
    nodes.push({
      members: [
        {
          key: `${inCluster ? "c" : "r"}/${i}.jpg`,
          size: Math.floor(rnd() * 1e7),
          uploaded: 1,
          ow: 0,
          oh: 0,
          ext: "jpg",
        },
      ],
      sig: i,
    });
  }
  return { t, nodes };
}

describe("groupNodes on a dense cluster", () => {
  it(
    `groups ${CLUSTER} mutually-near images inside ${RANDOM} in bounded time and memory`,
    () => {
      const { t, nodes } = denseLibrary();
      const rssBefore = process.resourceUsage().maxRSS * 1024;
      const started = performance.now();
      const { groups, crowded } = groupNodes(nodes, t);
      const ms = performance.now() - started;
      const grownMb = (process.resourceUsage().maxRSS * 1024 - rssBefore) / 1024 / 1024;
      console.log(
        `dense groupNodes: ${nodes.length} nodes, ${groups.length} groups, crowded ${crowded}, ` +
          `${Math.round(ms)} ms, peak RSS +${Math.round(grownMb)} MB`,
      );

      expect(ms).toBeLessThan(5000);
      // 全部の組を持つ作りでは、ここで 600 MB 以上増えていた
      expect(grownMb).toBeLessThan(120);
      // かたまりの物は互いに「似ている」。上限で切っても、どの 1 枚もどこかの組に入る
      const grouped = new Set(groups.flatMap((g) => g.items.map((i) => i.member.key)));
      const cluster = nodes.filter((nd) => nd.members[0].key.startsWith("c/"));
      expect(cluster.filter((nd) => !grouped.has(nd.members[0].key))).toEqual([]);
      expect(crowded).toBeGreaterThan(0);
      for (const g of groups) {
        expect(g.items.length).toBeLessThanOrEqual(2 * PARAMS.maxNeighbours + 1);
      }
    },
    60_000,
  );
});
