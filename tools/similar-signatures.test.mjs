import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import sharp from "sharp";
import { afterEach, describe, expect, it } from "vitest";
import {
  FLAG_FLAT,
  FLAG_FROM_ORIGINAL,
  compareSigs,
  decodeSig,
  sigInfo,
} from "../worker/src/lib/similar/core.ts";
import {
  checkExpected,
  main,
  pickSamples,
  reportHtml,
  scoreLabels,
  signatureFromOriginal,
  signatureOf,
  summarize,
} from "./similar-signatures.mjs";

describe("SHA parity in the report", () => {
  const m = (key) => ({ key, size: 10 });
  const it_ = (key, match, variant = false) => ({ member: m(key), match, variant });
  const dup = (id, items) => ({ id, tier: "dup", items });

  it("counts a SHA group as parity only when every copy is selectable by すべての重複", () => {
    const groups = [
      dup("x1", [it_("x1", "keeper"), it_("x2", "identical")]),
      dup("a", [it_("a", "keeper"), it_("y1", "same"), it_("y2", "same")]),
      // 反転・差分かもとして取られた写しは選ばれないので、同じ束に居ても parity ではない
      dup("b", [it_("b", "keeper"), it_("z1", "mirror"), it_("z2", "mirror")]),
      dup("c", [it_("c", "keeper"), it_("w1", "same", true), it_("w2", "same", true)]),
    ];
    const exact = [
      { keys: ["x1", "x2"] },
      { keys: ["y1", "y2"] },
      { keys: ["z1", "z2"] },
      { keys: ["w1", "w2"] },
      { keys: ["v1", "v2"] },
    ];
    expect(summarize(groups, exact).shaParity).toEqual({
      groups: 5,
      together: 2,
      asIdentical: 1,
      absorbed: 1,
      unselectable: 2,
      split: 1,
    });
  });
});

const hex = (b) => Buffer.from(b).toString("hex");

/**
 * worker/src/lib/similar/core.test.ts の GOLDEN_VS1 をそのまま写した物。
 * sharp で PNG に詰めて読み直した画素からも、Worker の基準実装と同じバイト列が出ることを確かめる
 * （ツールの報告が本番の判定と 1 bit もずれないことの裏付け）。
 */
const GOLDEN_HEX = {
  V1:
    "80264b56ad3a755f" +
    "0000000001030204" +
    "d5711f43f84f3106" +
    "050b11171d232a30363c42484f555b610e151b21272d333a40464c52585f656b181e252b31373d434a50565c62686f7522282e353b41474d535a60666c72787f" +
    "2c32383e454b51575d636a70767c8288363c42484e545b61676d737a80868c923f464c52585e646b71777d838a90969c494f565c62686e747b81878d9399a0a3" +
    "53595f666c72787e848b91979da3a99a5d63696f767c82888e949ba1a7ada59c676d73797f868c92989ea4abb1b0a0a670777d83898f969ca2a8aeb4b8a6aab0" +
    "7a80878d93999fa5acb2b8beafaeb4ba848a90979da3a9afb5bcc2bab1b7bec48e949aa0a7adb3b9bfc5c4b5bbc1c7cd989ea4aab0b7bdc3c9cdbbbfc5cbd1d7" +
    "3e3951be39b03eb199beb18d" +
    "00400030" +
    "00",
  V2:
    "83162d740d0ef2fb" +
    "181c6708286328ac" +
    "d6537801585ba76d" +
    "333d696a879cacaf895e5a8e798e97b445505469aeadbd9793606c7f829c9abc62565e51bbcaaa9a8b80648179bfc0ab7a9894b8717a685da79bb4c7a071806c" +
    "919aa4a8697d687a95abb9bda27b7f93acad80989aa2743fc0cac4a7a288802d4a458082a3bba6c9a86e81948b7ca6b1575f6c80c3c4a7bcae5d7769929bacad" +
    "67896966c7e7a1aea46c81717da3de9a837e939bb59a889cb37b917fa296ab879e9cd0ca7273719d9295d3b6bc3d8b82b6b9a2afaa69666097b4c594b2808b52" +
    "517d8a95ab9fb0ca7d5fa0838e80a2bb6c666f8ec59ea9ba9f77945982b5acae888d807cc8b3a9bf85906f6b78b2c1b88b6a8b7de793acbd8b8d4b6b8acdb5ae" +
    "7b93539492839d9486929494" +
    "00250017" +
    "00",
  V3:
    "aaaaaaaaaaaaaaaa" +
    "0000190000191900" +
    "d515555555555555" +
    "1de61de61ee51ee51ee51ee61de61de6976c976c976c976c976c976c976c976cc142c142c142c142c142c142c142c1421de61de61ee51ee51ee51ee61de61de6" +
    "ba49ba49ba49ba49ba49ba49ba49ba499d669d669d669d669d669d669d669d661de61de61ee51ee51ee51ee61de61de6dc27dc27dc26dd26dd27dc27dc27dc27" +
    "7d867d867d867d867d867d867d867d8637cc38cb38cb38cb38cb38cb37cc37cce51ee51ee61de61de61de61ee51ee51e5aa95aa95aa95ba85aa95aa95aa95aa9" +
    "5aa95aa95aa95ba85aa95aa95aa95aa9e51ee51ee61de61de61de61ee51ee51e37cc38cb38cb38cb38cb38cb37cc37cc788b788b788a798a798b788b788b788b" +
    "818181828282818181828282" +
    "0200016a" +
    "00",
  V4:
    "8000000000000000" +
    "0000000000000000" +
    "8000000000000000" +
    "80".repeat(256) +
    "808080808080808080808080" +
    "00640064" +
    "01",
};

