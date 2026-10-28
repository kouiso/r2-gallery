import { TRASH_PREFIX } from "./const";
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

/** ゴミ箱の保持日数。削除する側と画面に出す側で同じ値を使うため1か所で読む */
export function trashRetentionDays(env: Env): number {
  return Number(env.TRASH_RETENTION_DAYS ?? "30") || 30;
}

export async function purgeTrash(env: Env): Promise<number> {
  const days = trashRetentionDays(env);
  const cutoff = Date.now() - days * 86_400_000;
  let removed = 0;
  for (const lib of libraries(env)) {
    const bucket = env[lib.binding] as R2Bucket | undefined;
    if (!bucket || lib.readOnly) continue;
    let cursor: string | undefined;
    do {
      const listed = await bucket.list({ prefix: TRASH_PREFIX, cursor, limit: 1000 });
      const expired = listed.objects
        .filter((o) => Number(/^\.trash\/(\d+)\//.exec(o.key)?.[1] ?? Infinity) < cutoff)
        .map((o) => o.key);
      if (expired.length) {
        await bucket.delete(expired);
        removed += expired.length;
      }
      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);
  }
  return removed;
}
