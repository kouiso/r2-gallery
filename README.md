# R2 Gallery

A small, private media viewer built with Flutter (Android + web), backed by a
Cloudflare Worker in front of one or more R2 buckets.

## Features

- Grid browsing with recent-first order, folder (prefix) browsing, multiple libraries
- Albums, fullscreen viewer, video player with double-tap ±10s seek
- Multi-select trash / restore; trash purged by a daily cron after 30 days
- PIN lock, `r2g://setup` one-tap pairing link
- Upload via file picker (multipart for large files), client-side thumbnail backfill
- No storage credentials in the app: the Worker returns short-lived HMAC-signed media URLs

## Layout

```
flutter/     Flutter client (Android APK via FAD, web build via Cloudflare Pages)
worker/      Cloudflare Worker (API + signed media URLs)
tools/       ops scripts (index-upload, app-distribute, pairing-url)
```

## App

```sh
cd flutter
flutter pub get
flutter build apk --release    # release APK for FAD
flutter build web --release    # web build for Pages (deployed via pages-dist)
```

## Worker

```sh
cp worker/wrangler.example.toml worker/wrangler.toml   # git-ignored; fill in names
cd worker
npx wrangler secret put ACCESS_TOKEN
npx wrangler secret put SIGNING_SECRET
npx wrangler deploy
```

### Index format

Albums are read from `META/.system/index-<library id>.json`:

```json
{
  "version": 1,
  "generatedAt": "2026-01-01T00:00:00Z",
  "items": [{ "key": "path/to/item.jpg" }],
  "albums": [
    {
      "id": "album-1",
      "title": "Album 1",
      "cover": "path/to/cover.jpg",
      "items": [{ "key": "path/to/item.jpg", "note": "free text", "createdAt": 1700000000000 }]
    }
  ]
}
```

`items` (optional) is a flat list of every media object in the library; entries that no album
claims are shown in a built-in `その他` album. When `items` is omitted, that album is hidden.
The album id `__other__` is reserved for that album and must not be declared.

Optional thumbnails are read from `META/.system/thumbs/<library id>/<key>.webp`; when missing the
original object is served. Index files and thumbnails are produced by your own tooling and are
never committed to this repository.

### Index uploader

`tools/index-upload.mjs` validates an index JSON, renders WebP thumbnails from a local media
mirror, and uploads both to the META bucket via `wrangler` (operator credentials, run locally):

```sh
pnpm tools:index-upload --index ./index.json --lib <library id> --meta-bucket <meta bucket> \
  --media-root ./media --video-thumbs
# --dry-run prints the plan without uploading
```

Thumbnails land at `.system/thumbs/<library id>/<key>.webp`; the index lands at
`.system/index-<library id>.json`. Existing library objects are never modified.

### Pre-publication hygiene check

`tools/leak-check.mjs` scans tracked files and the history of the checked-out ref
(HEAD) for forbidden file types (service-account JSON, `wrangler.toml`, `.env`,
keystores, index data), non-noreply commit emails, and an operator-supplied
forbidden-word list. Other branches are checked when CI checks their own head.
Commits already published on `main` with a personal email are listed by hash in
`tools/leak-check-allow-commits.txt`; only those commits are exempt:

```sh
pnpm leak:check
QN_FORBIDDEN_WORDS_FILE=~/forbidden-words.txt pnpm leak:check   # or QN_FORBIDDEN_WORDS=a,b,c
```

The forbidden-word list is never committed. In CI (`.github/workflows/ci.yml`) it is
injected from the `QN_FORBIDDEN_WORDS` repository secret.

## Release build & distribution

The app's version lives in `flutter/pubspec.yaml` (`version: x.y.z+code`) and mirrors
`package.json`'s `version` — `tools/app-distribute.test.mjs` enforces the sync.

App Distribution upload is fully environment-driven — no identifiers, keys,
or project IDs live in this repository:

```sh
export FIREBASE_APP_ID=...   # operator console value
export FIREBASE_TOKEN=...    # or GOOGLE_APPLICATION_CREDENTIALS
tools/app-distribute.sh      # Flutter release APK → build (if needed) + upload via firebase-tools
```

Recipients are restricted to the owner: `QN_TESTERS` must only contain addresses in the
script's `ALLOWED_TESTERS` (pinned by `tools/app-distribute.test.mjs`), and `QN_GROUPS`
is refused because group membership cannot be checked here. The FAD tester list itself
is watched daily by the operator-managed `fad-testers-watch` lane.

## License

MIT
