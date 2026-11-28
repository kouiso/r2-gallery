import {
  journalBestEffort,
  loadCatalog,
  rowOf,
  type CatalogRow,
  type JournalEntry,
} from "../lib/catalog";
import { IMAGE_EXT, TRASH_PREFIX } from "../lib/const";
import type { Env } from "../lib/env";
import { similarLimits, writable } from "../lib/env";
import { dropHashesBestEffort, hashBudget, validHash } from "../lib/hashes";
import { assertUserKey, HttpError, json, readJson } from "../lib/http";
import { moveBackFromTrash, moveObject } from "../lib/objects";
import { compareSigs, extOf, type Label, type PairMeta } from "../lib/similar/core";
import { exactRows, exactSide, loadHashesCached, loadShard, shardOf } from "../lib/similar/store";
import type { Shard } from "../lib/similar/store";
import { loadAlbums, loadIndex, mutateAlbums } from "../lib/store";
import type { AlbumsFile, GlobalAlbum, GlobalAlbumItem, IndexItem } from "../lib/store";
import {
  addKeeperDependent,
  dropKeeperDependent,
  foldGhostsIntoOrder,
  insertByTrashOrder,
  makeProbe,
  pruneTrashOrder,
  trashAlbumsPath,
  type TrashAlbumMembership,
} from "../lib/trash-albums";
import { sameContent } from "./duplicates";
import { restoredThumb } from "./write";

/**
 * 重複・似ている写真をまとめてゴミ箱へ送る口と、その直後の取り消し。
 *
 * 1 件ずつの trashDuplicate を数千回呼ぶと、1 件ごとに albums.json を読み書きして互いに
 * 競合し、索引の追記もハッシュの書き直しも件数分走る。ここでは 40 件を 1 回の albums.json の
 * 書き込み・1 回の追記・1 回のハッシュの書き直しで済ませる。
 *
 * 守る事: どの失敗でも物とアルバムの所属を失わない。動かした後で失敗したら元へ戻し、
 * 控え（.system/trash-albums/）を残さない。戻すのにも失敗した物はゴミ箱に控えごと残し、
 * ゴミ箱の画面から戻せるようにする。
 */

type WaitUntil = Pick<ExecutionContext, "waitUntil">;

// 1 本の Worker が同時に開ける接続には上限がある。head は軽いので 6 本、移動は中で
// head・読み・書き・消しを続けて行うので 4 本にする（write.ts・hashes.ts と同じ目安）
const HEAD_PARALLEL = 6;
const MOVE_PARALLEL = 4;
const TRASH_KEY = /^\.trash\/(\d+)\/([\s\S]+)$/;
/** 取り消しでアルバムを書く回数と、2 回目からの待ち（100ms → 200ms） */
const UNDO_ALBUM_TRIES = 3;
const UNDO_ALBUM_BACKOFF_MS = 100;
/** 戻すのに失敗した時に試し直す回数（一時的な失敗でゴミ箱に取り残さない） */
const MOVE_BACK_TRIES = 3;
/**
 * まとめて消す時に albums.json を書く回数の上限。1 回ごとに残す物 40 件を head し直すので、
 * mutateAlbums の 8 回まで競合すると、跡を確かめる分と合わせて 1000 回を超える
 */
const TRASH_ALBUM_ATTEMPTS = 4;
/**
 * まとめて消す時に跡を確かめる外部呼び出しの上限。この口は 40 件で約 500 回を使い、アルバムを書けずに
 * 全部を戻す道でもう約 250 回を使うので、1 件ずつの口より小さくする
 */
const TRASH_PROBE_BUDGET = 80;

