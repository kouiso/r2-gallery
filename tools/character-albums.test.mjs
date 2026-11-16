import sharp from "sharp";
import { describe as suite, expect, it } from "vitest";
import {
  DEFAULT_PARAMS,
  applyPlan,
  buildPlan,
  classify,
  clusterUnmatched,
  describe,
  hamming,
} from "./character-albums-core.mjs";

// 上半分＝髪色、下半分＝服の色、という単純なキャラ画像を作る。
async function character(hair, outfit, { noise = 0, seed = 1 } = {}) {
  const w = 96;
  const h = 96;
  const buf = Buffer.alloc(w * h * 3);
  let s = seed;
  const rand = () => ((s = (s * 1103515245 + 12345) % 2147483648) / 2147483648 - 0.5) * noise;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const c = y < h / 2 ? hair : outfit;
      const o = (y * w + x) * 3;
      for (let k = 0; k < 3; k++) buf[o + k] = Math.max(0, Math.min(255, c[k] + rand()));
    }
  }
  return sharp(buf, { raw: { width: w, height: h, channels: 3 } })
    .png()
    .toBuffer();
}

const PINK = [240, 120, 170];
const SILVER = [200, 200, 210];
const BLUE = [40, 80, 220];
const GREEN = [40, 200, 60];
const WHITE = [245, 245, 245];
const BLACK = [20, 20, 20];

async function album(id, title, hair, outfits) {
  const refs = [];
  for (const [n, o] of outfits.entries())
    refs.push(await describe(await character(hair, o, { noise: 20, seed: n + 3 })));
  return { id, title, refs };
}

