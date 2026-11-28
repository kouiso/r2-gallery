import { SYSTEM_PREFIX, TRASH_PREFIX } from "./const";
import type { Env } from "./env";
import { bucketFor } from "./env";
import type { GlobalAlbum, GlobalAlbumItem } from "./store";

/**
 * ゴミ箱へ送った物のアルバム所属の控えと、並びを戻すための道具。
 * 1 件ずつのゴミ箱（routes/write.ts）と、まとめて消す口（routes/similar-trash.ts）の両方が
 * 同じ控えの形と同じ並びの規則を使わないと、片方で消した物をもう片方で戻した時に位置がずれる。
 */

// ゴミ箱へ送る時に外したアルバムの控え。復元で元のアルバムへ戻すために、
// 外した項目そのものを META に置く（R2 のゴミ箱には載せない）。
export interface TrashAlbumMembership {
  albumId: string;
  item: GlobalAlbumItem;
  /**
   * 重複・似ている物として消した時の「残す側」の key（同じライブラリ）。
   * 古い控えには無い。無ければ従来どおりの扱いになる
   */
  keeper?: string;
  /** 消した時に、残す側をこのアルバムの空いた位置へ入れたか。直後の取り消しで残す側を外すのに使う */
  keeperAdded?: boolean;
  /** 中身が同じ（SHA-256 が一致）として消したか。ゴミ箱から戻しても残す側の居るアルバムへは戻さない */
  exact?: boolean;
}

export const trashAlbumsPath = (lib: string, trashKey: string) =>
  `${SYSTEM_PREFIX}trash-albums/${lib}/${trashKey.slice(TRASH_PREFIX.length)}.json`;
export const refKey = (i: { lib: string; key: string }) => `${i.lib}:${i.key}`;

// 位置の控えは index ではなく「ゴミ箱の物も含めた並び」を albums.json 側に持つ。
// index だと、複数枚を送った時に後の物の位置が先に抜けた物の分ずれて、戻すと逆順になる。
export function foldGhostsIntoOrder(album: GlobalAlbum) {
  const order = album.items.map(refKey);
  const seen = new Set(order);
  const prev = album.trashOrder ?? [];
  prev.forEach((id, i) => {
    if (seen.has(id)) return;
    // 手前にいた物のうち残っている最寄りの後ろへ。無ければ先頭
    let at = 0;
    for (let j = i - 1; j >= 0; j--) {
      const k = order.indexOf(prev[j]!);
      if (k >= 0) {
        at = k + 1;
        break;
      }
    }
    order.splice(at, 0, id);
    seen.add(id);
  });
  album.trashOrder = order;
}

/**
 * 跡を確かめるのに 1 リクエストで使ってよい外部呼び出しの数（既定）。1 リクエストの上限は 1000 回で、
 * 跡の数（アルバムから消した物の数）は上限なく増える。使い切った後の跡は確かめずに「まだ戻せる」と
 * 見なして残す（落とす側に倒すと、戻した時に元の位置へ戻らない）。落とせる跡は次の書き込みで少しずつ落ちる
 */
export const PROBE_BUDGET = 150;

