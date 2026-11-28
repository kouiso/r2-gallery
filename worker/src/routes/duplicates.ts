import { journalBestEffort, loadCatalog, rowOf, type CatalogRow } from "../lib/catalog";
import { TRASH_PREFIX } from "../lib/const";
import type { Env } from "../lib/env";
import { readable } from "../lib/env";
import {
  dropHashBestEffort,
  duplicateState,
  ensureHashes,
  hashBudget,
  isSha256Hex,
  loadHashes,
  mutateHashes,
  needsHash,
  recordHashBestEffort,
  sha256OfObject,
  validHash,
  type DuplicateGroup,
} from "../lib/hashes";
import { HttpError, json, readJson } from "../lib/http";
import { moveObject } from "../lib/objects";
import { loadIndex, mediaFor, mutateAlbums } from "../lib/store";

type Ctx = Pick<ExecutionContext, "waitUntil"> | undefined;

const mediaOf = (env: Env, origin: string, lib: string, row: CatalogRow, thumb: boolean) =>
  mediaFor(env, origin, lib, { key: row[0], createdAt: row[2] }, thumb).then((m) => ({
    ...m,
    size: row[1],
  }));

/**
 * POST /v1/:lib/duplicates/scan — サイズが同じ物のうち、まだ中身を計算していない物を
 * 1 回ぶんの予算だけ計算して記録する。pending が 0 になるまで繰り返し呼ぶ。
 */
export async function handleDuplicateScan(env: Env, lib: string, ctx: Ctx): Promise<Response> {
  const { bucket } = readable(env, lib);
  const catalog = await loadCatalog(env, lib, bucket, { ctx });
  const candidates = [...catalog.bySize().values()].flatMap(needsHash);
  const r = await ensureHashes(env, lib, bucket, candidates, hashBudget(env));
  if (r.pending === 0) {
    // 走査が終わった所で、もう無い物・入れ替わった物の記録を落とす（ファイルを太らせない）
    try {
      await mutateHashes(env, lib, (d) => {
        let dropped = false;
        for (const [key, rec] of Object.entries(d.items)) {
          const row = catalog.rows.get(key);
          if (row && row[3] === rec.etag) continue;
          delete d.items[key];
          dropped = true;
        }
        return dropped;
      });
    } catch (e) {
      console.error("hash_prune_failed", lib, e);
    }
  }
  return json({ pending: r.pending, hashed: r.hashed, skipped: r.skipped });
}

const reclaimOf = (g: DuplicateGroup) => (g.rows.length - 1) * g.size;

/** GET /v1/:lib/duplicates — 記録済みのハッシュから重複の束を返す。計算はしない。 */
export async function handleDuplicates(
  env: Env,
  origin: string,
  lib: string,
  url: URL,
  ctx: Ctx,
): Promise<Response> {
  const { bucket } = readable(env, lib);
  const [catalog, hashes] = await Promise.all([
    loadCatalog(env, lib, bucket, { ctx }),
    loadHashes(env, lib),
  ]);
  const state = duplicateState(catalog, hashes, hashBudget(env).maxObjectBytes);
  const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit") ?? "50") || 50));
  // 消すと束が減って番号がずれるので、続きは「この束より後」で探す
  let start = 0;
  const m = /^(\d+)\|([0-9a-f]{64})$/.exec(url.searchParams.get("cursor") ?? "");
  if (m) {
    const reclaim = Number(m[1]);
    const sha = m[2]!;
    start = state.groups.findIndex(
      (g) => reclaimOf(g) < reclaim || (reclaimOf(g) === reclaim && g.sha256 > sha),
    );
    if (start < 0) start = state.groups.length;
  }
  const page = state.groups.slice(start, start + limit);
  const groups = await Promise.all(
    page.map(async (g) => ({
      sha256: g.sha256,
      size: g.size,
      items: await Promise.all(
        g.rows.map((r) => mediaOf(env, origin, lib, r, catalog.hasThumb(r[0]))),
      ),
    })),
  );
  const last = page[page.length - 1];
  return json({
    groups,
    cursor:
      last && start + page.length < state.groups.length
        ? `${reclaimOf(last)}|${last.sha256}`
        : null,
    total: state.groups.length,
    reclaimable: state.groups.reduce((sum, g) => sum + reclaimOf(g), 0),
    pending: state.pending.length,
    skipped: state.skipped,
  });
}

