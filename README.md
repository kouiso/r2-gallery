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

## 手元で動かす

`worker/wrangler.toml` は git 管理の外なので、手元ではテスト用の設定 `worker/wrangler.test.toml`
（ローカルの R2 / D1 だけを使い、実バケットや本番の秘密は参照しない）で Worker を起動する。

```sh
pnpm install
# リポジトリのルートで実行する（lockfile で固定した wrangler と hono はルートの node_modules にある）。
# 旧来の `cd worker && npx wrangler dev` は worker/wrangler.toml が git 管理外で無いため、そのままでは起動しない
pnpm exec wrangler dev --local --port 8787 \
  --config worker/wrangler.test.toml --persist-to worker/.wrangler/state
curl http://127.0.0.1:8787/health   # {"ok":true}
```

- 仮のトークン: `ACCESS_TOKEN = test-access-token`（`worker/wrangler.test.toml`）。API は
  `Authorization: Bearer test-access-token` で呼ぶ。ライブラリは `a`（書き込み可）と `b`（読み取り専用）。
- Maestro 用の設定は `.maestro/wrangler.maestro.toml`（トークン `live-token`）。`.maestro/prepare.sh` が
  `worker/` に写して起動する。
- 永続先 `worker/.wrangler/` は git 管理外。消せば空の状態に戻る。
- 確認用の画像は PUT で入れる（キーには拡張子が要る）:

```sh
TOKEN=test-access-token
curl -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: image/jpeg" \
  --data-binary @photo.jpg "http://127.0.0.1:8787/v1/a/objects?key=photo.jpg"
```

### アプリから手元の Worker につなぐ

接続画面（手入力・`r2g://setup` リンク）は `https://` で始まる接続先しか受け付けないので、手元の
`http://` の Worker にはつなげない。つなぐには、ビルド時に接続先とトークンを焼き込む:

```sh
cd flutter
flutter pub get
flutter build web --release \
  --dart-define=R2_BAKED_ENDPOINT=http://127.0.0.1:8787 \
  --dart-define=R2_BAKED_TOKEN=test-access-token
python3 -m http.server 8080 --directory build/web   # http://localhost:8080 を開く
```

- 前提: 焼き込み値が使われるのは、ブラウザに保存済みの接続が無い時だけ（保存済みの接続が先に使われる。
  `flutter/lib/src/state/app_state.dart` の `_initOnce`）。同じオリジンで前に別の接続先やトークンでつないでいた場合は、
  サイトデータを消すか、新しいプロファイルで開く。
- 焼き込み値は起動時に `/v1/libraries` を呼んで確かめ、通れば保存して一覧へ進む。通らなければ接続画面に戻る。
- Worker 側の CORS は全オリジンを許すので、Web 版を別ポートで配ってもつながる。
- Android のエミュレータでは `adb reverse tcp:8787 tcp:8787` で端末の `127.0.0.1:8787` に見せ、
  同じ `--dart-define` で `flutter build apk --release` する。`http` はリリース版では既定で禁止なので、
  確認用 APK だけ manifest に `android:usesCleartextTraffic="true"` を足す手順を
  `.github/workflows/maestro.yml` が取っている。この APK は配らない。
- 焼き込んだビルドにはトークンが入る。成果物を公開・配布しない（Pages や FAD には載せない）。
- 手元の `http` を接続画面で許すかどうかは未決定。許すと決まったら、その変更の PR でこの節を書き直す。

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