const badItems = () => new HttpError(400, "bad_items");
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** 同時に limit 本まで走らせる（Promise.all に全部投げると接続の上限で詰まる） */
async function forEachLimit<T>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<void>,
): Promise<void> {
  let next = 0;
  const worker = async () => {
    while (next < items.length) await fn(items[next++]!);
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
}

/** 控えの書き込み。一時的な失敗で所属の控えを失わないよう、数回試す */
async function putSidecar(env: Env, path: string, m: TrashAlbumMembership[]): Promise<void> {
  for (let attempt = 0; ; attempt++) {
    try {
      await env.META.put(path, JSON.stringify(m), {
        httpMetadata: { contentType: "application/json" },
      });
      return;
    } catch (e) {
      if (attempt >= 2) throw e;
    }
  }
}

async function deleteSidecarBestEffort(env: Env, path: string): Promise<void> {
  try {
    await env.META.delete(path);
  } catch (e) {
    console.error("similar_sidecar_delete_failed", path, e);
  }
}

/* ---------------- まとめてゴミ箱へ ---------------- */

type Phase =
  /** まだ動かしていない（断った物もここに残る） */
  | "idle"
  /** ゴミ箱へ移した */
  | "moved"
  /** 一度移したが元の key へ戻した */
  | "back"
  /** 戻すのにも失敗し、控えごとゴミ箱に残っている */
  | "stuck";

interface TrashItem {
  key: string;
  keep: string;
  trashKey: string;
  phase: Phase;
  error?: string;
  target?: R2Object;
  keeper?: R2Object;
  kind?: Label;
  /** いま META に置いてある控え。空なら控えは無い */
  planned: TrashAlbumMembership[];
}

/**
 * POST /v1/:lib/similar/trash {items:[{key, keep}]} — 重複・似ている物をまとめてゴミ箱へ送り、
 * 入っていたアルバムでは残す側をその位置へ入れる。束の分け方はアプリの言い分を信じず、
 * 1 件ずつ中身（SHA-256）か見た目の署名で残す側と比べ直してから動かす。
 */
export async function handleSimilarTrash(
  req: Request,
  env: Env,
  lib: string,
  ctx?: WaitUntil,
): Promise<Response> {
  const { bucket } = writable(env, lib);
  const body = await readJson(req);
  const raw = body.items;
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > similarLimits(env).trashBatch) {
    throw badItems();
  }
  const now = Date.now();
  const items: TrashItem[] = raw.map((v) => {
    const r = v && typeof v === "object" ? (v as Record<string, unknown>) : {};
    let key: string;
    let keep: string;
    try {
      key = assertUserKey(r.key);
      keep = assertUserKey(r.keep);
    } catch {
      throw badItems();
    }
    return { key, keep, trashKey: `${TRASH_PREFIX}${now}/${key}`, phase: "idle", planned: [] };
  });
  if (new Set(items.map((i) => i.key)).size !== items.length) throw badItems();
  const targeted = new Set(items.map((i) => i.key));
  for (const it of items) {
    if (it.key === it.keep) it.error = "same_key";
    // 同じ回の中で残す側も消すと、互いを残す側にした 2 枚が両方消える
    else if (targeted.has(it.keep)) it.error = "keeper_targeted";
  }
  const open = () => items.filter((i) => !i.error && i.phase === "idle");
  const sidecarOf = (it: TrashItem) => trashAlbumsPath(lib, it.trashKey);

  // 1. 消す物と残す物を確かめる（まだ何も動かしていないので、ここで落ちても失う物は無い）
  const heads = new Map<string, R2Object | null>();
  await forEachLimit(
    [...new Set(open().flatMap((i) => [i.key, i.keep]))],
    HEAD_PARALLEL,
    async (k) => {
      heads.set(k, await bucket.head(k));
    },
  );
  for (const it of open()) {
    it.target = heads.get(it.key) ?? undefined;
    it.keeper = heads.get(it.keep) ?? undefined;
    if (!it.target) it.error = "source_not_found";
    else if (!it.keeper) it.error = "keeper_missing";
  }

  // 2. 種類を決める。中身が同じなら identical、違えば今の中身の署名同士で見た目を比べる
  await classify(env, lib, bucket, open());

  // 3. 外す前に控えを書く。ここで失敗した物は動かさないので、所属は失われない
  const albums = await loadAlbums(env);
  await forEachLimit(open(), HEAD_PARALLEL, async (it) => {
    const planned = membershipsIn(albums, lib, it);
    if (!planned.length) return;
    try {
      await putSidecar(env, sidecarOf(it), planned);
      it.planned = planned;
    } catch (e) {
      console.error("similar_sidecar_failed", lib, it.key, e);
      // 書けたかどうか分からないので消しておく（残ると無い物を「まだ戻せる」と数えてしまう）
      await deleteSidecarBestEffort(env, sidecarOf(it));
      it.error = "sidecar_failed";
    }
  });

  // 4. ゴミ箱へ移す
  await forEachLimit(open(), MOVE_PARALLEL, async (it) => {
    let copied = true;
    try {
      await moveObject(env, bucket, it.key, bucket, it.trashKey);
      it.phase = "moved";
      return;
    } catch (e) {
      console.error("similar_trash_move_failed", lib, it.key, e);
      // 行き先が既に在って写さなかった時だけは、ゴミ箱側の物はこの呼び出しの写しではない
      copied = !(e instanceof HttpError && e.code === "destination_exists");
    }
    // 途中まで進んで投げた時は、実物の場所で決める。元の key に在れば動いていない
    const where = await locate(bucket, it.key, it.trashKey);
    if (where === "trash") {
      it.phase = "moved";
      return;
    }
    if (where === "original" && copied) {
      // 写した後で元を消せなかった。ゴミ箱に残った写しは控えが無く戻せないのに一覧に出るので消す
      // （元の key に同じ物があるので、消しても失う物は無い）
      try {
        await bucket.delete(it.trashKey);
      } catch (e) {
        console.error("similar_trash_leftover_delete_failed", lib, it.trashKey, e);
      }
    }
    it.error = "move_failed";
    // 在り処が分からない時は控えを残す（ゴミ箱に在った場合、戻す時に所属が要る）
    if (where !== "unknown" && it.planned.length) {
      await deleteSidecarBestEffort(env, sidecarOf(it));
      it.planned = [];
    }
  });

  const moved = () => items.filter((i) => i.phase === "moved");
  const backRows: CatalogRow[] = [];
  const putBack = async (list: TrashItem[], error: string) => {
    await forEachLimit(list, MOVE_PARALLEL, async (it) => {
      it.error = error;
      const back = await moveBack(env, bucket, it.trashKey, it.key);
      if (!back) {
        // 控えは残す。アルバムはまだ書き換えていないので、ゴミ箱から戻せば元どおりになる
        it.phase = "stuck";
        console.error("similar_put_back_failed", lib, it.key, it.trashKey);
        return;
      }
      it.phase = "back";
      // 戻した物は uploaded（複数パートなら etag も）が変わるので、索引の行も入れ替える
      backRows.push(rowOf(back));
      if (it.planned.length) await deleteSidecarBestEffort(env, sidecarOf(it));
      it.planned = [];
    });
  };

  let real = new Map<TrashItem, TrashAlbumMembership[]>();
  const gone = new Set<string>();
  let albumsOk = false;
  try {
    // 5. 移した後で残す側を確かめ直す。同じ時に別の操作が残す側を消していたら戻す
    //    （互いを残す側にして同時に消しても、少なくとも片方が残る）
    await checkKeepers(bucket, moved(), gone);
    await putBack(
      moved().filter((i) => gone.has(i.keep)),
      "keeper_missing",
    );

    // 6. アルバムは 1 回だけ書く
    const keeperKeys = new Set(moved().map((i) => i.keep));
    const index = await loadIndex(env, lib);
    const meta = new Map(
      (index.items ?? []).filter((i) => keeperKeys.has(i.key)).map((i) => [i.key, i]),
    );
    const probe = makeProbe(env, TRASH_PROBE_BUDGET);
    let attempt = 0;
    await mutateAlbums(env, async (data) => {
      // この回で書く中身だけを持つ（途中で投げた回の分を、書けた物と取り違えない）
      real = new Map();
      // やり直すたびに残す物を確かめ直すので、競合が続くと 1 リクエストの外部呼び出しの上限に届く。
      // 数回で諦めて全部を元へ戻す（アプリは albums_failed の物を一覧に戻し、もう一度選べる）
      if (attempt >= TRASH_ALBUM_ATTEMPTS) throw new HttpError(503, "albums_contended");
      if (attempt++) probe.reset();
      // 書く直前にもう一度、残す側があるかを確かめる。別の操作が残す側を消した後で
      // アルバムを残す側へ書き換えると、ゴミ箱にある物を指してしまう。albums.json は
      // etag の条件付きで書くので、ここで見た後に相手が先に書けば、こちらはやり直しになる。
      // 一度無いと分かった残す側は、やり直しでも無いものとして扱う（戻すと決めた物を動かさない）
      await checkKeepers(bucket, moved(), gone);
      real = handOver(
        data,
        lib,
        moved().filter((i) => !gone.has(i.keep)),
        meta,
      );
      for (const a of data.albums) if (touchedAlbum(a, real)) await pruneTrashOrder(probe, a);
    });
    albumsOk = true;
  } catch (e) {
    console.error("similar_trash_albums_failed", lib, e);
    // 書き込みは届いたのに応答で投げた時に、ファイルだけ戻すとアルバムから外れたままになる。
    // 今の albums.json がこの回の書き換えどおりなら、書けたものとして進める
    albumsOk = await albumsLanded(env, lib, real);
  }
  if (albumsOk) {
    await putBack(
      moved().filter((i) => gone.has(i.keep)),
      "keeper_missing",
    );
  } else {
    // アルバムを直せなかったら、移した物を全部戻して失敗を返す（アルバムが無い物を指したままにしない）
    real = new Map();
    await putBack(moved(), "albums_failed");
  }

  // 7. 控えを書いてから所属が増減していたら（並行操作）、実際に書き換えた分で書き直す
  await forEachLimit([...real], HEAD_PARALLEL, async ([it, actual]) => {
    if (JSON.stringify(actual) === JSON.stringify(it.planned)) return;
    try {
      if (actual.length) await putSidecar(env, sidecarOf(it), actual);
      else await env.META.delete(sidecarOf(it));
      it.planned = actual;
    } catch (e) {
      console.error("similar_sidecar_rewrite_failed", lib, it.key, e);
    }
  });

  // 8. 消すと決まってから索引とハッシュの記録から外す（途中で戻した物を外したままにしない）。
  //    戻せずにゴミ箱に残った物も、元の key には無いので外す。見た目の署名は消さない:
  //    ゴミ箱から戻せば etag が同じままなので、そのまま使える
  const trashed = items.filter((i) => i.phase === "moved" || i.phase === "stuck").map((i) => i.key);
  const entry: JournalEntry = {
    ...(trashed.length ? { del: trashed } : {}),
    ...(backRows.length ? { put: backRows } : {}),
  };
  if (entry.del || entry.put) await journalBestEffort(env, lib, entry, ctx);
  await dropHashesBestEffort(env, lib, trashed);

  return json({
    results: items.map((it) =>
      it.phase === "moved"
        ? { key: it.key, ok: true, trashKey: it.trashKey, kind: it.kind }
        : it.phase === "stuck"
          ? // 元へ戻せずゴミ箱に残っている。アプリはゴミ箱から戻せると伝える
            { key: it.key, ok: false, error: "put_back_failed", trashKey: it.trashKey }
          : { key: it.key, ok: false, error: it.error ?? "move_failed" },
    ),
  });
}