const CHECK_MAX_ITEMS = 1000;
const CHECK_MAX_MATCHES = 5;

/**
 * POST /v1/:lib/objects/check — これから上げる物が保存済みと同じ中身かを答える。
 * サイズだけ送れば「同じサイズの物が何件あるか」だけ返す（端末が全部のハッシュを
 * 計算しなくて済むよう、まずサイズで絞らせる）。sha256 付きなら中身が同じ物を返す。
 */
export async function handleObjectsCheck(
  req: Request,
  env: Env,
  origin: string,
  lib: string,
  ctx: Ctx,
): Promise<Response> {
  const { bucket } = readable(env, lib);
  const body = await readJson(req);
  const raw = body.items;
  if (!Array.isArray(raw) || raw.length > CHECK_MAX_ITEMS) throw new HttpError(400, "bad_items");
  const items = raw.map((v) => {
    const r = v && typeof v === "object" ? (v as Record<string, unknown>) : {};
    const size = Number(r.size);
    if (!Number.isInteger(size) || size < 0) throw new HttpError(400, "bad_items");
    if (r.sha256 !== undefined && !isSha256Hex(r.sha256)) throw new HttpError(400, "bad_items");
    return { size, sha256: r.sha256 as string | undefined };
  });
  const catalog = await loadCatalog(env, lib, bucket, { ctx });
  const bySize = catalog.bySize();
  const candidates = new Map<string, CatalogRow>();
  for (const it of items) {
    if (!it.sha256) continue;
    for (const row of bySize.get(it.size) ?? []) candidates.set(row[0], row);
  }
  const ensured = candidates.size
    ? await ensureHashes(env, lib, bucket, [...candidates.values()], hashBudget(env))
    : { known: new Map<string, string>(), pending: 0, skipped: 0 };
  const results = await Promise.all(
    items.map(async (it) => {
      const same = bySize.get(it.size) ?? [];
      const matches = it.sha256
        ? same.filter((r) => ensured.known.get(r[0]) === it.sha256).slice(0, CHECK_MAX_MATCHES)
        : [];
      return {
        sizeMatches: same.length,
        matches: await Promise.all(
          matches.map((r) => mediaOf(env, origin, lib, r, catalog.hasThumb(r[0]))),
        ),
      };
    }),
  );
  return json({ results, pending: ensured.pending, skipped: ensured.skipped });
}

/** 2 つの中身が同じかを SHA-256 で確かめる。記録が無ければその場で計算する。 */
export async function sameContent(
  env: Env,
  lib: string,
  bucket: R2Bucket,
  a: R2Object,
  b: R2Object,
): Promise<boolean> {
  if (a.size !== b.size) return false;
  if (a.size > hashBudget(env).maxObjectBytes) return false;
  const hashes = await loadHashes(env, lib);
  const shaOf = async (o: R2Object): Promise<string | null> => {
    const have = validHash(hashes, rowOf(o));
    if (have) return have;
    const got = await sha256OfObject(bucket, o.key);
    if (!got || got.etag !== o.etag) return null;
    await recordHashBestEffort(env, lib, o.key, got);
    return got.sha256;
  };
  const [x, y] = await Promise.all([shaOf(a), shaOf(b)]);
  return x !== null && x === y;
}

/**
 * 重複として消す（POST /v1/:lib/ops/trash の duplicateOf 付き）。
 * 消す側が入っていたアルバムは、残す側を同じ位置に入れる。所属の控えは作らない:
 * ゴミ箱から戻した物はライブラリに戻るだけで、アルバムは残す側が持ち続ける。
 */
