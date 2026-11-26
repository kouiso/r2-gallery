import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { FLAG_FLAT, extOf, groupNodes, sigInfo } from "../worker/src/lib/similar/core.ts";
import { PROBE_BYTES, probeDims } from "../worker/src/lib/similar/probe.ts";
import {
  DISTINCT_COUNT,
  SET_COUNT,
  alignKeepers,
  assertLocalEndpoint,
  clockSteps,
  expectedOf,
  generateFixture,
  main,
} from "./similar-fixture-seed.mjs";
import {
  IMAGE_RE,
  buildNodes,
  checkExpected,
  signatureFromOriginal,
  signatureOf,
} from "./similar-signatures.mjs";

// 描いて符号化するのが 2 回分あるので、既定の 5 秒では足りない
const SLOW = 120_000;

let fx;
beforeAll(async () => {
  fx = await generateFixture({ seed: 1 });
}, SLOW);

describe("上げた時刻と残す物の期待", () => {
  const fake = {
    files: [{ key: "r/originals/s1.png" }, { key: "r/v/s1-q.jpg" }, { key: "r/x-copies/s1.png" }],
    checks: [
      { key: "r/originals/s1.png", with: "r/originals/s1.png", expect: ["keeper"], set: "s1", role: "base" },
      { key: "r/v/s1-q.jpg", with: "r/originals/s1.png", expect: ["same"], set: "s1", role: "q40" },
      { key: "r/x-copies/s1.png", with: "r/originals/s1.png", expect: ["identical"], set: "s1", role: "copy" },
    ],
  };

  it("時刻が上げた順なら期待はそのまま", () => {
    const t = new Map([
      ["r/originals/s1.png", 10],
      ["r/v/s1-q.jpg", 11],
      ["r/x-copies/s1.png", 12],
    ]);
    const { fx: out, swapped } = alignKeepers(fake, t);
    expect(swapped).toEqual([]);
    expect(out.checks).toEqual(fake.checks);
    expect(clockSteps(fake.files, t)).toEqual({ back: 0, worst: 0 });
  });

  it("時計が戻って写しの方が古くなったら、写しを残す物にして同じ組の期待をそちらへ向ける", () => {
    const t = new Map([
      ["r/originals/s1.png", 1000],
      ["r/v/s1-q.jpg", 400],
      ["r/x-copies/s1.png", 401],
    ]);
    const { fx: out, swapped } = alignKeepers(fake, t);
    expect(swapped).toEqual([{ set: "s1", base: 1000, copy: 401 }]);
    expect(out.checks.map((c) => [c.key, c.with, c.expect])).toEqual([
      ["r/originals/s1.png", "r/x-copies/s1.png", ["identical"]],
      ["r/v/s1-q.jpg", "r/x-copies/s1.png", ["same"]],
      ["r/x-copies/s1.png", "r/x-copies/s1.png", ["keeper"]],
    ]);
    // 元の期待は書き換えない
    expect(fake.checks[0].expect).toEqual(["keeper"]);
    expect(clockSteps(fake.files, t)).toEqual({ back: 2, worst: 600 });
  });
});

const digest = (f) => ({
  key: f.key,
  contentType: f.contentType,
  sha256: f.sha256,
  thumb: f.thumb,
  thumbSha256: f.thumbBytes ? createHash("sha256").update(f.thumbBytes).digest("hex") : null,
});