/**
 * 残す側と比べ直して種類を決める。合わない物には error を付ける。
 * SHA-256 の記録が両方にあればそれで決め、無ければ sameContent がその場で計算する
 * （sameContent は呼ぶたびに数 MB のハッシュの記録を読み直すので、分かる物は先に済ませる）。
 */
async function classify(env: Env, lib: string, bucket: R2Bucket, list: TrashItem[]) {
  if (!list.length) return;
  const hashes = (await loadHashesCached(env, lib)).data;
  const maxBytes = hashBudget(env).maxObjectBytes;
  const unknown: TrashItem[] = [];
  const visual: TrashItem[] = [];
  for (const it of list) {
    const a = it.target!;
    const b = it.keeper!;
    // sameContent と同じ決まり: 大きさが違う・大きすぎる物は同じとは言わない
    if (a.size !== b.size || a.size > maxBytes) {
      visual.push(it);
      continue;
    }
    const x = validHash(hashes, rowOf(a));
    const y = validHash(hashes, rowOf(b));
    if (x && y) {
      if (x === y) it.kind = "identical";
      else visual.push(it);
    } else unknown.push(it);
  }
  await forEachLimit(unknown, MOVE_PARALLEL, async (it) => {
    if (await sameContent(env, lib, bucket, it.target!, it.keeper!)) it.kind = "identical";
    else visual.push(it);
  });
  if (!visual.length) return;

  // 同じ中身の物の集まりは、一覧と同じく集まりの署名（古い順で最初の単色でない物）で比べる。
  // 一員それぞれの署名で比べると、署名の無い写しや作り方の違うサムネで、一覧と違う答えになる
  const catalog = await loadCatalog(env, lib, bucket);
  const rowsOf = new Map<string, CatalogRow[]>();
  for (const it of visual) {
    for (const o of [it.target!, it.keeper!]) {
      // head で見た今の行で探す。一覧の後に入れ替わった物を古い絵で判定しない
      if (IMAGE_EXT.test(o.key) && !rowsOf.has(o.key)) {
        rowsOf.set(o.key, exactRows(rowOf(o), catalog, hashes));
      }
    }
  }
  const shards = new Map<number, Shard>();
  await forEachLimit(
    [...new Set([...rowsOf.values()].flat().map((r) => shardOf(r[0])))],
    HEAD_PARALLEL,
    async (n) => {
      shards.set(n, await loadShard(env, lib, n));
    },
  );
  const sideOf = (o: R2Object): { sig: Uint8Array; meta: PairMeta } | null => {
    const rows = rowsOf.get(o.key);
    if (!rows) return null;
    const side = exactSide(rows, (k) => shards.get(shardOf(k)));
    return side.sig
      ? { sig: side.sig, meta: { ow: side.ow, oh: side.oh, ext: extOf(o.key) } }
      : null;
  };
  for (const it of visual) {
    const k = sideOf(it.keeper!);
    const t = sideOf(it.target!);
    if (!k || !t) {
      it.error = "stale_signature";
      continue;
    }
    // sha256 は渡さない: 中身が同じかはここまでで決めてあり、見た目の判定だけが要る
    const r = compareSigs(k.sig, t.sig, k.meta, t.meta);
    if (r) it.kind = r.label;
    else it.error = "not_similar";
  }
}

