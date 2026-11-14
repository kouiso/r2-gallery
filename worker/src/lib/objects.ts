import { SYSTEM_PREFIX, TRASH_PREFIX } from "./const";
import type { Env } from "./env";
import { HttpError } from "./http";
import { libraries } from "./env";

/**
 * A head() check before put() still lets a write that lands in between be replaced.
 * If-None-Match: * makes R2 enforce "create only" atomically; put() returns null instead.
 */
export const createOnly = (): Headers => new Headers({ "if-none-match": "*" });

/**
 * R2 multipart complete() accepts no precondition, so re-check right before committing:
 * the init-time check alone leaves the whole upload duration open to a replacing write.
 */
export async function completeCreateOnly(
  bucket: R2Bucket,
  up: R2MultipartUpload,
  parts: R2UploadedPart[],
): Promise<R2Object> {
  if (await bucket.head(up.key)) {
    await up.abort().catch(() => undefined);
    throw new HttpError(409, "destination_exists");
  }
  return up.complete(parts);
}

export async function copyObject(
  env: Env,
  src: R2Bucket,
  srcKey: string,
  dst: R2Bucket,
  dstKey: string,
): Promise<R2Object> {
  if (await dst.head(dstKey)) throw new HttpError(409, "destination_exists");
  const head = await src.head(srcKey);
  if (!head) throw new HttpError(404, "source_not_found");
  const mpMin = Number(env.MULTIPART_COPY_MIN_BYTES ?? 96 * 1024 * 1024);
  const put =
    head.size > mpMin
      ? await copyMultipart(env, src, head, dst, dstKey)
      : await dst.put(dstKey, (await src.get(srcKey))!.body, {
          httpMetadata: head.httpMetadata,
          customMetadata: head.customMetadata,
          onlyIf: createOnly(),
        });
  if (!put) throw new HttpError(409, "destination_exists");
  if (put.size !== head.size) throw new HttpError(500, "copy_verify_failed");
  return put;
}

/** Server-side copy for large objects: ranged reads into a multipart upload. */
async function copyMultipart(
  env: Env,
  src: R2Bucket,
  head: R2Object,
  dst: R2Bucket,
  dstKey: string,
): Promise<R2Object> {
  const partSize = Math.max(
    5 * 1024 * 1024,
    Number(env.MULTIPART_COPY_PART_BYTES ?? 64 * 1024 * 1024),
  );
  const mp = await dst.createMultipartUpload(dstKey, {
    httpMetadata: head.httpMetadata,
    customMetadata: head.customMetadata,
  });
  try {
    const parts: R2UploadedPart[] = [];
    for (let offset = 0, n = 1; offset < head.size; offset += partSize, n++) {
      const obj = await src.get(head.key, {
        range: { offset, length: Math.min(partSize, head.size - offset) },
      });
      if (!obj) throw new HttpError(404, "source_not_found");
      parts.push(await mp.uploadPart(n, obj.body));
    }
    return await completeCreateOnly(dst, mp, parts);
  } catch (e) {
    await mp.abort().catch(() => undefined);
    throw e;
  }
}

export async function moveObject(
  env: Env,
  src: R2Bucket,
  srcKey: string,
  dst: R2Bucket,
  dstKey: string,
): Promise<R2Object> {
  const put = await copyObject(env, src, srcKey, dst, dstKey);
  const check = await dst.head(dstKey);
  if (!check || check.size !== put.size) throw new HttpError(500, "move_verify_failed");
  await src.delete(srcKey);
  return put;
}

/**
 * サムネは本体とは別の META に key 単位で置かれ、本体を消しても残る。
 * 同名で別の物を上げ直した時に古い絵が出ないよう、本体が入れ替わる所で必ず消す。
 */
export async function deleteThumb(env: Env, lib: string, key: string): Promise<void> {
  await env.META.delete(`${SYSTEM_PREFIX}thumbs/${lib}/${key}.webp`);
}

/** ゴミ箱の保持日数。削除する側と画面に出す側で同じ値を使うため1か所で読む */
export function trashRetentionDays(env: Env): number {
  return Number(env.TRASH_RETENTION_DAYS ?? "30") || 30;
}

/**
 * 作成・移動が成功した後のサムネ掃除。ここで失敗を 5xx にすると、保存済みなのに
 * クライアントが再送して 409 になり、別名で二重保存される。なので握りつぶして記録だけ残す。
 */
export async function dropThumbBestEffort(env: Env, lib: string, key: string): Promise<void> {
  try {
    await deleteThumb(env, lib, key);
  } catch (e) {
    console.error("thumb_delete_failed", lib, key, e);
  }
}

/**
 * 1回の purge で「サムネ→本体」を済ませる期限切れエントリ数。1回の cron 呼び出しの
 * subrequest 数・時間には上限があり、全件を先にサムネ処理すると毎回同じ所で落ちて
 * 本体が一度も消えない恐れがある。小さな単位で完結させれば、落ちても済んだ分は残らない。
 */
export const PURGE_BATCH = 100;

export async function purgeTrash(env: Env, batchSize = PURGE_BATCH): Promise<number> {
  const days = trashRetentionDays(env);
  const cutoff = Date.now() - days * 86_400_000;
  let removed = 0;
  for (const lib of libraries(env)) {
    const bucket = env[lib.binding] as R2Bucket | undefined;
    if (!bucket || lib.readOnly) continue;
    // サムネは元のキー単位なので、期限切れと同名の「まだ新しい」ゴミ箱エントリが
    // 1つでもあれば（restore で必要）消せない。list は軽いので全件を先に数えてから判定する。
    const expired: string[] = [];
    const liveOriginals = new Set<string>();
    let cursor: string | undefined;
    do {
      const listed = await bucket.list({ prefix: TRASH_PREFIX, cursor, limit: 1000 });
      for (const o of listed.objects) {
        const m = /^\.trash\/(\d+)\/(.*)$/.exec(o.key);
        if (!m) continue;
        if (Number(m[1]) < cutoff) expired.push(o.key);
        else liveOriginals.add(m[2] ?? "");
      }
      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);

    for (let i = 0; i < expired.length; i += batchSize) {
      const batch = expired.slice(i, i + batchSize);
      // 本体より先にサムネを消す。途中で落ちてもその batch の本体（期限切れ）は残るので
      // 次回また通り、サムネだけが孤児になることはない。済んだ batch の本体は消えているので
      // 実行のたびに必ず先へ進む（META 障害が続く間は止まるが、再試行できる側に倒れる）。
      const originals = new Set<string>();
      for (const tk of batch) {
        const original = /^\.trash\/\d+\/(.+)$/.exec(tk)?.[1];
        if (original) originals.add(original);
      }
      for (const original of originals) {
        if (liveOriginals.has(original)) continue;
        // 同名で上げ直された新しい物が居る間は、そのサムネなので触らない
        if (await bucket.head(original)) continue;
        await deleteThumb(env, lib.id, original);
      }
      await bucket.delete(batch);
      removed += batch.length;
    }
  }
  return removed;
}
