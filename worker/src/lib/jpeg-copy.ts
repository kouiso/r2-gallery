import { JPEG_COPY_EXT } from "./const";
import type { Env } from "./env";

// 自前の最小の型にする。理由: 試験の偽物を同じ型で書ける。Cloudflare の Workers の型定義パッケージの型名に依らない
export interface ImagesChain {
  transform(o: { width: number; height: number; fit: "scale-down" }): ImagesChain;
  output(o: { format: "image/jpeg"; quality: number }): Promise<{ response(): Response }>;
}
export interface ImagesLike {
  input(stream: ReadableStream<Uint8Array>): ImagesChain;
}

export const JPEG_COPY_MAX_BYTES = 20 * 1024 * 1024;
export const THUMB_EDGE = 512;
export const VIEW_EDGE = 2560;
export const JPEG_COPY_QUALITY = 85;

const imagesOf = (env: Env): ImagesLike | undefined => env.IMAGES as ImagesLike | undefined;

export const jpegCopyExt = (key: string) => JPEG_COPY_EXT.test(key);

/** 原本から長辺 edge の JPEG を作る。作れない時は null。null の後、src.body は読み切っている事がある。 */
export async function jpegCopy(
  env: Env,
  src: R2ObjectBody,
  edge: number,
): Promise<Uint8Array | null> {
  const images = imagesOf(env);
  if (!images) return null;
  if (src.size > JPEG_COPY_MAX_BYTES) return null;
  try {
    const out = await images
      .input(src.body)
      .transform({ width: edge, height: edge, fit: "scale-down" })
      .output({ format: "image/jpeg", quality: JPEG_COPY_QUALITY });
    const buf = new Uint8Array(await out.response().arrayBuffer());
    // binding の答えが JPEG でなければ写しと認めない（エラーページ等を保存しない）
    if (buf.length < 3 || buf[0] !== 0xff || buf[1] !== 0xd8 || buf[2] !== 0xff) return null;
    return buf;
  } catch (e) {
    console.error("jpeg_copy_failed", src.key, e);
    return null;
  }
}
