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

// 候補のうち「まだ戻せる物」を返す。期限切れ purge は控えを消さないので、控えがあり、かつ
// .trash の実体も元の key も無い物だけを purge 済みと見なす。restore は実体を先に元の key へ戻して
// からアルバムを更新するので、元の key を見ないと、その間に戻している途中の物が落ちてしまう。
// 控えの一覧と head の結果はリクエスト内で使い回し、mutateAlbums がやり直す時だけ捨てる
// （並行した trash が書いた控えを見落として落とさないため）。
//
// ゴミ箱の実体は 1 件ずつ head せず、送った時刻の階（.trash/<時刻>/）ごとに 1 回 list して確かめる。
// まとめて消す口は 40 件を同じ時刻で送るので、アルバムに数百件の跡が溜まっても数回の list で済む。
// 1 件ずつ head すると、跡 1 件ごとに 2 回の外部呼び出しが毎回の書き込みで掛かり、同じアルバムから
// 240 件ほど消した所で 1 リクエストの上限（1000 回）を超えていた。元の key の head は、ゴミ箱に
// 実体が無い物（purge 済みか戻している途中）だけに行う。purge 済みならその書き込みで跡から外れるので、
// 同じ物に何度も払わない。
export function makeProbe(env: Env) {
  let lists = new Map<string, Promise<Map<string, string[]>>>();
  let heads = new Map<string, Promise<boolean>>();
  let floors = new Map<string, Promise<Set<string>>>();
  const trashFloor = (lib: string, bucket: R2Bucket, trashKey: string) => {
    const at = trashKey.indexOf("/", TRASH_PREFIX.length);
    const prefix = at < 0 ? trashKey : trashKey.slice(0, at + 1);
    const id = `${lib}\n${prefix}`;
    let p = floors.get(id);
    if (!p) {
      p = (async () => {
        const out = new Set<string>();
        let cursor: string | undefined;
        do {
          const listed = await bucket.list({ prefix, cursor });
          for (const o of listed.objects) out.add(o.key);
          cursor = listed.truncated ? listed.cursor : undefined;
        } while (cursor);
        return out;
      })();
      floors.set(id, p);
    }
    return p;
  };
  const listSidecars = (lib: string) => {
    let p = lists.get(lib);
    if (!p) {
      p = (async () => {
        const out = new Map<string, string[]>();
        const prefix = `${SYSTEM_PREFIX}trash-albums/${lib}/`;
        let cursor: string | undefined;
        do {
          const listed = await env.META.list({ prefix, cursor });
          for (const o of listed.objects) {
            const m = /^(\d+)\/([\s\S]+)\.json$/.exec(o.key.slice(prefix.length));
            if (!m) continue;
            const id = `${lib}:${m[2]}`;
            out.set(id, [...(out.get(id) ?? []), `${TRASH_PREFIX}${m[1]}/${m[2]}`]);
          }
          cursor = listed.truncated ? listed.cursor : undefined;
        } while (cursor);
        return out;
      })();
      lists.set(lib, p);
    }
    return p;
  };
  const head = (lib: string, bucket: R2Bucket, key: string) => {
    const id = `${lib}\n${key}`;
    let p = heads.get(id);
    if (!p) {
      p = bucket.head(key).then((o) => o !== null);
      heads.set(id, p);
    }
    return p;
  };
  return {
    reset() {
      lists = new Map();
      heads = new Map();
      floors = new Map();
    },
    async live(candidates: Set<string>): Promise<Set<string>> {
      const live = new Set<string>();
      for (const id of candidates) {
        const lib = id.slice(0, id.indexOf(":"));
        const original = id.slice(lib.length + 1);
        const t = bucketFor(env, lib);
        const trashKeys = t ? (await listSidecars(lib)).get(id) : undefined;
        if (!t || !trashKeys) continue;
        const inTrash = await Promise.all(
          trashKeys.map(async (k) => (await trashFloor(lib, t.bucket, k)).has(k)),
        );
        if (inTrash.some(Boolean) || (await head(lib, t.bucket, original))) live.add(id);
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
