/**
 * Private image storage viewer API.
 *
 * A "library" is one R2 bucket. Libraries are declared in the LIBRARIES var.
 *
 * - GET /, /health                           -> {ok:true} (no bearer needed)
 * - GET /v1/libraries                         -> configured libraries
 * - GET /v1/:lib/albums                       -> album list (user albums from META/.system/albums.json + pipeline albums from index-<lib>.json)
 * - GET /v1/:lib/albums/:id?cursor=&limit=    -> items in an album, with signed media URLs
 * - GET /v1/:lib/folders?prefix=&cursor=&sort=&type=&recursive=&fresh=
 *                                             -> folder browsing; sorted listings are served from the
 *                                                catalog in META/.system/catalog/ (fresh=1 rebuilds it first)
 * - GET /v1/:lib/duplicates?cursor=&limit=    -> groups of byte-identical media (from recorded SHA-256)
 * - POST /v1/:lib/duplicates/scan             -> hash a bounded batch of same-size candidates -> {pending,hashed,skipped}
 * - POST /v1/:lib/objects/check {items:[{size,sha256?}]} -> same-size counts / same-content matches before upload
 * - GET /v1/:lib/meta?key=                    -> review metadata joined from D1 (REVIEW_LIBS only)
 * - GET /m/:lib/<key>?e=&s=                   -> original object (signed, no bearer needed)
 * - GET /t/:lib/<key>?e=&s=                   -> thumbnail from META/.system/thumbs/<lib>/ (falls back to original)
 *
 * Write operations (libraries with readOnly !== true only):
 * - PUT  /v1/:lib/objects?key=               -> upload a small object (body = bytes; refuses to overwrite;
 *                                                optional x-content-sha256 is verified by R2 and recorded)
 * - POST /v1/:lib/objects/multipart          {key, contentType}    -> {uploadId}
 * - PUT  /v1/:lib/objects/multipart/part?key=&uploadId=&part=      -> {etag}  (body = bytes)
 * - POST /v1/:lib/objects/multipart/complete {key, uploadId, parts:[{partNumber,etag}]} -> {key,size}
 * - POST /v1/:lib/objects/multipart/abort    {key, uploadId}       -> {ok:true}
 * - PUT  /v1/:lib/thumb?key=                 -> write META thumbnail (body = JPEG or WEBP bytes)
 * - POST /v1/:lib/objects/import  {url, prefix?}                   -> import media by URL
 * - POST /v1/:lib/ops/mkdir   {prefix}        -> create an empty folder marker (<prefix>/.keep)
 * - POST /v1/ops/copy   {from:{lib,key}, to:{lib,key}}   -> copy (same or cross library, no overwrite)
 * - POST /v1/ops/move   {from:{lib,key}, to:{lib,key}}   -> copy + verify + remove source (also used for rename)
 * - POST /v1/:lib/ops/trash   {key, duplicateOf?} -> move to .trash/<epoch ms>/<key> (kept 30 days);
 *                                                with duplicateOf, album memberships move to that key
 * - POST /v1/:lib/ops/restore {trashKey}      -> move a trashed object back to its original key
 * - GET  /v1/:lib/trash?cursor=               -> list trashed objects
 *
 * Album edits (libraries with readOnly !== true only; they rewrite META/.system/albums.json, the user albums
 * shared by all libraries, where each item is stamped with its lib):
 * - POST   /v1/:lib/albums                   {title, subtitle?}    -> {id,title}  (201)
 * - PATCH  /v1/:lib/albums/:id               {title?, subtitle?}   -> rename / retitle
 * - DELETE /v1/:lib/albums/:id                                     -> {ok:true}  (the album only, media stays)
 * - POST   /v1/:lib/albums/:id/items         {keys:[...]}          -> append media (max 500 per call)
 * - POST   /v1/:lib/albums/:id/items/remove  {keys:[...]}          -> drop media from the album
 * - POST   /v1/:lib/albums/:id/order         {items:[{key,lib}]}   -> reorder (must be the album's exact current set)
 * A daily cron permanently removes trash entries older than TRASH_RETENTION_DAYS (default 30).
 *
 * All /v1 API routes require `Authorization: Bearer <ACCESS_TOKEN>`.
 */

