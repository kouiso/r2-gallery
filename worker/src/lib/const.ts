export const IMAGE_EXT = /\.(jpe?g|png|webp|gif|avif)$/i;
const VIDEO = "mp4|webm|mov|m4v|mkv|ts|m2ts|mpg|mpeg|avi|flv|3gp|wmv";
export const VIDEO_EXT = new RegExp(`\\.(${VIDEO})$`, "i");
export const MEDIA_EXT = new RegExp(`\\.(jpe?g|png|webp|gif|avif|${VIDEO})$`, "i");
export const SYSTEM_PREFIX = ".system/";
export const TRASH_PREFIX = ".trash/";
export const MAX_SIMPLE_UPLOAD = 100 * 1024 * 1024;

export const OTHER_ALBUM_ID = "__other__";
export const OTHER_ALBUM_TITLE = "その他";

export const IMPORT_MAX_DEFAULT = 50 * 1024 * 1024;
export const MAX_REDIRECTS = 3;

export const INDEX_CACHE_MS = 60_000;