/** いまのアルバムのうち、消す物が入っている所の控えを作る */
function membershipsIn(data: AlbumsFile, lib: string, it: TrashItem): TrashAlbumMembership[] {
  return data.albums.flatMap((a) => {
    const item = a.items.find((i) => i.lib === lib && i.key === it.key);
    return item
      ? [
          {
            albumId: a.id,
            item,
            keeper: it.keep,
            keeperAdded: false,
            exact: it.kind === "identical",
          },
        ]
      : [];
  });
}

/** 移した物の残す側を確かめ、無い物を gone に足す（一度無いと分かった物は確かめ直さない） */
async function checkKeepers(bucket: R2Bucket, list: TrashItem[], gone: Set<string>) {
  const keepers = [...new Set(list.map((i) => i.keep))].filter((k) => !gone.has(k));
  await forEachLimit(keepers, HEAD_PARALLEL, async (k) => {
    if (!(await bucket.head(k))) gone.add(k);
  });
}

/**
 * アルバムの中で、消す物の位置を残す側へ譲る。返すのは実際に書き換えた所属（控えの中身）。
 * 残す側が既に居るアルバムでは消す物を外すだけにする（同じ絵を 2 回並べない）。
 * 並びの控え（trashOrder）には消す物を残し、その直後に残す側を置く。ゴミ箱から戻した時に
 * 消す物が元の位置（残す側の手前）へ戻り、アルバムの末尾へ回らないようにするため。
 */