function rgbaOf(w, h, f) {
  const b = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) b.set(f(x, y), (y * w + x) * 4);
  return b;
}

// 仕様の golden vectors の表の式そのまま
const VECTORS = {
  V1: () => [
    64,
    48,
    rgbaOf(64, 48, (x, y) => [(4 * x) & 255, (5 * y) & 255, (3 * (x + y)) & 255, 255]),
  ],
  V2: () => [
    37,
    23,
    rgbaOf(37, 23, (x, y) => [
      (x * x + 7 * y) % 256,
      ((13 * x) ^ (29 * y)) & 255,
      (x * y) % 256,
      (x + y) % 3 === 0 ? 128 : 255,
    ]),
  ],
  V3: () => [
    512,
    362,
    rgbaOf(512, 362, (x, y) => {
      const v = (((x >> 5) + (y >> 5)) & 1) === 1 ? 230 : 30;
      const c = v + (x % 7) - 3;
      return [c, c, c, 255];
    }),
  ],
  V4: () => [100, 100, rgbaOf(100, 100, () => [128, 128, 128, 255])],
};

const pngOfRgba = (w, h, rgba) =>
  sharp(rgba, { raw: { width: w, height: h, channels: 4 } })
    .png()
    .toBuffer();

/** 図形とグラデーションだけの絵（実在の中身を使わない）。明るさ +8 で白飛びしないよう 20..235 に収める */
function procedural(w = 512, h = 384) {
  const buf = Buffer.alloc(w * h * 3);
  const shapes = [
    { kind: "circle", cx: 150, cy: 120, r: 70, c: [210, 70, 60] },
    { kind: "rect", x0: 300, y0: 200, x1: 450, y1: 330, c: [40, 150, 200] },
    { kind: "circle", cx: 390, cy: 90, r: 45, c: [230, 210, 80] },
    { kind: "rect", x0: 40, y0: 260, x1: 200, y1: 300, c: [60, 180, 90] },
    { kind: "circle", cx: 250, cy: 300, r: 30, c: [120, 40, 160] },
  ];
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let c = [
        30 + Math.floor((x * 140) / w),
        40 + Math.floor((y * 120) / h),
        80 + Math.floor(((x + y) * 80) / (w + h)),
      ];
      for (const s of shapes) {
        const inside =
          s.kind === "circle"
            ? (x - s.cx) ** 2 + (y - s.cy) ** 2 <= s.r ** 2
            : x >= s.x0 && x < s.x1 && y >= s.y0 && y < s.y1;
        if (inside) c = s.c;
      }
      buf.set(c, (y * w + x) * 3);
    }
  }
  return sharp(buf, { raw: { width: w, height: h, channels: 3 } });
}

const patch = (size, left, top, c) => ({
  input: {
    create: { width: size, height: size, channels: 3, background: { r: c[0], g: c[1], b: c[2] } },
  },
  left,
  top,
});