describe("generateFixture", () => {
  it(
    "is deterministic for the same seed and differs for another seed",
    async () => {
      const again = await generateFixture({ seed: 1 });
      expect(again.files.map(digest)).toEqual(fx.files.map(digest));
      expect(again.albumKeys).toEqual(fx.albumKeys);
      expect(expectedOf(again, { lib: "a" })).toEqual(expectedOf(fx, { lib: "a" }));
      const other = await generateFixture({ seed: 2 });
      expect(other.files.map((f) => f.sha256)).not.toEqual(fx.files.map((f) => f.sha256));
    },
    SLOW,
  );

  it("has the planned shape: sets, variants, distinct, flat and a video pair", () => {
    const roles = fx.files.map((f) => f.role);
    expect(roles.filter((r) => r === "base")).toHaveLength(SET_COUNT);
    for (const r of [
      "copy",
      "q40",
      "half",
      "webp",
      "png",
      "bright",
      "patch40",
      "patch-small",
      "hflip",
      "crop",
    ])
      expect(
        roles.filter((x) => x === r),
        r,
      ).toHaveLength(SET_COUNT);
    expect(roles.filter((r) => r === "distinct")).toHaveLength(DISTINCT_COUNT);
    expect(roles.filter((r) => r === "flat")).toHaveLength(1);
    const videos = fx.files.filter((f) => f.contentType === "video/mp4");
    expect(videos).toHaveLength(2);
    expect(videos[0].sha256).toBe(videos[1].sha256);
    // 写しは元絵と同じバイト列で、元絵より後に上げる（古い方が残す物になる）
    for (const copy of fx.files.filter((f) => f.role === "copy")) {
      const base = fx.files.find((f) => f.set === copy.set && f.role === "base");
      expect(copy.sha256).toBe(base.sha256);
      expect(fx.files.indexOf(copy)).toBeGreaterThan(fx.files.indexOf(base));
    }
    // 中身が同じ物は写しと動画の組だけ（他の別版が偶然一致すると identical の期待が崩れる）
    const bySha = new Map();
    for (const f of fx.files) bySha.set(f.sha256, (bySha.get(f.sha256) ?? 0) + 1);
    expect([...bySha.values()].filter((n) => n > 1)).toHaveLength(SET_COUNT + 1);
    expect(new Set(fx.files.map((f) => f.key)).size).toBe(fx.files.length);
    for (const f of fx.files) expect(f.key.startsWith("similar-e2e/")).toBe(true);
  });

  it("puts JPEG thumbnails on about half of the images and WebP on about a quarter", () => {
    const e = expectedOf(fx, { lib: "a" });
    const { images, thumbJpeg, thumbWebp, thumbNone } = e.counts;
    expect(thumbJpeg + thumbWebp + thumbNone).toBe(images);
    expect(thumbJpeg / images).toBeGreaterThan(0.4);
    expect(thumbJpeg / images).toBeLessThan(0.6);
    expect(thumbWebp / images).toBeGreaterThan(0.18);
    expect(thumbWebp / images).toBeLessThan(0.32);
    expect(thumbNone / images).toBeGreaterThan(0.18);
    // 元絵には必ずサムネがある（Web でも束の基準が変わらないように）
    for (const f of fx.files.filter((x) => x.role === "base")) expect(f.thumb).not.toBeNull();
    for (const f of fx.files.filter((x) => x.thumb === "jpeg"))
      expect(f.thumbBytes.subarray(0, 3).toString("hex")).toBe("ffd8ff");
    for (const f of fx.files.filter((x) => x.thumb === "webp"))
      expect(f.thumbBytes.subarray(8, 12).toString("latin1")).toBe("WEBP");
    expect(fx.files.filter((f) => f.contentType === "video/mp4" && f.thumb)).toHaveLength(0);
  });

  it("keeps the uncompressed base as the largest same-size PNG so it ranks as keeper", () => {
    for (const base of fx.files.filter((f) => f.role === "base")) {
      const otherPngs = fx.files.filter(
        (f) => f.set === base.set && f.key.endsWith(".png") && f.sha256 !== base.sha256,
      );
      expect(otherPngs.length).toBeGreaterThan(0);
      for (const f of otherPngs) expect(f.bytes.length, f.key).toBeLessThan(base.bytes.length);
    }
  });

  it("lists album keys that exist in the fixture", () => {
    const keys = new Set(fx.files.map((f) => f.key));
    expect(fx.albumKeys.length).toBeGreaterThanOrEqual(8);
    for (const k of fx.albumKeys) expect(keys.has(k), k).toBe(true);
    expect(new Set(fx.albumKeys).size).toBe(fx.albumKeys.length);
  });
});

/**
 * Worker と同じ材料で束ねてみる: サムネのある物はそのサムネ、無い物は PC ツールと同じく原本から作った
 * 512px JPEG で署名し、寸法は先頭 64 KB から読む。これで期待ファイルが本当に成り立つかを通信なしで確かめる
 * （しきい値の際に乗る別版があると、手元の E2E でたまにだけ落ちる）。
 */