function handOver(
  data: AlbumsFile,
  lib: string,
  list: TrashItem[],
  meta: Map<string, IndexItem>,
): Map<TrashItem, TrashAlbumMembership[]> {
  const real = new Map<TrashItem, TrashAlbumMembership[]>(list.map((i) => [i, []]));
  const byKey = new Map(list.map((i) => [i.key, i]));
  const id = (k: string) => `${lib}:${k}`;
  for (const a of data.albums) {
    // アルバムの並び順に処理する。同じ残す側の物が 2 枚入っていれば、手前の物の位置に残す側が入る
    const hits = a.items
      .filter((i) => i.lib === lib && byKey.has(i.key))
      .map((i) => byKey.get(i.key)!);
    if (!hits.length) continue;
    foldGhostsIntoOrder(a);
    for (const it of hits) {
      const at = a.items.findIndex((i) => i.lib === lib && i.key === it.key);
      if (at < 0) continue;
      const gone = a.items[at]!;
      const hasKeeper = a.items.some((i) => i.lib === lib && i.key === it.keep);
      // 残す物が誰の代わりに居るかを控える。直後の取り消しは、代わりの物が全部戻った時だけ外す
      addKeeperDependent(a, id(it.keep), id(it.key), !hasKeeper);
      if (hasKeeper) {
        a.items.splice(at, 1);
      } else {
        const m = meta.get(it.keep);
        // メモと日時は残す側が空なら消す側のを引き継ぐ。thumb は残す側自身の物だけ使う
        // （trashDuplicate と同じ決まり）
        const entry: GlobalAlbumItem = {
          key: it.keep,
          lib,
          ...(m?.thumb ? { thumb: m.thumb } : {}),
          note: m?.note ?? gone.note,
          createdAt: m?.createdAt ?? gone.createdAt,
        };
        a.items[at] = entry;
        // 残す側が前にゴミ箱から外れた跡として並びに残っていても、今は実物として居るので位置は 1 つだけ
        const order = a.trashOrder!.filter((k) => k !== id(it.keep));
        order.splice(order.indexOf(id(it.key)) + 1, 0, id(it.keep));
        a.trashOrder = order;
      }
      real.get(it)!.push({
        albumId: a.id,
        item: gone,
        keeper: it.keep,
        keeperAdded: !hasKeeper,
        exact: it.kind === "identical",
      });
    }
  }
  return real;
}