suite("character-albums", () => {
  it("衣装が変わっても髪色が同じなら同じアルバムに寄せる", async () => {
    const albums = [
      await album("a1", "ピンク", PINK, [WHITE, BLACK, BLUE]),
      await album("a2", "シルバー", SILVER, [BLACK, BLUE, WHITE]),
    ];
    const t = await describe(await character(PINK, BLACK, { noise: 30, seed: 99 }));
    const r = classify(t, albums);
    expect(r.decision).toBe("match");
    expect(r.albumTitle).toBe("ピンク");
    expect(r.rationale).toMatch(/ピンク/);
  });

  it("どのアルバムにも近くない画像は未分類にする", async () => {
    const albums = [await album("a1", "ピンク", PINK, [WHITE, WHITE, WHITE])];
    const t = await describe(await character(GREEN, BLUE, { seed: 7 }));
    expect(classify(t, albums).decision).toBe("unmatched");
  });

  it("2 つのアルバムに同じくらい近い画像は要確認に回す", async () => {
    const same = [WHITE, WHITE, WHITE];
    const albums = [await album("a1", "A", PINK, same), await album("a2", "B", PINK, same)];
    const t = await describe(await character(PINK, WHITE, { noise: 20, seed: 50 }));
    const r = classify(t, albums);
    expect(r.decision).toBe("review");
    expect(r.rationale).toMatch(/複数人|似た別キャラ/);
  });

  it("dHash は同じ画像で 0、違う画像で大きい", async () => {
    const a = await describe(await character(PINK, WHITE));
    const b = await describe(await character(PINK, WHITE));
    const c = await describe(await character(PINK, WHITE, { noise: 120, seed: 5 }));
    expect(hamming(a.dhash, b.dhash)).toBe(0);
    expect(hamming(a.dhash, c.dhash)).toBeGreaterThan(0);
  });

  it("完全連結なので似た画像の鎖で別キャラまで繋がらない", () => {
    const v = (x) => ({ key: x.join(), desc: { vector: x } });
    const items = [v([1, 0]), v([0.95, 0.312]), v([0.8, 0.6])];
    const groups = clusterUnmatched(items, 0.94);
    expect(groups.length).toBeGreaterThan(1);
  });

  it("配属済みは触らず、未分類同士の塊は仮ラベルの新規アルバム候補にする", async () => {
    const albums = [await album("a1", "ピンク", PINK, [WHITE, BLACK, BLUE])];
    const targets = [
      { key: "p1.png", desc: await describe(await character(PINK, BLUE, { noise: 20, seed: 11 })) },
      { key: "done.png", desc: await describe(await character(PINK, BLUE)) },
      {
        key: "g1.png",
        desc: await describe(await character(GREEN, BLACK, { noise: 10, seed: 1 })),
      },
      {
        key: "g2.png",
        desc: await describe(await character(GREEN, BLACK, { noise: 10, seed: 2 })),
      },
    ];
    const plan = buildPlan({
      lib: "personal",
      targets,
      albums,
      assigned: new Set(["personal:done.png"]),
      params: DEFAULT_PARAMS,
      planId: "run1",
    });
    expect(plan.skipped.map((s) => s.key)).toEqual(["done.png"]);
    const add = plan.groups.find((g) => g.action === "add");
    expect(add.items.map((i) => i.key)).toEqual(["p1.png"]);
    const create = plan.groups.find((g) => g.action === "create");
    expect(create.title).toBe("キャラクターA（仮・run1）");
    expect(create.items.map((i) => i.key).sort()).toEqual(["g1.png", "g2.png"]);
    expect(plan.groups.every((g) => g.approved === false)).toBe(true);
    expect(JSON.stringify(plan)).not.toMatch(/"vector"/);
  });

  function fakeApi(albums) {
    const calls = [];
    const store = new Map(albums.map((a) => [a.id, new Set(a.keys ?? [])]));
    return {
      calls,
      store,
      async listAlbums() {
        return albums;
      },
      async createAlbum(_lib, title) {
        const id = `new-${albums.length}`;
        albums.push({ id, title, readOnly: false });
        store.set(id, new Set());
        calls.push(["create", title]);
        return { id, title };
      },
      async addItems(_lib, id, keys) {
        const set = store.get(id);
        let added = 0;
        for (const k of keys) if (!set.has(k)) (set.add(k), added++);
        calls.push(["add", id, keys.length]);
        return { id, added, count: set.size };
      },
    };
  }

  it("承認したグループだけ反映し、再実行しても二重作成・二重登録しない", async () => {
    const api = fakeApi([{ id: "a1", title: "ピンク", readOnly: false, keys: ["old.png"] }]);
    const plan = {
      version: 1,
      lib: "personal",
      groups: [
        {
          id: "add:a1",
          action: "add",
          albumId: "a1",
          title: "ピンク",
          approved: true,
          items: [{ key: "p1.png" }],
        },
        {
          id: "create:A",
          action: "create",
          title: "キャラクターA（仮）",
          approved: true,
          items: [{ key: "g1.png" }],
        },
        {
          id: "create:B",
          action: "create",
          title: "キャラクターB（仮）",
          approved: false,
          items: [{ key: "x.png" }],
        },
      ],
    };
    const first = await applyPlan(plan, api);
    expect(first.map((r) => r.status)).toEqual(["applied", "applied", "held"]);
    expect([...api.store.get("a1")].sort()).toEqual(["old.png", "p1.png"]);
    const second = await applyPlan(plan, api);
    expect(api.calls.filter((c) => c[0] === "create")).toHaveLength(1);
    expect(second.every((r) => !r.added)).toBe(true);
    expect([...api.store.values()].some((s) => s.has("x.png"))).toBe(false);
  });

  it("別の実行で作った同名の仮アルバムへ、新しいプランの画像を寄せない", async () => {
    // 前の実行が残した「キャラクターA（仮・old-run）」アルバムがある状態。
    // 新しいプランの A も同じ名前ではない（planId が違う）ので、そこへは寄せず新規作成する
    const api = fakeApi([
      { id: "a-old", title: "キャラクターA（仮・old-run）", readOnly: false, keys: [] },
    ]);
    const plan = {
      version: 1,
      lib: "personal",
      planId: "new-run1",
      groups: [
        {
          id: "create:A",
          action: "create",
          title: "キャラクターA（仮・new-run1）",
          approved: true,
          items: [{ key: "g1.png" }],
        },
      ],
    };
    await applyPlan(plan, api);
    expect(api.store.get("a-old").size).toBe(0);
    expect(api.calls.filter((c) => c[0] === "create")).toHaveLength(1);
    // 作った id が plan に書き戻るので、再実行はタイトル照合に頼らず同じ所へ入る
    const again = await applyPlan(plan, api);
    expect(again[0].albumId).toBe(plan.groups[0].appliedAlbumId);
    expect(api.calls.filter((c) => c[0] === "create")).toHaveLength(1);
  });

  it("500 枚を超える束は分けて送る", async () => {
    const api = fakeApi([{ id: "a1", title: "ピンク", readOnly: false, keys: [] }]);
    const keys = Array.from({ length: 1200 }, (_, i) => `k${i}.png`);
    const plan = {
      version: 1,
      lib: "personal",
      groups: [
        {
          id: "add:a1",
          action: "add",
          albumId: "a1",
          title: "ピンク",
          approved: true,
          items: keys.map((key) => ({ key })),
        },
      ],
    };
    const sentSizes = [];
    const orig = api.addItems;
    api.addItems = (lib, id, ks) => {
      sentSizes.push(ks.length);
      return orig(lib, id, ks);
    };
    const r = await applyPlan(plan, api);
    expect(sentSizes).toEqual([500, 500, 200]);
    expect(r[0].added).toBe(1200);
    expect(api.store.get("a1").size).toBe(1200);
  });

  it("読み取り専用アルバムには書かない／dry-run では何も作らない", async () => {
    const api = fakeApi([{ id: "ro", title: "pipeline", readOnly: true }]);
    const plan = {
      version: 1,
      lib: "personal",
      groups: [
        {
          id: "add:ro",
          action: "add",
          albumId: "ro",
          title: "pipeline",
          approved: true,
          items: [{ key: "a.png" }],
        },
        {
          id: "create:A",
          action: "create",
          title: "キャラクターA（仮）",
          approved: true,
          items: [{ key: "b.png" }],
        },
      ],
    };
    const r = await applyPlan(plan, api, { dryRun: true });
    expect(r[0].status).toBe("error");
    expect(r[1].status).toBe("dry-run");
    expect(api.calls).toHaveLength(0);
  });
});

suite("character-albums leave-one-out", () => {
  it("対象自身が参照に入っていても自分とは照合しない", async () => {
    const self = await describe(await character(GREEN, BLACK));
    const albums = [{ id: "a1", title: "緑", refs: [{ key: "t.png", ...self }] }];
    expect(classify(self, albums, DEFAULT_PARAMS, { key: "t.png" }).decision).toBe(
      "unmatched",
    );
    expect(classify(self, albums, DEFAULT_PARAMS).decision).toBe("match");
  });

  it("別ライブラリの同名参照は、対象と同じ名前でも参照から外さない", async () => {
    const self = await describe(await character(GREEN, BLACK));
    const albums = [
      {
        id: "a1",
        title: "緑",
        refs: [
          { key: "t.png", lib: "other-lib", ...self },
          { key: "x.png", lib: "personal", ...self },
        ],
      },
    ];
    // 個人ライブラリの t.png を対象にしても、別ライブラリの同名参照は残る
    const r = classify(
      await describe(await character(GREEN, BLACK)),
      albums,
      DEFAULT_PARAMS,
      { lib: "personal", key: "t.png" },
    );
    expect(r.decision).toBe("match");
  });
});
