import mediaExt from "./media-ext.json";

// 一覧が拾う拡張子の唯一の元は media-ext.json。アプリ側の Dart は
// tools/gen-media-ext.mjs がここから生成する（手書きすると食い違って「上がるのに出ない」になる）
const alt = (exts: readonly string[]) => exts.join("|");
export const IMAGE_EXT = new RegExp(`\\.(${alt(mediaExt.image)})$`, "i");
export const VIDEO_EXT = new RegExp(`\\.(${alt(mediaExt.video)})$`, "i");
export const MEDIA_EXT = new RegExp(`\\.(${alt([...mediaExt.image, ...mediaExt.video])})$`, "i");
export const SYSTEM_PREFIX = ".system/";
export const TRASH_PREFIX = ".trash/";
export const MAX_SIMPLE_UPLOAD = 100 * 1024 * 1024;

export const OTHER_ALBUM_ID = "__other__";
export const OTHER_ALBUM_TITLE = "その他";

export const IMPORT_MAX_DEFAULT = 50 * 1024 * 1024;
export const MAX_REDIRECTS = 3;

export const INDEX_CACHE_MS = 60_000;