export async function trashDuplicate(
  env: Env,
  lib: string,
  bucket: R2Bucket,
  key: string,
  keeper: string,
): Promise<Response> {
  if (key === keeper) throw new HttpError(400, "same_key");
  const [target, keep] = await Promise.all([bucket.head(key), bucket.head(keeper)]);
  if (!target) throw new HttpError(404, "source_not_found");
  if (!keep) throw new HttpError(409, "keeper_missing");
  if (!(await sameContent(env, lib, bucket, target, keep))) {
    throw new HttpError(409, "not_duplicate");
  }
  const trashKey = `${TRASH_PREFIX}${Date.now()}/${key}`;
  await moveObject(env, bucket, key, bucket, trashKey);
  const putBack = async () => {
    const back = await moveObject(env, bucket, trashKey, bucket, key);
    // 戻した物は uploaded と etag が変わるので、索引の行も入れ替える
    await journalBestEffort(env, lib, { put: [rowOf(back)] });
  };
  // 2 枚を互いの重複として同時に消すと両方消えてしまう。移した後で残す側を確かめ、
  // 無ければ戻す（少なくとも片方が残る）
  if (!(await bucket.head(keeper))) {
    await putBack();
    throw new HttpError(409, "keeper_missing");
  }
  const id = (k: string) => `${lib}:${k}`;
  try {
    const index = await loadIndex(env, lib);
    const meta = index.items?.find((i) => i.key === keeper);
    await mutateAlbums(env, async (data) => {
      // 書く直前にもう一度、残す側があるかを確かめる。別の操作が残す側を消した後で
      // アルバムを残す側へ書き換えると、ゴミ箱にある物を指してしまう。albums.json は
      // etag の条件付きで書くので、ここで見た後に相手が先に書けば、こちらはやり直しになる
      if (!(await bucket.head(keeper))) throw new HttpError(409, "keeper_missing");
      for (const a of data.albums) {
        const at = a.items.findIndex((i) => i.lib === lib && i.key === key);
        if (at < 0) continue;
        const gone = a.items[at]!;
        const hasKeeper = a.items.some((i) => i.lib === lib && i.key === keeper);
        // この口は控えを作らず、消した物はアルバムへ戻らない。残す側はこのアルバムで消した物の
        // 代わりをずっと務めるので、まとめて消した時の代わりの控えを消して元から居た物と同じ扱いに
        // する（/ops/restore の同じ中身の場合と同じ）。控えを残すと、同じ残す側で先に消した物の
        // 取り消し（/similar/undo）が残す側を外し、ここで消した物の居場所がアルバムから消える
        if (a.keeperFor?.[id(keeper)]) {
          delete a.keeperFor[id(keeper)];
          if (!Object.keys(a.keeperFor).length) delete a.keeperFor;
        }
        if (hasKeeper) {
          a.items.splice(at, 1);
        } else {
          // メモと日時は残す側が空なら消す側のを引き継ぐ。thumb は残す側自身の物だけ使う
          a.items[at] = {
            key: keeper,
            lib,
            ...(meta?.thumb ? { thumb: meta.thumb } : {}),
            note: meta?.note ?? gone.note,
            createdAt: meta?.createdAt ?? gone.createdAt,
          };
        }
        if (a.trashOrder) {
          a.trashOrder = hasKeeper
            ? a.trashOrder.filter((k) => k !== id(key))
            : a.trashOrder.map((k) => (k === id(key) ? id(keeper) : k));
        }
      }
    });
  } catch (e) {
    // アルバムを直せなかったら、消した物を戻して失敗を返す（アルバムが無い物を指したままにしない）
    await putBack();
    throw e;
  }
  // 消すと決まってから索引から外す（途中で戻した時に、戻した物を外したままにしない）
  await journalBestEffort(env, lib, { del: [key] });
  await dropHashBestEffort(env, lib, key);
  return json({ ok: true, trashKey });
}