import { Hono } from "hono";

import type { Env } from "./lib/env";
import { bucketFor } from "./lib/env";
import { rebuildAllCatalogs } from "./lib/catalog";
import { ALLOWED_METHODS, corsHeaders, HttpError, isAuthorized, json } from "./lib/http";
import { purgeTrash } from "./lib/objects";
import { handleDuplicates, handleDuplicateScan, handleObjectsCheck } from "./routes/duplicates";
import { handleMedia } from "./routes/media";
import {
  handleAlbum,
  handleAlbums,
  handleFolders,
  handleLibraries,
  handleMeta,
  handleTrashListForLib,
} from "./routes/read";
import {
  handleCopyMove,
  handleImportRoute,
  handleLibOps,
  handleMultipartDone,
  handleMultipartInit,
  handleMultipartPart,
  handlePutObject,
  handleThumb,
  handleAlbumCreate,
  handleAlbumDelete,
  handleAlbumItemsAdd,
  handleAlbumItemsRemove,
  handleAlbumOrder,
  handleAlbumUpdate,
} from "./routes/write";

export type { Env } from "./lib/env";
export { forbiddenHost } from "./lib/import";

const app = new Hono<{ Bindings: Env }>();

app.onError((e) => {
  if (e instanceof HttpError) return json({ error: e.code }, e.status);
  console.error("unhandled", e instanceof Error ? e.message : String(e));
  return json(
    { error: "internal", detail: e instanceof Error ? `${e.name}: ${e.message}` : String(e) },
    500,
  );
});
app.notFound(() => json({ error: "not_found" }, 404));

// CORS preflight + method guard.
app.use("*", async (c, next) => {
  if (c.req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }
  if (!(ALLOWED_METHODS as readonly string[]).includes(c.req.method)) {
    return json({ error: "method" }, 405);
  }
  return next();
});

// Public routes: signed media/thumb and health — no bearer needed.
app.on(["GET", "HEAD", "POST", "PUT"], "/m/:lib/:key{.+}", (c) =>
  handleMedia(c.req.raw, c.env, "m", c.req.param("lib"), c.req.param("key"), new URL(c.req.url)),
);
app.on(["GET", "HEAD", "POST", "PUT"], "/t/:lib/:key{.+}", (c) =>
  handleMedia(c.req.raw, c.env, "t", c.req.param("lib"), c.req.param("key"), new URL(c.req.url)),
);
app.all("/", () => json({ ok: true }));
app.all("/health", () => json({ ok: true }));

// Everything under /v1 requires the bearer token.
const requireAuth = async (c: { req: { raw: Request }; env: Env }, next: () => Promise<void>) => {
  if (!isAuthorized(c.req.raw, c.env)) return json({ error: "unauthorized" }, 401);
  return next();
};
app.use("/v1", requireAuth);
app.use("/v1/*", requireAuth);

// 索引の作り直しを応答の後に回すための口。ExecutionContext が無い呼ばれ方（テストの直呼び等）
// では Hono が例外を投げるので、無い物として扱う
type WaitUntil = Pick<ExecutionContext, "waitUntil">;
const ctxOf = (c: { executionCtx: WaitUntil }): WaitUntil | undefined => {
  try {
    return c.executionCtx;
  } catch {
    return undefined;
  }
};