async function variants() {
  // 元の絵は無圧縮の PNG にして一番大きくする。束ねる時に残す物（大きい順）になるように
  const base = await procedural().png({ compressionLevel: 0 }).toBuffer();
  const from = () => sharp(base);
  return {
    base: { bytes: base, ext: "png" },
    q40: { bytes: await from().jpeg({ quality: 40 }).toBuffer(), ext: "jpg" },
    q90: { bytes: await from().jpeg({ quality: 90 }).toBuffer(), ext: "jpg" },
    resize: { bytes: await from().resize(256).jpeg({ quality: 90 }).toBuffer(), ext: "jpg" },
    webp: { bytes: await from().webp({ quality: 80 }).toBuffer(), ext: "webp" },
    pngToJpeg: { bytes: await from().jpeg({ quality: 85 }).toBuffer(), ext: "jpg" },
    bright: { bytes: await from().linear(1, 8).png().toBuffer(), ext: "png" },
    patch40: {
      bytes: await from()
        // 背景との差が大きすぎると pHash まで 10 を超えて「似ている」にも入らないので、中くらいの灰色にする
        .composite([patch(40, 200, 150, [160, 160, 160])])
        .png()
        .toBuffer(),
      ext: "png",
    },
    smallPatch: {
      bytes: await from()
        .composite([patch(24, 200, 150, [235, 235, 235])])
        .png()
        .toBuffer(),
      ext: "png",
    },
    hflip: { bytes: await from().flop().png().toBuffer(), ext: "png" },
    crop10: {
      bytes: await from().extract({ left: 0, top: 0, width: 461, height: 384 }).png().toBuffer(),
      ext: "png",
    },
  };
}

async function signed(v) {
  const meta = await sharp(v.bytes).metadata();
  return {
    sig: await signatureFromOriginal(v.bytes),
    meta: { ow: meta.width, oh: meta.height, ext: v.ext },
  };
}

describe("vs1 through sharp", () => {
  it("V1-V4 decoded from PNG are byte-identical to the Worker golden vectors", async () => {
    for (const [name, make] of Object.entries(VECTORS)) {
      const [w, h, rgba] = make();
      const sig = await signatureOf(await pngOfRgba(w, h, rgba));
      expect(hex(sig), name).toBe(GOLDEN_HEX[name]);
    }
    expect(sigInfo(Buffer.from(GOLDEN_HEX.V4, "hex")).flags & FLAG_FLAT).toBe(FLAG_FLAT);
  });

  it("applies EXIF orientation before hashing (6 swaps w and h)", async () => {
    const [w, h, rgba] = VECTORS.V1();
    const jpeg = await sharp(rgba, { raw: { width: w, height: h, channels: 4 } })
      .jpeg({ quality: 95 })
      .withMetadata({ orientation: 6 })
      .toBuffer();
    const info = sigInfo(await signatureOf(jpeg));
    expect([info.w, info.h]).toEqual([h, w]);
  });

  it("marks signatures made from originals", async () => {
    const v = await variants();
    const s = await signatureFromOriginal(v.base.bytes);
    expect(sigInfo(s).flags & FLAG_FROM_ORIGINAL).toBe(FLAG_FROM_ORIGINAL);
    expect(sigInfo(await signatureOf(v.base.bytes)).flags & FLAG_FROM_ORIGINAL).toBe(0);
  });

  it("labels sharp variants of a procedural image", async () => {
    const v = await variants();
    const base = await signed(v.base);
    const label = async (name) => {
      const o = await signed(v[name]);
      const r = compareSigs(base.sig, o.sig, base.meta, o.meta);
      return r ? (r.variant ? "variant" : r.label) : null;
    };
    for (const name of ["q40", "q90", "resize", "webp", "pngToJpeg", "bright"])
      expect(await label(name), name).toBe("same");
    expect(await label("patch40")).toBe("similar");
    expect(["variant", "similar"]).toContain(await label("smallPatch"));
    expect(await label("hflip")).toBe("mirror");
    expect(await label("crop10")).not.toBe("same");
  });
});

