#!/usr/bin/env node
/**
 * Generic index + thumbnail uploader for the media worker.
 *
 * Operator-local tool: validates an index JSON, generates WebP thumbnails
 * under a scratch dir, and uploads both to the META bucket via `wrangler`
 * (`wrangler r2 object put`). Nothing here stores credentials — wrangler
 * auth and bucket names come from the operator's own environment.
 *
 * Usage:
 *   node tools/index-upload.mjs --index ./index.json --lib <library-id> \
 *     --meta-bucket <r2-bucket> [--media-root DIR] [--video-thumbs] \
 *     [--width 512] [--dry-run]
 *
 *   --index       index JSON file (see README "Index format")
 *   --lib         library id the index belongs to (uploaded as
 *                 `.system/index-<lib>.json`)
 *   --meta-bucket R2 bucket that holds `.system/` objects
 *   --media-root  local directory that mirrors object keys; needed to
 *                 generate thumbnails. Without it only the index is sent.
 *   --video-thumbs  also extract a poster frame from videos via ffmpeg
 *   --width       thumbnail max edge in px (default 512)
 *   --dry-run     validate and print the plan without uploading
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, existsSync, rmSync, writeFileSync } from "node:fs";
import { constants, tmpdir } from "node:os";
import { basename, extname, join, resolve } from "node:path";
import { parseArgs } from "node:util";

// Must match worker/src/lib/const.ts: a narrower list rejects indexes whose videos the
// worker would serve. tools/index-upload.test.mjs asserts the two stay in sync.
const IMAGE = "jpe?g|png|webp|gif|avif";
const VIDEO = "mp4|webm|mov|m4v|mkv|ts|m2ts|mpg|mpeg|avi|flv|3gp|wmv";
const IMAGE_RE = new RegExp(`\\.(${IMAGE})$`, "i");
const VIDEO_RE = new RegExp(`\\.(${VIDEO})$`, "i");
const MEDIA_RE = new RegExp(`\\.(${IMAGE}|${VIDEO})$`, "i");
const FORBIDDEN_PREFIX = /^(?:\.system\/|\.trash\/)/;
// The worker resolves declared albums first, so declaring this id hides the virtual "その他" album.
const RESERVED_ALBUM_IDS = new Set(["__other__"]);

const { values: args } = parseArgs({
  options: {
    index: { type: "string" },
    lib: { type: "string" },
    "meta-bucket": { type: "string" },
    "media-root": { type: "string" },
    "video-thumbs": { type: "boolean", default: false },
    width: { type: "string", default: "512" },
    wrangler: { type: "string", default: "wrangler" },
    "dry-run": { type: "boolean", default: false },
  },
});

function fail(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

if (!args.index || !args.lib || !args["meta-bucket"]) {
  fail("required: --index <file> --lib <id> --meta-bucket <bucket>");
}
if (!/^[a-z0-9-]+$/i.test(args.lib)) fail(`--lib must be a slug, got: ${args.lib}`);
const width = Number(args.width);
if (!Number.isFinite(width) || width < 32 || width > 4096) fail("--width must be 32..4096");

function validKey(key) {
  return (
    typeof key === "string" &&
    key.length > 0 &&
    !key.includes("..") &&
    !key.startsWith("/") &&
    !FORBIDDEN_PREFIX.test(key) &&
    MEDIA_RE.test(key)
  );
}

function validateIndex(data) {
  const errors = [];
  if (data?.version !== 1) errors.push("version must be 1");
  if (!Array.isArray(data?.albums)) errors.push("albums must be an array");
  const ids = new Set();
  const checkItems = (items, where) => {
    if (!Array.isArray(items)) {
      errors.push(`${where}: items must be an array`);
      return;
    }
    items.forEach((it, i) => {
      if (!validKey(it?.key)) errors.push(`${where}[${i}]: invalid key ${JSON.stringify(it?.key)}`);
      // thumb は `<thumb>.webp` として META へ置かれ署名 URL で配信されるため、
      // 宣言された参照先も通常キーと同じ制約（形式・サイズ・prefix）を満たす必要がある。
      if (it?.thumb !== undefined && !validKey(it.thumb))
        errors.push(`${where}[${i}]: invalid thumb key ${JSON.stringify(it?.thumb)}`);
      if (it?.note !== undefined && typeof it.note !== "string")
        errors.push(`${where}[${i}]: note must be a string`);
    });
  };
  for (const a of data?.albums ?? []) {
    if (typeof a?.id !== "string" || !a.id) errors.push("album missing id");
    if (ids.has(a?.id)) errors.push(`duplicate album id: ${a.id}`);
    if (RESERVED_ALBUM_IDS.has(a?.id)) errors.push(`reserved album id: ${a.id}`);
    ids.add(a?.id);
    if (typeof a?.title !== "string" || !a.title) errors.push(`${a?.id}: missing title`);
    if (a?.cover !== undefined && !validKey(a.cover))
      errors.push(`${a?.id}: invalid cover key ${JSON.stringify(a?.cover)}`);
    checkItems(a?.items, `album ${a?.id}`);
  }
  if (data?.items !== undefined) checkItems(data.items, "items");
  return errors;
}

let index;
try {
  index = JSON.parse(readFileSync(args.index, "utf8"));
} catch (e) {
  fail(`cannot read index ${args.index}: ${e.message}`);
}
const errors = validateIndex(index);
if (errors.length) {
  errors.forEach((e) => console.error(`  - ${e}`));
  fail(`index validation failed (${errors.length} error(s))`);
}

// Every media key needing a thumbnail: declared albums + flat items list.
const allItems = [
  ...(index.items ?? []),
  ...(index.albums ?? []).flatMap((a) => a.items ?? []),
];
const keys = [...new Set(allItems.map((i) => i.key))];
const mediaRoot = args["media-root"] ? resolve(args["media-root"]) : null;

const wranglerPut = (bucketKey, file, contentType) => {
  execFileSync(
    args.wrangler,
    ["r2", "object", "put", `${args["meta-bucket"]}/${bucketKey}`, "--file", file, "--content-type", contentType, "--remote"],
    { stdio: "inherit" },
  );
};

const dry = args["dry-run"];
const tmp = mkdtempSync(join(tmpdir(), "qn-index-"));
process.on("exit", () => rmSync(tmp, { recursive: true, force: true }));
// A signal kills the process without emitting "exit"; route it through exit so Ctrl-C mid-upload
// does not leave thumbnails and the index copy behind.
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => process.exit(128 + constants.signals[signal]));
}

let sharp = null;
if (mediaRoot && !dry) {
  try {
    sharp = (await import("sharp")).default;
  } catch {
    fail("sharp is required for thumbnails (run via `pnpm exec` or `pnpm tools:index-upload`)");
  }
}

// ffmpeg only grabs a PNG frame; sharp does the WebP encode. Many ffmpeg builds (Homebrew's
// included) ship without a WebP encoder, so asking ffmpeg for .webp fails there.
function extractFrame(src, key, frame) {
  // 0.5s skips a black first frame; clips shorter than that fall back to the first frame.
  let reason = "no video frame found";
  for (const seek of ["0.5", "0"]) {
    try {
      execFileSync(
        "ffmpeg",
        ["-y", "-loglevel", "error", "-ss", seek, "-i", src, "-frames:v", "1", frame],
        { stdio: ["ignore", "ignore", "pipe"] },
      );
    } catch (e) {
      reason = String(e.stderr || e.message).trim();
    }
    if (existsSync(frame)) return frame;
  }
  return fail(`ffmpeg could not extract a poster frame from ${key}: ${reason}`);
}

let uploaded = 0;
let skipped = 0;
for (const key of keys) {
  const src = mediaRoot ? join(mediaRoot, key) : null;
  const thumbKey = `.system/thumbs/${args.lib}/${key}.webp`;
  const isImage = IMAGE_RE.test(key);
  const isVideo = VIDEO_RE.test(key);
  if (!src || !existsSync(src) || (!isImage && !(isVideo && args["video-thumbs"]))) {
    skipped++;
    continue;
  }
  if (dry) {
    console.log(`dry-run: would upload ${thumbKey} <- ${src}`);
    uploaded++;
    continue;
  }
  const out = join(tmp, `${keys.indexOf(key)}.webp`);
  const input = isImage ? src : extractFrame(src, key, join(tmp, `${keys.indexOf(key)}.png`));
  await sharp(input)
    .resize(width, width, { fit: "inside", withoutEnlargement: true })
    .webp({ quality: 78 })
    .toFile(out);
  wranglerPut(thumbKey, out, "image/webp");
  uploaded++;
}

const indexKey = `.system/index-${args.lib}.json`;
if (dry) {
  console.log(`dry-run: would upload ${indexKey} <- ${args.index}`);
} else {
  // Write the validated index to a temp file so the original is never touched.
  const norm = join(tmp, basename(args.index));
  writeFileSync(norm, JSON.stringify(index));
  wranglerPut(indexKey, norm, "application/json");
}

console.log(
  `done: index -> ${indexKey}; thumbs ${uploaded} uploaded, ${skipped} skipped` +
    (mediaRoot ? "" : " (no --media-root; thumbnails not generated)"),
);