describe("expected.json against the vs1 core (offline, same inputs as the Worker path)", () => {
  it(
    "every check holds",
    async () => {
      const metas = new Map();
      const sigs = new Map();
      fx.files.forEach((f, i) => {
        const dims = probeDims(new Uint8Array(f.bytes.subarray(0, PROBE_BYTES)));
        metas.set(f.key, {
          key: f.key,
          size: f.bytes.length,
          uploaded: 1_000 + i,
          ow: dims.w,
          oh: dims.h,
          ext: extOf(f.key),
        });
      });
      for (const f of fx.files) {
        if (!IMAGE_RE.test(f.key)) continue;
        sigs.set(
          f.key,
          f.thumbBytes ? await signatureOf(f.thumbBytes) : await signatureFromOriginal(f.bytes),
        );
      }
      const bySha = new Map();
      for (const f of fx.files) bySha.set(f.sha256, [...(bySha.get(f.sha256) ?? []), f.key]);
      const exactGroups = [...bySha.values()].filter((k) => k.length > 1).map((keys) => ({ keys }));
      const { nodes, table } = buildNodes({ metas, sigs, exactGroups });
      const { groups } = groupNodes(nodes, table);
      const serverGroups = groups.map((g) => ({
        id: g.id,
        tier: g.tier,
        items: g.items.map((it) => ({
          key: it.member.key,
          match: it.match,
          variant: it.variant,
          ph: it.ph,
          dh: it.dh,
          gMax: it.gMax,
        })),
      }));
      const flat = [...sigs.values()].filter((s) => sigInfo(s).flags & FLAG_FLAT).length;
      const expected = expectedOf(fx, { lib: "a" });
      expect(checkExpected(expected, serverGroups, { pending: 0, flat })).toEqual([]);
      expect(flat).toBe(expected.flatAtLeast);
    },
    SLOW,
  );
});

describe("endpoint guard", () => {
  it("accepts only 127.0.0.1 and localhost", () => {
    expect(assertLocalEndpoint("http://127.0.0.1:8787")).toBe("http://127.0.0.1:8787");
    expect(assertLocalEndpoint("http://localhost:8787/")).toBe("http://localhost:8787");
    for (const bad of [
      "https://example.com",
      "http://127.0.0.1.example.com:8787",
      "http://localhost.example.com",
      "http://example.com#@127.0.0.1",
      "http://user:pw@127.0.0.1:8787",
      "http://10.0.2.2:8787",
      "http://[::1]:8787",
      "ftp://127.0.0.1",
      "127.0.0.1:8787",
      "",
      undefined,
    ])
      expect(() => assertLocalEndpoint(bad), String(bad)).toThrow();
  });

  describe("main", () => {
    let root;
    beforeAll(() => {
      root = mkdtempSync(join(tmpdir(), "similar-seed-test-"));
    });
    afterAll(() => rmSync(root, { recursive: true, force: true }));

    const quiet = (calls) => ({
      root,
      env: {},
      fetchImpl: async (...a) => {
        calls.push(a);
        throw new Error("must not be called");
      },
      log: () => {},
      warn: (m) => calls.warnings.push(m),
    });

    it("refuses a remote endpoint before any request and never echoes the token", async () => {
      const calls = [];
      calls.warnings = [];
      const code = await main(
        ["--endpoint", "https://notes-sync.example.workers.dev", "--token", "secret-token-xyz"],
        quiet(calls),
      );
      expect(code).toBe(1);
      expect(calls).toHaveLength(0);
      expect(calls.warnings.join("\n")).not.toContain("secret-token-xyz");
    });

    it("refuses a remote R2G_ENDPOINT from the environment too", async () => {
      const calls = [];
      calls.warnings = [];
      const code = await main([], {
        ...quiet(calls),
        env: { R2G_ENDPOINT: "https://example.com", R2G_TOKEN: "t" },
      });
      expect(code).toBe(1);
      expect(calls).toHaveLength(0);
    });

    it("refuses an --out outside .work/", async () => {
      const calls = [];
      calls.warnings = [];
      const code = await main(
        ["--endpoint", "http://127.0.0.1:1", "--token", "t", "--out", "../expected.json"],
        quiet(calls),
      );
      expect(code).toBe(1);
      expect(calls).toHaveLength(0);
    });

    it(
      "stops when the library already holds fixture objects",
      async () => {
        const calls = [];
        const code = await main(["--endpoint", "http://127.0.0.1:1", "--token", "t"], {
          root,
          env: {},
          fetchImpl: async (url, init) => {
            calls.push([String(url), init.method]);
            return new Response(JSON.stringify({ items: [{ key: "similar-e2e/x.png" }] }), {
              status: 200,
              headers: { "content-type": "application/json" },
            });
          },
          log: () => {},
          warn: () => {},
        });
        expect(code).toBe(1);
        expect(calls).toHaveLength(1);
        expect(calls[0][1]).toBe("GET");
        expect(calls[0][0]).toMatch(/^http:\/\/127\.0\.0\.1:1\/v1\/a\/folders\?/);
      },
      SLOW,
    );

    it("does not write expected.json when seeding fails", () => {
      expect(() => readFileSync(join(root, ".work", "similar-e2e", "expected.json"))).toThrow();
    });
  });
});