// 候補のうち「まだ戻せる物」を返す。控えがあり、かつ .trash の実体も元の key も無い物だけを
// purge 済みと見なす（期限切れの purge は控えも消すが、この直しより前に purge した物は控えが残っている）。
// restore は実体を先に元の key へ戻してからアルバムを更新するので、元の key を見ないと、その間に
// 戻している途中の物が落ちてしまう。
//
// ゴミ箱の実体は 1 件ずつ head せず、送った時刻の階（.trash/<時刻>/）ごとに 1 回 list して確かめる
// （まとめて消す口は 40 件を同じ時刻で送る）。1 件ずつのゴミ箱は件ごとに階が違うので、跡 1 件に 1 回
// かかる。どちらも合わせて budget 回で打ち切る。確かめる順は送った時刻の古い順: purge で消えた跡
// （一番古い）から確かめるので、使い切っても落とせる跡が先に落ちる。
//
// 確かめた結果は mutateAlbums がやり直しても使い回す（やり直すたびに同じ数を払うと、競合 1 回で倍になる）。
// やり直しで読み直した albums.json に新しく現れた跡は、並行した trash がまだ控えを書き終えていない
// かもしれないので、確かめずに「まだ戻せる」とする。前の回に確かめた跡の答えは、その時点の答えとして
// 正しい（こちらが先に書けていても同じ結果になる）。
export function makeProbe(env: Env, limit = PROBE_BUDGET) {
  // テストは env で下げられる（上げられない）
  const lowered = Number(env.TRASH_PROBE_BUDGET);
  const budget =
    Number.isInteger(lowered) && lowered >= 0 && env.TRASH_PROBE_BUDGET
      ? Math.min(limit, lowered)
      : limit;
  let spent = 0;
  const take = () => {
    if (spent >= budget) return false;
    spent++;
    return true;
  };
  let reread = false;
  const verdict = new Map<string, boolean>();
  const sidecars = new Map<string, Promise<Map<string, string[]> | null>>();
  const floors = new Map<string, Promise<Set<string> | null>>();
  /** prefix の下を全部列挙する。途中で使い切ったら false（集めた分は使わない） */
  const listAll = async (
    bucket: R2Bucket,
    prefix: string,
    each: (key: string) => void,
  ): Promise<boolean> => {
    let cursor: string | undefined;
    do {
      if (!take()) return false;
      const listed = await bucket.list({ prefix, cursor });
      for (const o of listed.objects) each(o.key);
      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);
    return true;
  };
  const sidecarsOf = (lib: string) => {
    let p = sidecars.get(lib);
    if (!p) {
      p = (async () => {
        const out = new Map<string, string[]>();
        const prefix = `${SYSTEM_PREFIX}trash-albums/${lib}/`;
        const done = await listAll(env.META, prefix, (key) => {
          const m = /^(\d+)\/([\s\S]+)\.json$/.exec(key.slice(prefix.length));
          if (!m) return;
          const id = `${lib}:${m[2]}`;
          out.set(id, [...(out.get(id) ?? []), `${TRASH_PREFIX}${m[1]}/${m[2]}`]);
        });
        return done ? out : null;
      })();
      sidecars.set(lib, p);
    }
    return p;
  };
  const floorOf = (lib: string, bucket: R2Bucket, trashKey: string) => {
    const at = trashKey.indexOf("/", TRASH_PREFIX.length);
    const prefix = at < 0 ? trashKey : trashKey.slice(0, at + 1);
    const id = `${lib}\n${prefix}`;
    let p = floors.get(id);
    if (!p) {
      p = (async () => {
        const out = new Set<string>();
        return (await listAll(bucket, prefix, (key) => out.add(key))) ? out : null;
      })();
      floors.set(id, p);
    }
    return p;
  };
  const timeOf = (trashKey: string) => Number(trashKey.slice(TRASH_PREFIX.length).split("/")[0]);
  /** まだ戻せるか。確かめきれなければ null */
  const check = async (
    lib: string,
    bucket: R2Bucket,
    original: string,
    trashKeys: string[],
  ): Promise<boolean | null> => {
    for (const k of trashKeys) {
      const floor = await floorOf(lib, bucket, k);
      if (!floor) return null;
      if (floor.has(k)) return true;
    }
    if (!take()) return null;
    return (await bucket.head(original)) !== null;
  };
  return {
    /** mutateAlbums がやり直す（albums.json を読み直した）時に呼ぶ */
    reset() {
      reread = true;
    },
    async live(candidates: Set<string>): Promise<Set<string>> {
      const live = new Set<string>();
      const open: { id: string; lib: string; bucket: R2Bucket; keys: string[]; at: number }[] = [];
      for (const id of candidates) {
        const known = verdict.get(id);
        if (known !== undefined) {
          if (known) live.add(id);
          continue;
        }
        if (reread) {
          live.add(id);
          continue;
        }
        const lib = id.slice(0, id.indexOf(":"));
        const t = bucketFor(env, lib);
        if (!t) {
          verdict.set(id, false);
          continue;
        }
        const side = await sidecarsOf(lib);
        if (!side) {
          live.add(id);
          continue;
        }
        const keys = side.get(id);
        // 控えが無い跡は戻しても元の位置へ入らない（戻す道が無い）。呼び出しなしで落とす
        if (!keys) {
          verdict.set(id, false);
          continue;
        }
        open.push({ id, lib, bucket: t.bucket, keys, at: Math.min(...keys.map(timeOf)) });
      }
      open.sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
      for (const c of open) {
        const v = await check(c.lib, c.bucket, c.id.slice(c.lib.length + 1), c.keys);
        if (v === null) {
          live.add(c.id);
          continue;
        }
        verdict.set(c.id, v);
        if (v) live.add(c.id);
      }
      return live;
    },
  };
}
export type Probe = ReturnType<typeof makeProbe>;