const touchedAlbum = (a: GlobalAlbum, real: Map<TrashItem, TrashAlbumMembership[]>) => {
  for (const list of real.values()) if (list.some((m) => m.albumId === a.id)) return true;
  return false;
};

/**
 * albums.json の書き込みが例外で終わった時に、実は届いていたかを見る。書き換えた所属が 1 つも
 * 無ければ、届いたかどうかに関わらずファイルを戻してよいので false。確かめられなければ false
 * （従来どおり戻す側に倒す）。
 */
async function albumsLanded(
  env: Env,
  lib: string,
  real: Map<TrashItem, TrashAlbumMembership[]>,
): Promise<boolean> {
  const all = [...real].flatMap(([it, list]) => list.map((m) => ({ it, m })));
  if (!all.length) return false;
  try {
    const data = await loadAlbums(env);
    return all.every(({ it, m }) => {
      const a = data.albums.find((x) => x.id === m.albumId);
      if (!a) return false;
      const has = (k: string) => a.items.some((i) => i.lib === lib && i.key === k);
      return !has(it.key) && (!m.keeperAdded || has(it.keep));
    });
  } catch {
    return false;
  }
}

/**
 * 移動が例外で終わった時に、物が今どちらに在るかを見る。元の key に在れば「動いていない」、
 * 元に無くゴミ箱に在れば「移った」、どちらにも無ければ「無い」（別の操作が消した）。
 * 確かめられなければ unknown（その時は控えを消さない）。
 */
async function locate(
  bucket: R2Bucket,
  key: string,
  trashKey: string,
): Promise<"original" | "trash" | "none" | "unknown"> {
  try {
    if (await bucket.head(key)) return "original";
    return (await bucket.head(trashKey)) ? "trash" : "none";
  } catch {
    return "unknown";
  }
}

/** ゴミ箱から元の key へ戻す。戻った物を返し、数回試しても戻せなければ null */
async function moveBack(
  env: Env,
  bucket: R2Bucket,
  trashKey: string,
  key: string,
): Promise<R2Object | null> {
  for (let attempt = 0; attempt < MOVE_BACK_TRIES; attempt++) {
    try {
      // 途中まで進んで投げた時も、元の key に同じ中身が在れば戻っている（残った写しは消す）
      return (await moveBackFromTrash(env, bucket, trashKey, key, false)).obj;
    } catch (e) {
      console.error("similar_move_back_failed", key, attempt, e);
      // 元の key に別の物が置かれた・ゴミ箱側が無い時は、試し直しても戻せない
      if (
        e instanceof HttpError &&
        (e.code === "destination_exists" || e.code === "source_not_found")
      ) {
        return null;
      }
    }
  }
  return null;
}