describe("report HTML and scoring", () => {
  const member = (key, size = 1000) => ({ key, size, uploaded: 1, ow: 0, oh: 0, ext: "png" });
  const groups = [
    {
      id: "a/k.png",
      tier: "dup",
      items: [
        { member: member("a/k.png"), match: "keeper", variant: false },
        {
          member: member("b/<script>x.png"),
          match: "same",
          ph: 1,
          dh: 2,
          mph: 9,
          gMax: 4,
          variant: false,
        },
        {
          member: member("c/m.png"),
          match: "mirror",
          ph: 30,
          dh: 30,
          mph: 1,
          gMax: 3,
          variant: false,
        },
      ],
    },
    {
      id: "a/k.png",
      tier: "similar",
      items: [
        { member: member("a/k.png"), match: "keeper", variant: false },
        {
          member: member("d/s.png"),
          match: "similar",
          ph: 8,
          dh: 9,
          mph: 20,
          gMax: 40,
          variant: false,
        },
      ],
    },
  ];

  it("renders radios, localStorage and the labels export, escaping keys", () => {
    const samples = pickSamples(groups, 1);
    expect(samples.dupGroups).toHaveLength(1);
    expect(samples.sameMembers).toHaveLength(1);
    expect(samples.similarMembers).toHaveLength(1);
    const html = reportHtml({
      lib: "a",
      stats: {
        images: 4,
        signed: { total: 4 },
        flat: 0,
        decodeFailures: 0,
        tiers: {
          dup: { groups: 1, items: 2, reclaimable: 1000 },
          similar: { groups: 1, items: 1, reclaimable: 1000 },
        },
      },
      samples,
      previews: new Map([["a/k.png", "data:image/webp;base64,AAAA"]]),
    });
    for (const s of [
      "同じ絵",
      "差分",
      "別物",
      "localStorage",
      "Export labels.json",
      "labels.json",
      "オリジナル",
    ])
      expect(html).toContain(s);
    expect(html).toContain('type="radio"');
    expect(html).not.toContain("<script>x.png");
    expect(html).toContain("b/&lt;script&gt;x.png");
    // ページに埋める JSON も </script> で閉じられない
    const json = html.slice(
      html.indexOf('id="pairs">') + 11,
      html.indexOf("</script>", html.indexOf('id="pairs">')),
    );
    expect(json).not.toMatch(/</);
    const pairs = Object.values(JSON.parse(json));
    // 同じ組（残す物と一員）が束の見本と一員の見本の両方に出ても、ラベルは 1 つにまとまる
    expect(pairs.filter((p) => p.key === "b/<script>x.png")).toHaveLength(1);
    expect(html).not.toMatch(/https?:\/\//);
  });

  it("scores precision per label and applies the 98% gate to same", () => {
    const l = (key, match, answer, variant = false) => ({
      keeper: "k",
      key,
      match,
      variant,
      answer,
    });
    const labels = [
      ...Array.from({ length: 49 }, (_, i) => l(`s${i}`, "same", "same")),
      l("s49", "same", "diff"),
      l("s49", "same", "same"), // 同じ組の重複は先の答えだけ数える
      l("v1", "same", "diff", true),
      l("v2", "same", "same", true),
      l("m1", "mirror", "same"),
      l("x1", "similar", "diff"),
      l("x2", "similar", "other"),
      l("n1", "similar", undefined),
    ];
    const r = scoreLabels({ version: 1, labels });
    expect(r.categories.same).toMatchObject({ n: 50, same: 49, diff: 1, precision: 0.98 });
    expect(r.gate.pass).toBe(true);
    expect(r.categories.variant).toMatchObject({ n: 2, precision: 0.5 });
    expect(r.categories.mirror.precision).toBe(1);
    expect(r.categories.similar).toMatchObject({ n: 2, precision: 0.5 });
    labels.push(l("s50", "same", "other"));
    expect(scoreLabels(labels).gate.pass).toBe(false);
  });

  it("checks server groups against expected.json", () => {
    const server = [
      {
        id: "k",
        tier: "dup",
        items: [
          { key: "k", match: "keeper" },
          { key: "copy", match: "identical" },
          { key: "q40", match: "same" },
          { key: "patchSame", match: "same", variant: true },
          { key: "flip", match: "mirror" },
        ],
        more: 0,
      },
      {
        id: "k",
        tier: "similar",
        items: [
          { key: "k", match: "keeper" },
          { key: "patch", match: "similar" },
        ],
      },
    ];
    const expected = {
      version: 1,
      flatAtLeast: 1,
      checks: [
        { key: "copy", with: "k", expect: ["identical"] },
        { key: "q40", with: "copy", expect: ["same"] },
        { key: "patchSame", with: "k", expect: ["variant", "similar"] },
        { key: "patch", with: "k", expect: ["similar"] },
        { key: "flip", with: "k", expect: ["mirror"] },
        { key: "crop", with: "k", expect: ["none"] },
        { key: "flat", expect: ["none"] },
        { key: "k", with: "q40", expect: ["keeper", "same"] },
      ],
    };
    expect(checkExpected(expected, server, { pending: 0, flat: 1 })).toEqual([]);
    const bad = checkExpected(
      { ...expected, checks: [{ key: "flip", with: "k", expect: ["same"] }] },
      server,
      { pending: 3, flat: 0 },
    );
    expect(bad).toHaveLength(3);
    expect(bad.join("\n")).toMatch(/pending/);
    expect(bad.join("\n")).toMatch(/flip.*mirror/);
  });
});

// ---------------------------------------------------------------- 通信を偽物に差し替えた通し

const ENDPOINT = "http://127.0.0.1:8787";
// wrangler.test.toml と同じ見るからに試験用の値（秘密の検出に引っかからないよう、乱数らしい文字列にしない）
const TOKEN = "test-access-token-t1";

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Worker の最小の偽物。署名付き URL にトークンが付いて来ないことも見張る */
function fakeWorker(handlers) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    const u = new URL(url);
    const auth = init.headers?.authorization;
    calls.push({
      path: u.pathname,
      search: u.search,
      method: init.method ?? "GET",
      auth,
      body: init.body,
      headers: init.headers,
    });
    if (u.pathname.startsWith("/v1/")) {
      if (auth !== `Bearer ${TOKEN}`) return jsonResponse({ error: "unauthorized" }, 401);
    } else if (auth) {
      throw new Error(`token sent to signed url ${u.pathname}`);
    }
    for (const [re, h] of handlers) {
      const m = re.exec(u.pathname);
      if (m && (h.method ?? "GET") === (init.method ?? "GET")) return h.fn(u, init, m);
    }
    return jsonResponse({ error: "not_found" }, 404);
  };
  return { calls, fetchImpl };
}

