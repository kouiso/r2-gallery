/**
 * Private image storage viewer API.
 *
 * A "library" is one R2 bucket. Libraries are declared in the LIBRARIES var.
 *
 * - GET /v1/libraries                         -> configured libraries
 * - GET /v1/:lib/albums                       -> album list (from META/.system/index-<lib>.json)
 * - GET /v1/:lib/albums/:id?cursor=&limit=    -> items in an album, with signed media URLs
 * - GET /v1/:lib/folders?prefix=&cursor=      -> raw folder browsing of the library bucket
 * - GET /v1/:lib/meta?key=                    -> review metadata joined from D1 (REVIEW_LIBS only)
 * - GET /m/:lib/<key>?e=&s=                   -> original object (signed, no bearer needed)
 * - GET /t/:lib/<key>?e=&s=                   -> thumbnail from META/.system/thumbs/<lib>/ (falls back to original)
 *
 * Write operations (libraries with readOnly !== true only):
 * - PUT  /v1/:lib/objects?key=               -> upload a small object (body = bytes; refuses to overwrite)
 * - POST /v1/:lib/objects/multipart          {key, contentType}    -> {uploadId}
 * - PUT  /v1/:lib/objects/multipart/part?key=&uploadId=&part=      -> {etag}  (body = bytes)
 * - POST /v1/:lib/objects/multipart/complete {key, uploadId, parts:[{partNumber,etag}]} -> {key,size}
 * - POST /v1/:lib/objects/multipart/abort    {key, uploadId}       -> {ok:true}
 * - PUT  /v1/:lib/thumb?key=                 -> write META thumbnail (body = JPEG or WEBP bytes)
 * - POST /v1/:lib/objects/import  {url, prefix?}                   -> import media by URL
 * - POST /v1/:lib/ops/mkdir   {prefix}        -> create an empty folder marker (<prefix>/.keep)
 * - POST /v1/ops/copy   {from:{lib,key}, to:{lib,key}}   -> copy (same or cross library, no overwrite)
 * - POST /v1/ops/move   {from:{lib,key}, to:{lib,key}}   -> copy + verify + remove source (also used for rename)
 * - POST /v1/:lib/ops/trash   {key}           -> move to .trash/<epoch ms>/<key> (kept 30 days)
 * - POST /v1/:lib/ops/restore {trashKey}      -> move a trashed object back to its original key
 * - GET  /v1/:lib/trash?cursor=               -> list trashed objects
 * A daily cron permanently removes trash entries older than TRASH_RETENTION_DAYS (default 30).
 *
 * All API routes require `Authorization: Bearer <ACCESS_TOKEN>`.
 */

import { Hono } from "hono";

import type { Env } from "./lib/env";
import { bucketFor } from "./lib/env";
import { corsHeaders, HttpError, isAuthorized, json } from "./lib/http";
import { purgeTrash } from "./lib/objects";
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
  if (!["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].includes(c.req.method)) {
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
  return handleFolders(c.env, url.origin, target.lib.id, target.bucket, url);
});

app.put("/v1/:lib/objects", (c) =>
  handlePutObject(c.req.raw, c.env, c.req.param("lib"), new URL(c.req.url)),
);
app.post("/v1/:lib/objects/multipart", (c) =>
  handleMultipartInit(c.req.raw, c.env, c.req.param("lib")),
);
app.put("/v1/:lib/objects/multipart/part", (c) =>
  handleMultipartPart(c.req.raw, c.env, c.req.param("lib"), new URL(c.req.url)),
);
app.post("/v1/:lib/objects/multipart/complete", (c) =>
  handleMultipartDone(c.req.raw, c.env, c.req.param("lib"), "complete"),
);
app.post("/v1/:lib/objects/multipart/abort", (c) =>
  handleMultipartDone(c.req.raw, c.env, c.req.param("lib"), "abort"),
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
    const removed = await purgeTrash(env);
    console.log("trash purge", removed);
  },
} satisfies ExportedHandler<Env>;