/**
 * 取り消しのアルバムの書き込みが例外で終わった時に、実は届いていたかを見る。戻す物がどの
 * アルバムにも居て、残す物の代わりの控えからも外れていれば届いている。確かめられなければ false。
 */
async function undoLanded(env: Env, lib: string, list: UndoItem[]): Promise<boolean> {
  try {
    const data = await loadAlbums(env);
    return list.every((it) =>
      it.memberships!.every((m) => {
        const a = data.albums.find((x) => x.id === m.albumId);
        if (!a) return true;
        if (!a.items.some((i) => i.lib === lib && i.key === it.key)) return false;
        return !(m.keeper && a.keeperFor?.[`${lib}:${m.keeper}`]?.includes(`${lib}:${it.key}`));
      }),
    );
  } catch {
    return false;
  }
}

/* ---------------- 直後の取り消し ---------------- */

interface UndoItem {
  trashKey: string;
  key: string;
  ok: boolean;
  error?: string;
  status?: number;
  /** 控えの中身。控えが無ければ null */
  memberships: TrashAlbumMembership[] | null;
}

/**
 * POST /v1/:lib/similar/undo {trashKeys} — まとめて消した直後の「元に戻す」。
 * /ops/restore と違い、消した時に残す側を入れたアルバムからは残す側を外す（ちょうど逆の操作）。
 * ゴミ箱の画面から戻す時は /ops/restore を使い、残す側はアルバムに残る。
 */