const tmpRoots = [];
afterEach(() => {
  for (const d of tmpRoots.splice(0)) rmSync(d, { recursive: true, force: true });
});

function listFiles(dir) {
  return readdirSync(dir, { recursive: true })
    .map((p) => join(dir, String(p)))
    .filter((p) => statSync(p).isFile());
}

describe("report mode end to end (fake Worker)", () => {
  it("groups the library locally, writes only under .work/similar-report/<lib>, never leaks the token", async () => {
    const v = await variants();
    const blobs = new Map();
    const items = [];
    const add = (key, bytes, { thumbStored = true, type = "image", createdAt = 1000 } = {}) => {
      blobs.set(key, bytes);
      items.push({
        key,
        lib: "a",
        type,
        size: bytes.length,
        createdAt,
        thumbStored,
        url: `${ENDPOINT}/m/a/${encodeURIComponent(key)}?e=1&s=sig`,
        thumbUrl: type === "image" ? `${ENDPOINT}/t/a/${encodeURIComponent(key)}?e=1&s=sig` : null,
      });
    };
    add("orig/base.png", v.base.bytes, { createdAt: 1 });
    add("copy/base.png", v.base.bytes, { createdAt: 2 });
    add("v/q40.jpg", v.q40.bytes);
    add("v/webp.webp", v.webp.bytes, { thumbStored: false });
    add("v/patch40.png", v.patch40.bytes);
    add("v/hflip.png", v.hflip.bytes);
    add("v/broken.jpg", Buffer.from("not an image"));
    const flatPng = await sharp({
      create: { width: 64, height: 64, channels: 3, background: "#808080" },
    })
      .png()
      .toBuffer();
    add("v/flat.png", flatPng);
    const video = Buffer.from("same-video-bytes");
    add("clip/a.mp4", video, { type: "video" });
    add("clip/b.mp4", video, { type: "video" });

    const exactGroups = [
      { sha256: "a".repeat(64), size: v.base.bytes.length, items: [items[0], items[1]] },
      { sha256: "b".repeat(64), size: video.length, items: [items[8], items[9]] },
    ];
    const blob = (u, init) => {
      const key = decodeURIComponent(u.pathname.split("/").slice(3).join("/"));
      let b = blobs.get(key);
      if (!b) return jsonResponse({}, 404);
      const m = /^bytes=0-(\d+)$/.exec(init.headers?.range ?? "");
      if (m) b = b.subarray(0, Number(m[1]) + 1);
      return new Response(b, {
        status: m ? 206 : 200,
        headers: { "content-length": String(b.length) },
      });
    };
    const { calls, fetchImpl } = fakeWorker([
      [
        /^\/v1\/a\/folders$/,
        {
          fn: (u) => {
            const start = Number(u.searchParams.get("cursor") ?? 0);
            const page = items.slice(start, start + 4);
            return jsonResponse({
              items: page,
              cursor: start + 4 < items.length ? String(start + 4) : null,
            });
          },
        },
      ],
      [
        /^\/v1\/a\/duplicates$/,
        { fn: () => jsonResponse({ groups: exactGroups, cursor: null, pending: 0, skipped: 0 }) },
      ],
      [/^\/t\/a\//, { fn: blob }],
      [/^\/m\/a\//, { fn: blob }],
    ]);

    const root = mkdtempSync(join(tmpdir(), "similar-report-"));
    tmpRoots.push(root);
    const out = [];
    const code = await main(["report", "--lib", "a", "--include-originals", "--probe-dims"], {
      env: { R2G_ENDPOINT: ENDPOINT, R2G_TOKEN: TOKEN },
      root,
      fetchImpl,
      log: (m) => out.push(m),
      warn: (m) => out.push(m),
    });
    expect(code, out.join("\n")).toBe(0);

    const files = listFiles(root).map((p) => relative(root, p).split("\\").join("/"));
    expect(files.sort()).toEqual([
      ".work/similar-report/a/report.html",
      ".work/similar-report/a/stats.json",
    ]);
    const stats = JSON.parse(readFileSync(join(root, ".work/similar-report/a/stats.json"), "utf8"));
    const html = readFileSync(join(root, ".work/similar-report/a/report.html"), "utf8");
    for (const text of [out.join("\n"), JSON.stringify(stats), html]) {
      expect(text).not.toContain(TOKEN);
      expect(text).not.toContain(ENDPOINT);
      expect(text).not.toContain("s=sig");
    }

    expect(stats).toMatchObject({ images: 8, videos: 2, flat: 1, decodeFailures: 1 });
    expect(stats.signed).toMatchObject({ total: 7, fromThumb: 6, fromOriginal: 1 });
    expect(stats.shaParity).toMatchObject({ groups: 2, together: 2, split: 0 });
    expect(stats.tiers.dup.byMatch.identical.items).toBe(2); // 画像の写しと動画の写し
    expect(stats.tiers.dup.byMatch.same.items).toBe(2); // q40 と WebP
    expect(stats.tiers.dup.byMatch.mirror.items).toBe(1);
    expect(stats.tiers.similar.items).toBe(1);
    // 寸法は原本の先頭 64 KB だけを Range で読み、Worker と同じ probeDims で取る
    expect(stats.probe).toEqual({ known: 7, unknown: 0, failed: 0 });
    const probes = calls.filter((c) => c.path.startsWith("/m/") && c.headers?.range);
    expect(probes.length).toBe(7);
    expect(probes.every((c) => c.headers.range === "bytes=0-65535")).toBe(true);
    expect(stats.bytesDownloaded).toBeGreaterThan(0);
    expect(typeof stats.groupingMs).toBe("number");
    expect(html).toContain("data:image/webp;base64,");

    // 一覧と重複の API にだけトークンを付けている（署名付き URL に付けていれば fakeWorker が落ちる）
    expect(calls.filter((c) => c.path.startsWith("/v1/")).every((c) => c.auth)).toBe(true);
    expect(calls.some((c) => c.method !== "GET")).toBe(false);

    // --purge は出力だけを消す
    expect(await main(["--purge", "--lib", "a"], { root, log: () => {}, warn: () => {} })).toBe(0);
    expect(listFiles(root)).toEqual([]);
    expect(await main(["--purge", "--lib", "../x"], { root, log: () => {}, warn: () => {} })).toBe(
      1,
    );
  }, 60_000);

  it("refuses to run without the environment and does not echo it", async () => {
    const out = [];
    const code = await main(["report", "--lib", "a"], {
      env: { R2G_ENDPOINT: ENDPOINT },
      root: tmpdir(),
      log: (m) => out.push(m),
      warn: (m) => out.push(m),
    });
    expect(code).toBe(1);
    expect(out.join("\n")).not.toContain(ENDPOINT);
  });
});

describe("write mode (fake Worker)", () => {
  async function setup({ conflict = false } = {}) {
    const v = await variants();
    const blobs = new Map([
      ["t/ok.png", v.base.bytes],
      ["o/orig.png", v.q90.bytes],
      ["o/broken.jpg", Buffer.from("garbage")],
    ]);
    const todo = [
      { key: "t/ok.png", etag: "e1", size: 10, ext: "png", thumbStored: true },
      { key: "o/orig.png", etag: "e2", size: 10, ext: "png", thumbStored: false },
      { key: "o/huge.png", etag: "e3", size: 64 * 1024 * 1024, ext: "png", thumbStored: false },
      { key: "o/broken.jpg", etag: "e4", size: 7, ext: "jpg", thumbStored: false },
      { key: "o/gone.png", etag: "e5", size: 10, ext: "png", thumbStored: false },
    ].map((it) => ({
      ...it,
      url: `${ENDPOINT}/m/a/${it.key}?e=1&s=sig`,
      thumbUrl: `${ENDPOINT}/t/a/${it.key}?e=1&s=sig`,
    }));
    const posts = [];
    const blob = (u) => {
      const b = blobs.get(u.pathname.split("/").slice(3).join("/"));
      // 読めない物は通信の失敗として扱い、失敗印を残さない
      return b ? new Response(b) : new Response("x", { status: 404 });
    };
    const worker = fakeWorker([
      [
        /^\/v1\/a\/similar\/status$/,
        {
          fn: () =>
            jsonResponse({
              alg: "vs1",
              params: "p1",
              pending: posts.length ? 1 : 5,
              pendingWithThumb: 1,
              pendingNoThumb: 4,
            }),
        },
      ],
      [
        /^\/v1\/a\/similar\/todo$/,
        {
          fn: (u) => {
            const shard = Number(u.searchParams.get("shard"));
            const after = u.searchParams.get("after");
            if (shard !== 3)
              return jsonResponse({ shard, items: [], next: null, pendingInShard: 0 });
            const start = after ? todo.findIndex((t) => t.key === after) + 1 : 0;
            const page = todo.slice(start, start + 3);
            return jsonResponse({
              shard,
              items: page,
              next: start + 3 < todo.length ? page[page.length - 1].key : null,
              pendingInShard: todo.length - start,
            });
          },
        },
      ],
      [
        /^\/v1\/a\/similar\/signatures$/,
        {
          method: "POST",
          fn: (u, init) => {
            const body = JSON.parse(init.body);
            posts.push(body);
            if (conflict) return jsonResponse({ error: "alg_mismatch" }, 409);
            return jsonResponse({
              stored: body.items.filter((i) => i.sig).length,
              stale: 0,
              failRecorded: body.items.filter((i) => i.fail).length,
            });
          },
        },
      ],
      [/^\/t\/a\//, { fn: blob }],
      [/^\/m\/a\//, { fn: blob }],
    ]);
    return { ...worker, posts };
  }

  it("walks every shard, signs thumbnails and originals, records fail markers, skips network errors", async () => {
    const { posts, calls, fetchImpl } = await setup();
    const out = [];
    const code = await main(["write", "--lib", "a"], {
      env: { R2G_ENDPOINT: ENDPOINT, R2G_TOKEN: TOKEN },
      fetchImpl,
      log: (m) => out.push(m),
      warn: (m) => out.push(m),
    });
    // 通信の失敗が残ったので 2（やり直せば続きから進む）
    expect(code, out.join("\n")).toBe(2);
    expect(out.join("\n")).not.toContain(TOKEN);
    const shards = new Set(
      calls
        .filter((c) => c.path.endsWith("/similar/todo"))
        .map((c) => new URL(ENDPOINT + c.path + c.search).searchParams.get("shard")),
    );
    expect(shards.size).toBe(32);
    // 1 ページ目と 2 ページ目の終わりにそれぞれ送る
    expect(posts).toHaveLength(2);
    const rows = posts.flatMap((p) => p.items);
    expect(posts.every((p) => p.alg === "vs1")).toBe(true);
    const byKey = Object.fromEntries(rows.map((r) => [r.key, r]));
    expect(Object.keys(byKey).sort()).toEqual([
      "o/broken.jpg",
      "o/huge.png",
      "o/orig.png",
      "t/ok.png",
    ]);
    expect(byKey["t/ok.png"]).toMatchObject({ etag: "e1", src: "t" });
    expect(sigInfo(decodeSig(byKey["t/ok.png"].sig)).flags & FLAG_FROM_ORIGINAL).toBe(0);
    expect(byKey["o/orig.png"]).toMatchObject({ etag: "e2", src: "o" });
    expect(sigInfo(decodeSig(byKey["o/orig.png"].sig)).flags & FLAG_FROM_ORIGINAL).toBe(
      FLAG_FROM_ORIGINAL,
    );
    expect(byKey["o/huge.png"]).toEqual({
      key: "o/huge.png",
      etag: "e3",
      src: "o",
      fail: "too_large",
    });
    expect(byKey["o/broken.jpg"]).toMatchObject({ fail: "decode" });
    // 大きすぎる原本は落とさない
    expect(calls.some((c) => c.path.includes("huge"))).toBe(false);
  }, 60_000);

  it("stops on 409 alg_mismatch", async () => {
    const { fetchImpl } = await setup({ conflict: true });
    const out = [];
    const code = await main(["write", "--lib", "a"], {
      env: { R2G_ENDPOINT: ENDPOINT, R2G_TOKEN: TOKEN },
      fetchImpl,
      log: (m) => out.push(m),
      warn: (m) => out.push(m),
    });
    expect(code).toBe(1);
    expect(out.join("\n")).toMatch(/alg_mismatch/);
  }, 60_000);
});

describe("--check-expected against the server (fake Worker)", () => {
  it("pages both tabs and passes when every check holds", async () => {
    const dup = [
      {
        id: "k",
        tier: "dup",
        items: [
          { key: "k", match: "keeper" },
          { key: "copy", match: "identical" },
        ],
        more: 0,
      },
    ];
    const { fetchImpl } = fakeWorker([
      [
        /^\/v1\/a\/similar\/status$/,
        { fn: () => jsonResponse({ alg: "vs1", pending: 0, flat: 2 }) },
      ],
      [
        /^\/v1\/a\/similar$/,
        {
          fn: (u) => {
            const tab = u.searchParams.get("tab");
            if (tab === "similar") return jsonResponse({ groups: [], cursor: null });
            const cursor = u.searchParams.get("cursor");
            return cursor
              ? jsonResponse({
                  groups: [
                    {
                      id: "k2",
                      tier: "dup",
                      items: [
                        { key: "k2", match: "keeper" },
                        { key: "q", match: "same" },
                      ],
                    },
                  ],
                  cursor: null,
                })
              : jsonResponse({ groups: dup, cursor: "c1" });
          },
        },
      ],
    ]);
    const root = mkdtempSync(join(tmpdir(), "similar-check-"));
    tmpRoots.push(root);
    const file = join(root, "expected.json");
    writeFileSync(
      file,
      JSON.stringify({
        version: 1,
        lib: "a",
        flatAtLeast: 2,
        checks: [
          { key: "copy", with: "k", expect: ["identical"] },
          { key: "q", with: "k2", expect: ["same"] },
        ],
      }),
    );
    const env = { R2G_ENDPOINT: ENDPOINT, R2G_TOKEN: TOKEN };
    const out = [];
    expect(
      await main(["--check-expected", file], {
        env,
        fetchImpl,
        log: (m) => out.push(m),
        warn: (m) => out.push(m),
      }),
    ).toBe(0);
    writeFileSync(
      file,
      JSON.stringify({ version: 1, lib: "a", checks: [{ key: "q", with: "k", expect: ["same"] }] }),
    );
    expect(
      await main(["--check-expected", file], { env, fetchImpl, log: () => {}, warn: () => {} }),
    ).toBe(1);
  });
});