// 並びの控えが増え続けないよう、アルバムにも今のゴミ箱にも無い key（アルバムから外した物、
// purge された物）を落とし、ゴミ箱の物が無くなれば控え自体を消す。mutateAlbums の中で呼ぶ。
// trash は控えを書いてから albums.json を更新するので、並行して送った物は落ちない。
export async function pruneTrashOrder(probe: Probe, album: GlobalAlbum) {
  const order = album.trashOrder;
  const present = new Set(album.items.map(refKey));
  const ghosts = new Set((order ?? []).filter((k) => !present.has(k)));
  // 残す物がアルバムに居なくても、ゴミ箱に居てまだ戻せるなら代わりの控えは畳まない。
  // 残す物をゴミ箱へ送って戻す（または取り消す）と、控えが無いまま残す物がアルバムへ戻り、
  // 後の取り消しで残す物を外せなくなる。並びの控えには載らないので、ここで候補へ足す
  const candidates = new Set(ghosts);
  for (const k of Object.keys(album.keeperFor ?? {})) if (!present.has(k)) candidates.add(k);
  const live = candidates.size ? await probe.live(candidates) : candidates;
  // 代わりの控えも同じ決まりで畳む。残す物がもう居ない（戻せない）、または代わっている物が
  // ゴミ箱から消えた（purge・別の口で戻した）分は、もう誰の代わりでもない
  if (album.keeperFor) {
    for (const [k, deps] of Object.entries(album.keeperFor)) {
      const rest = present.has(k) || live.has(k) ? deps.filter((d) => live.has(d)) : [];
      if (rest.length) album.keeperFor[k] = rest;
      else delete album.keeperFor[k];
    }
    if (!Object.keys(album.keeperFor).length) delete album.keeperFor;
  }
  if (!order) return;
  if (![...ghosts].some((k) => live.has(k))) {
    delete album.trashOrder;
    return;
  }
  album.trashOrder = order.filter((k) => present.has(k) || live.has(k));
}

/**
 * 消した物 dep の代わりに残す物 keeper がアルバムに居ることを控える。added は「この消し方で
 * 残す物を入れた」か。入れていなくても、残す物が既に誰かの代わりで居るなら dep も足す
 * （その残す物は、元から居た物ではないため）。
 */
export function addKeeperDependent(
  album: GlobalAlbum,
  keeper: string,
  dep: string,
  added: boolean,
): void {
  const deps = album.keeperFor?.[keeper];
  if (deps) {
    if (!deps.includes(dep)) deps.push(dep);
    return;
  }
  if (!added) return;
  album.keeperFor = { ...album.keeperFor, [keeper]: [dep] };
}

/**
 * dep がゴミ箱から戻った（または戻さないと決まった）。残す物 keeper が代わっていた物が
 * これで無くなれば "last"、まだ残れば "remaining"、控えが無ければ "none"。
 */
export function dropKeeperDependent(
  album: GlobalAlbum,
  keeper: string,
  dep: string,
): "last" | "remaining" | "none" {
  const map = album.keeperFor;
  const deps = map?.[keeper];
  if (!map || !deps) return "none";
  const rest = deps.filter((d) => d !== dep);
  if (rest.length) {
    map[keeper] = rest;
    return "remaining";
  }
  delete map[keeper];
  if (!Object.keys(map).length) delete album.keeperFor;
  return "last";
}

export function insertByTrashOrder(album: GlobalAlbum, item: GlobalAlbumItem) {
  const id = refKey(item);
  const order = album.trashOrder ?? [];
  const idx = order.indexOf(id);
  // 項目数の2乗にならないよう、現在の位置は一度だけ作る
  const where = new Map(album.items.map((i, n) => [refKey(i), n]));
  let at = album.items.length;
  if (idx >= 0) {
    // 最寄りの手前の物の後ろ → 無ければ最寄りの後ろの物の前 → 無ければ先頭
    at = 0;
    let found = false;
    for (let j = idx - 1; j >= 0 && !found; j--) {
      const k = where.get(order[j]!);
      if (k !== undefined) {
        at = k + 1;
        found = true;
      }
    }
    for (let j = idx + 1; j < order.length && !found; j++) {
      const k = where.get(order[j]!);
      if (k !== undefined) {
        at = k;
        found = true;
      }
    }
  }
  album.items.splice(at, 0, item);
}