app.get("/v1/libraries", (c) => handleLibraries(c.env));
app.get("/v1/:lib/meta", (c) => handleMeta(c.env, c.req.param("lib"), new URL(c.req.url)));
app.get("/v1/:lib/trash", (c) =>
  handleTrashListForLib(c.env, c.req.param("lib"), new URL(c.req.url)),
);
app.get("/v1/:lib/albums", (c) =>
  handleAlbums(c.env, new URL(c.req.url).origin, c.req.param("lib")),
);
app.get("/v1/:lib/albums/:id", (c) =>
  handleAlbum(
    c.env,
    new URL(c.req.url).origin,
    c.req.param("lib"),
    c.req.param("id"),
    new URL(c.req.url),
    ctxOf(c),
  ),
);
app.post("/v1/:lib/albums", (c) => handleAlbumCreate(c.req.raw, c.env, c.req.param("lib")));
app.post("/v1/:lib/albums/:id/items", (c) =>
  handleAlbumItemsAdd(c.req.raw, c.env, c.req.param("lib"), c.req.param("id")),
);
app.post("/v1/:lib/albums/:id/items/remove", (c) =>
  handleAlbumItemsRemove(c.req.raw, c.env, c.req.param("lib"), c.req.param("id")),
);
app.post("/v1/:lib/albums/:id/order", (c) =>
  handleAlbumOrder(c.req.raw, c.env, c.req.param("lib"), c.req.param("id")),
);
app.patch("/v1/:lib/albums/:id", (c) =>
  handleAlbumUpdate(c.req.raw, c.env, c.req.param("lib"), c.req.param("id")),
);
app.delete("/v1/:lib/albums/:id", (c) =>
  handleAlbumDelete(c.env, c.req.param("lib"), c.req.param("id")),
);
app.get("/v1/:lib/folders", (c) => {
  const url = new URL(c.req.url);
  const target = bucketFor(c.env, c.req.param("lib"));
  if (!target) return json({ error: "unknown_library" }, 404);
  return handleFolders(c.env, url.origin, target.lib.id, target.bucket, url, ctxOf(c));
});
app.get("/v1/:lib/duplicates", (c) => {
  const url = new URL(c.req.url);
  return handleDuplicates(c.env, url.origin, c.req.param("lib"), url, ctxOf(c));
});
app.post("/v1/:lib/duplicates/scan", (c) =>
  handleDuplicateScan(c.env, c.req.param("lib"), ctxOf(c)),
);
app.post("/v1/:lib/objects/check", (c) =>
  handleObjectsCheck(c.req.raw, c.env, new URL(c.req.url).origin, c.req.param("lib"), ctxOf(c)),
);

app.put("/v1/:lib/objects", (c) =>
  handlePutObject(c.req.raw, c.env, c.req.param("lib"), new URL(c.req.url), ctxOf(c)),
);
app.post("/v1/:lib/objects/multipart", (c) =>
  handleMultipartInit(c.req.raw, c.env, c.req.param("lib"), ctxOf(c)),
);
app.put("/v1/:lib/objects/multipart/part", (c) =>
  handleMultipartPart(c.req.raw, c.env, c.req.param("lib"), new URL(c.req.url)),
);
app.post("/v1/:lib/objects/multipart/complete", (c) =>
  handleMultipartDone(c.req.raw, c.env, c.req.param("lib"), "complete", ctxOf(c)),
);
app.post("/v1/:lib/objects/multipart/abort", (c) =>
  handleMultipartDone(c.req.raw, c.env, c.req.param("lib"), "abort", ctxOf(c)),
);
app.put("/v1/:lib/thumb", (c) =>
  handleThumb(c.req.raw, c.env, c.req.param("lib"), new URL(c.req.url)),
);
app.post("/v1/:lib/objects/import", (c) => handleImportRoute(c.req.raw, c.env, c.req.param("lib")));
app.post("/v1/ops/copy", (c) => handleCopyMove(c.req.raw, c.env, "copy"));
app.post("/v1/ops/move", (c) => handleCopyMove(c.req.raw, c.env, "move"));
app.post("/v1/:lib/ops/:action{mkdir|trash|restore}", (c) =>
  handleLibOps(c.req.raw, c.env, c.req.param("lib"), c.req.param("action")),
);

export default {
  fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> | Response {
    return app.fetch(req, env, ctx);
  },
  async scheduled(_event: ScheduledController, env: Env): Promise<void> {
    try {
      const removed = await purgeTrash(env);
      console.log("trash purge", removed);
    } catch (e) {
      // ゴミ箱の掃除が落ちても、索引の作り直しは走らせる（落ちたままだと索引が古いまま残る）
      console.error("trash_purge_failed", e);
    }
    // Worker を通らずに R2 へ置かれた物を拾い、溜まった追記を畳む
    await rebuildAllCatalogs(env);
  },
} satisfies ExportedHandler<Env>;