export async function handleSimilarUndo(
  req: Request,
  env: Env,
  lib: string,
  ctx?: WaitUntil,
): Promise<Response> {
  const { bucket } = writable(env, lib);
  const body = await readJson(req);
  const raw = body.trashKeys;
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > similarLimits(env).trashBatch) {
    throw badItems();
  }
  const items: UndoItem[] = raw.map((v) => {
    const m = typeof v === "string" ? TRASH_KEY.exec(v) : null;
    if (!m) throw badItems();
    let key: string;
    try {
      key = assertUserKey(m[2]);
    } catch {
      throw badItems();
    }
    return { trashKey: v as string, key, ok: false, memberships: null };
  });
  if (new Set(items.map((i) => i.trashKey)).size !== items.length) throw badItems();

  const rows: CatalogRow[] = [];
  const thumb: string[] = [];
  const unthumb: string[] = [];
  const fail = (it: UndoItem, e: unknown) => {
    it.error = e instanceof HttpError ? e.code : "restore_failed";
    it.status = e instanceof HttpError ? e.status : 500;
  };

  // 1. ファイルを戻す（/ops/restore と同じ手順。控えは先に読んでおく）
  await forEachLimit(items, MOVE_PARALLEL, async (it) => {
    const sidecar = trashAlbumsPath(lib, it.trashKey);
    try {
      const saved = await env.META.get(sidecar);
      const parsed: unknown = saved ? await saved.json() : null;
      // 読めない控えのまま戻すと所属を黙って失う。動かさずに失敗を返し、控えも残す
      if (saved && !Array.isArray(parsed)) throw new HttpError(500, "bad_sidecar");
      it.memberships = parsed as TrashAlbumMembership[] | null;
      // 前回、ファイルは戻ったのにアルバムの更新（や索引の追記）で失敗した場合のやり直しも、
      // 写しが済んだのにゴミ箱側を消せなかった場合も、物の在り処で決める（/ops/restore と同じ）
      const { obj } = await moveBackFromTrash(env, bucket, it.trashKey, it.key, !!saved);
      // ゴミ箱の間もサムネは残してある。送った後に同じ key の別の物が置いたサムネは外す
      // （/ops/restore と同じ）。確かめられなかった時はサムネの有無に触れない
      const hasThumb = await restoredThumb(env, lib, it.key, it.trashKey);
      // やり直しでも行を足し直す。前回が索引の追記の前で止まっていると、一覧に戻らないため
      rows.push(rowOf(obj));
      if (hasThumb === true) thumb.push(it.key);
      else if (hasThumb === false) unthumb.push(it.key);
      it.ok = true;
    } catch (e) {
      fail(it, e);
    }
  });

  // 2. 索引への追記は 1 回にまとめる
  if (rows.length) {
    await journalBestEffort(
      env,
      lib,
      {
        put: rows,
        ...(thumb.length ? { thumb } : {}),
        ...(unthumb.length ? { unthumb } : {}),
      },
      ctx,
    );
  }

  // 3. アルバムも 1 回で戻す。先に全部を元の並びへ差し込み、その後で消した時に入れた残す側を外す
  //    （残す側を先に外すと、差し込む位置の目印が減る）
  const withAlbums = items.filter((i) => i.ok && i.memberships?.length);
  if (withAlbums.length) {
    const probe = makeProbe(env);
    let attempt = 0;
    // 一時的な失敗でファイルだけ戻ってアルバムが戻らないままにしないよう、この呼び出しの中で数回
    // 試し直す。書き換えは何度やっても同じ形になる（居る物は差し込まず、外し済みの残す物は "none"）
    const write = () =>
      mutateAlbums(env, async (data) => {
        if (attempt++) probe.reset();
        const touched = new Set<GlobalAlbum>();
        const find = (id: string) => data.albums.find((a) => a.id === id);
        for (const it of withAlbums) {
          for (const m of it.memberships!) {
            const album = find(m.albumId);
            if (!album) continue;
            touched.add(album);
            if (album.items.some((i) => i.lib === lib && i.key === it.key)) continue;
            insertByTrashOrder(album, m.item);
          }
        }
        for (const it of withAlbums) {
          for (const m of it.memberships!) {
            if (!m.keeper) continue;
            const album = find(m.albumId);
            if (!album) continue;
            // 残す物が、まだゴミ箱にいる別の物の代わりも務めている間は外さない
            // （先に消した方だけを取り消すと、後で消した物の場所が空になる）。
            // 代わりの控えが無い（"none"）時も外さない: 元から居た残す物か、同じ中身の物をゴミ箱から
            // 戻した時にそのアルバムでは残す物がずっと代わりを務めると決まった物（/ops/restore）。
            // やり直しで、前回の書き込みが既に残す物を外していた時もここに来る
            const left = dropKeeperDependent(album, `${lib}:${m.keeper}`, `${lib}:${it.key}`);
            if (left !== "last") continue;
            album.items = album.items.filter((i) => !(i.lib === lib && i.key === m.keeper));
          }
        }
        for (const album of touched) await pruneTrashOrder(probe, album);
      });
    let albumsOk = false;
    for (let tries = 0; tries < UNDO_ALBUM_TRIES && !albumsOk; tries++) {
      if (tries) await sleep(UNDO_ALBUM_BACKOFF_MS * 2 ** (tries - 1));
      try {
        await write();
        albumsOk = true;
      } catch (e) {
        console.error("similar_undo_albums_failed", lib, tries, e);
        // 書き込みは届いたのに応答で投げた時は、届いた物として扱う（/similar/trash と同じ）
        albumsOk = await undoLanded(env, lib, withAlbums);
      }
    }
    if (!albumsOk) {
      // ファイルは戻っている。控えは残すので、もう一度呼べば「やり直し」の手順でアルバムだけ直る
      // （アプリは albums_failed の物を少し待ってから呼び直す）
      for (const it of withAlbums) {
        it.ok = false;
        it.error = "albums_failed";
        it.status = 503;
      }
    }
  }

  // 4. 戻し終えた物の控えを消す
  await forEachLimit(
    items.filter((i) => i.ok && i.memberships),
    HEAD_PARALLEL,
    async (it) => deleteSidecarBestEffort(env, trashAlbumsPath(lib, it.trashKey)),
  );

  return json({
    results: items.map((it) =>
      it.ok
        ? { trashKey: it.trashKey, ok: true, key: it.key }
        : { trashKey: it.trashKey, ok: false, error: it.error, status: it.status },
    ),
  });
}
