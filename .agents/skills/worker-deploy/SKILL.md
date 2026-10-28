---
name: worker-deploy
description: Deploy worker/ to the notes-sync Cloudflare Worker without wrangler credentials — esbuild bundle + multipart PUT through the authenticated cloudflare-unified-mcp execute tool.
---

# Worker deploy (notes-sync)

`wrangler deploy` needs an interactive login. When credentials are unavailable, deploy through
the org's authenticated `cloudflare-unified-mcp` `execute` tool instead.

1. Bundle: `cd worker && pnpm dlx esbuild src/index.ts --bundle --minify --format=esm --target=es2022 --outfile=/tmp/ns-min.js`
   (Hono + deps bundle cleanly; module format, `main_module` = `worker.js`.)
2. Build a multipart body by hand as a STRING (FormData does NOT work — it gets serialized to
   JSON → error 10001):
   - part `metadata` (`application/json`): `{main_module, compatibility_date, bindings[]}`
   - part `worker.js` (`application/javascript+module`): the bundle.
3. `cloudflare.request({method:"PUT", path:"/accounts/{account_id}/workers/scripts/notes-sync",
   body:<string>, contentType:"multipart/form-data; boundary=<b>", rawBody:true})`.
4. Preserve the existing bindings verbatim — do NOT retype them: before deploy, fetch
   `GET /accounts/{aid}/workers/scripts/notes-sync/settings` and reuse the returned
   `bindings[]` (R2 `LIB_P`/`LIB_R`/`META`, D1 `REVIEW_DB`, plain_text `LIBRARIES`,
   `REVIEW_LIBS`, `TRASH_RETENTION_DAYS`, `URL_TTL_SECONDS`) in the metadata, minus
   the `secret_text` entries. Bucket names never enter the repo — read them from the
   live settings, not from memory or docs.
5. Secrets `ACCESS_TOKEN`/`SIGNING_SECRET` are `secret_text`: omit them from metadata — they
   persist. Supplying them REQUIRES a value every deploy.
6. Verify live: `curl -H "Authorization: Bearer $TOK" https://notes-sync.kouiso.workers.dev/v1/personal/folders?order=recent`
   (token: 1Password `磯貝プライベート共有` → "R2 Gallery worker (notes-sync)" → `access_token`).

Account id: `6e206506efda3871a2d6e81da38b4b0b`. Cron `17 3 * * *` (trash purge) is unaffected.
