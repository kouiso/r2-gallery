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

Flutter の版は `flutter/.flutter-version` に固定する（CI・Devin 設定・この文書は
その1か所を指す）。mise なら `mise use flutter@$(cat flutter/.flutter-version)`。

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

### Listing catalog

Sorted listings (`GET /v1/:lib/folders?sort=…`, i.e. what the app's photo grid asks for) are served
from a catalog instead of enumerating the bucket on every request — R2 can only list in key order,
so sorting by date/size/name needs every object, and at tens of thousands of objects that is dozens
of `list` calls per page.

- `META/.system/catalog/<library id>.json` — snapshot of every key in the library
  (`{ version: 1, startedAt, items: [[key, size, uploadedMs, etag, hasThumb]] }`).
- `META/.system/catalog/<library id>/j/<ms>-<uuid>.json` — one small journal entry per write made
  through the Worker (`{ put?, del?, thumb?, unthumb? }`), applied on top of the snapshot.

Writes through the Worker are therefore visible on the next request. Objects written **directly to
R2** (pipelines, `tools/index-upload.mjs`) appear after the next rebuild: the snapshot is rebuilt in
the background once it is older than `CATALOG_MAX_AGE_SECONDS` (default 300), by the daily cron, and
immediately when the app pulls to refresh (`fresh=1`). `CATALOG_MAX_AGE_SECONDS = "0"` rebuilds on
every request (the pre-catalog behaviour; slow on large libraries, useful as an escape hatch).
Both files are derived data: deleting them only costs one rebuild.

### Content hashes (duplicate detection)

`META/.system/hashes-<library id>.json` records SHA-256 digests used to find byte-identical media:

```json
{ "version": 1, "items": { "path/to/item.jpg": { "size": 12345, "etag": "…", "sha256": "…" } } }
```

Only the Worker writes it — digests it computed itself, or that R2 verified on upload
(`x-content-sha256` on `PUT /v1/:lib/objects`). A record counts only while the object still has the
same `etag`. Digests are computed lazily, only for objects that share a byte size with another one
(`POST /v1/:lib/duplicates/scan`, bounded by `DUP_SCAN_BYTES` and `DUP_SCAN_OBJECTS` per call; objects above
`DUP_MAX_OBJECT_BYTES` are skipped). `GET /v1/:lib/duplicates` returns the groups,
`POST /v1/:lib/objects/check` answers "is this already stored?" before an upload, and
`POST /v1/:lib/ops/trash` with `duplicateOf` moves album memberships to the copy that is kept.

### 見た目の照合（似ている写真）

設定タブの「重複・似ている写真を探す」は、上の SHA-256（中身がバイト単位で同じ物）に加えて、
再保存・縮小・形式違い・明るさ違いの「ほぼ同じ」写真、左右反転、見た目が近いだけの「似ている」写真をまとめる。
Worker は画素を読まない（wasm も、課金のある Cloudflare Images も使わない）。署名はアプリか PC ツールが、
保存済みの 512px サムネから作って送る。

**署名 "vs1"**（基準の実装は `worker/src/lib/similar/core.ts`、Dart への移植は
`flutter/lib/src/duplicates/visual_signature.dart`。両方が同じ正解値 V1〜V4 をテストで持つ）

- 入力は EXIF の向きを直した RGBA。白の上に合成し、輝度を整数で求め、32×32・9×8・16×16 の輝度の格子と
  2×2 の色を作る。デコードの後は全部整数の計算なので、Android・Web・Node で 1 bit も違わない。
- 297 バイト（base64url で 396 文字）: pHash（DCT、8 バイト）・dHash（8 バイト）・左右反転の pHash（8 バイト）・
  16×16 の輝度（256 バイト）・2×2 の色（12 バイト）・サムネの幅と高さ・印（単色 / 原本から作った / 先頭の 1 コマだけ）。
- 画像だけ（`IMAGE_EXT`）。動画は見た目では比べず、中身が同じ時だけ SHA-256 でまとまる。

**判定**（しきい値は `PARAMS`（版 `"p1"`）としてコードに置く。env では変えない。PC ツールの報告とサーバーが同じ値で判定するため）

| 札 | 画面の文字 | 条件 |
|---|---|---|
| `identical` | 同じファイル | SHA-256 が同じ（他の条件より先に決まる） |
| `same` | ほぼ同じ | pHash 差 ≤4・dHash 差 ≤6・縦横比の差 ≤0.02・16×16 の輝度差（明るさのずれを除いて）最大 ≤12・合計 ≤768・色差 ≤20 |
| `same` + `variant` | 差分かも | `same` のうち、両方の原本の寸法と拡張子が同じで、輝度差の最大が 3 を超える物 |
| `mirror` | 反転 | 反転した pHash と格子・色で `same` と同じ条件を満たす物 |
| `similar` | 似ている | pHash 差 ≤10・dHash 差 ≤12・縦横比の差 ≤0.10・色差 ≤48 |

- 単色に近い画像（輝度の標準偏差 < 6）は見た目では比べない。
- 束ね方は連鎖しない先頭決め（A〜B、B〜C でも A≁C なら C は別の組）。候補は pHash を 16 bit ずつ 4 つに割った
  多重索引で引く（距離 11 以下は総当たりと同じ結果）。辺を先に全部は作らず、頭ごとにその場で引くので、近い物が
  数千枚かたまっていても作業と記憶は枚数に比例する。1 つの頭が取るのは、まだどの組にも入っていない相手のうち
  近い順（段の中の種類 → その種類の距離。反転は反転 pHash）に 64 件まで（相手を残した頭は `crowded` に数える）。
  取れる相手が残らなかった物も、既にできた組の頭と直接合えば、その組へ 64 件まで足す（連写が 64 枚を超えても
  どの 1 枚も組から漏れない）。
- 段ごとに束ねる。先に重複の段（同じファイル・ほぼ同じ・反転の辺だけ）、次に似ている段（似ているの辺だけ）。
  重複の組に入った物は似ている段では頭にも一員にもならず、重複の組の頭は似ている段で他の頭に取られない
  （似ているの弱い辺で先に取られて、本当の「ほぼ同じ」の相手の組が消えないように。同じ物を 2 つの組で別の
  オリジナルに向けて消させないように）。
- 中身が同じ物の集まりは 1 つの節で、組の中では必ず全部が「すべての重複」で選べる形で出る。別の頭に取られるのは
  「ほぼ同じ」（差分かもでない）の時だけで、反転・似ている・差分かもになる時は取られず、集まりが自分の組
  （一番古い物がオリジナル、ほかは同じファイル）になる。集まりの署名は古い順で最初の単色でない物、寸法は分かって
  いる一員の物で、一覧・ゴミ箱・付け直しで同じ物を使う（古い写しに署名が無くても、一覧どおりに消せる）。
- 残す物（オリジナル）は、原本の画素数が大きい → PNG → バイト数が大きい → 古い → キーの順。中身が同じ組の中では
  一番古い物（従来の重複の画面と同じ）。

**置き場**

- `META/.system/similar/<library id>/<NN>.json`（`NN = fnv1a32(key) % 32` の 32 ファイル）:
  `{ version: 1, alg: "vs1", items: { "<key>": [etag, sigB64, "t"|"o", ow, oh] | [etag, null, "decode"|"too_large"] } }`。
  `ow`・`oh` は署名を受け取る時に Worker が原本の先頭 64 KB から読む寸法（JPEG の SOF と EXIF の向き、PNG、WebP、GIF、BMP）。
- 記録は、一覧（catalog）に同じ etag の行がある間だけ有効。中身が変わると作り直しになる。ゴミ箱へ送っても消さない
  （単一パートの物は戻しても etag が変わらず、そのまま有効に戻る）。書くたびに、一覧に無い・etag の合わない記録を落とす。
- 5 万枚で JSON は約 25 MB。消せば次に画面を開いた時に作り直すだけの派生データ。

**API**（どれも Bearer トークンが要る）

| 呼び出し | 中身 |
|---|---|
| `GET /v1/:lib/similar/status` | 画像数・署名済み・失敗・単色・残り（サムネの有無別）・残りの通信量の見積もり、1 回に受ける件数（`sigBatch`・`trashBatch`） |
| `GET /v1/:lib/similar/todo?shard=0..31&after=&limit≤300` | 署名の無い画像を置き場ごとにキーの順で返す |
| `POST /v1/:lib/similar/signatures` | 署名か失敗の印を 200 件まで受け取る。方式違いは 409 `alg_mismatch`、etag 違いは `stale` と数えて置かない。読み取り専用のライブラリでも受け付ける（書くのは META だけ） |
| `GET /v1/:lib/similar?tab=dup\|similar&cursor=&limit≤100` | 重複の段（同じファイル・ほぼ同じ・反転）と似ている段の組。1 組 60 枚まで（残りは `more`）。カーソルは「この組より後」なので、消しても続きがずれない |
| `POST /v1/:lib/similar/relabel` | 利用者が選び直したオリジナルに対して、組の各員の札を付け直す |
| `POST /v1/:lib/similar/trash` | 40 件までまとめてゴミ箱へ。サーバーが中身・署名で確かめ直し、合わない物は `not_similar` / `stale_signature` で動かさない。アルバムでは消した物の場所にオリジナルが入る（アルバムの書き込みは 1 回）。書き込めるライブラリだけ（読み取り専用は 403） |
| `POST /v1/:lib/similar/undo` | 直後の「元に戻す」用。消す前のアルバムにそのまま戻し、消した時に入れたオリジナルも外す |

- ゴミ箱の画面から 1 件戻す時（`/ops/restore`）は従来どおり。「同じファイル」として消した物は、オリジナルが残っている
  アルバムへは戻らない。それ以外は元の位置へ戻り、オリジナルも残る（その分アルバムの枚数が増える）。
- 予算: 署名の POST は 200 件で原本の先頭読み約 200 回と、触れた置き場ごとの読み書き 2 回（置き場は 2 つずつ書き直す）。
  まとめてゴミ箱は 1 件約 12 回（40 件で約 500 回。同じアルバムから何百件消しても、前の回の跡 1 回ぶんにつき list 1 回しか
  増えない）。どちらも 1 リクエストの外部呼び出しの上限 1000 回に収まるよう、件数の上限は設定で上げられない。
- 設定（任意。`worker/wrangler.example.toml` に注記あり）: `SIMILAR_MAX_NODES`（既定 50000。超えると
  `GET /similar` は 413 `too_many_for_similar`。束ねる途中の記憶が 5 万件で約 75 MB、10 万件で isolate の上限 128 MB を
  超えるため）、`SIMILAR_SIG_BATCH`（既定・最大 200）、`SIMILAR_TRASH_BATCH`（既定・最大 40）。
  下げた値は `/similar/status` の `sigBatch`・`trashBatch` でアプリに伝わり、アプリはその件数で分けて送る
  （その値を返さない Worker には、アプリの上限 200 / 40 で送る）。
- 見た目の照合に対応していない古い Worker（`/similar/status` が 404）と、`GET /similar` が 413 `too_many_for_similar` の
  ライブラリでは、アプリは従来の重複の画面を出す。一覧の口だけが落ちた時（CPU の上限など）も、エラーの画面の
  「同じファイルだけを探す」で従来の画面へ移れる。
- 移動が途中で止まった時（写しは置けたのに元を消せなかった、など）は、物の在り処で決め直す。消す時は元が残って
  いればこの回の写しをゴミ箱から消して `move_failed`、戻す時（`/similar/undo`・`/ops/restore`）は元の key に
  中身が同じ写し（大きさと etag が同じ）があれば戻ったとしてゴミ箱側を消す。複数パートで写した 96 MiB 以上の物は
  etag が変わるので、やり直しで中身が同じとは言えず、従来どおり 409 になる。
- 同じアルバムで 2 回に分けて消した時、アルバムに入れたオリジナルが誰の代わりかを `albums.json` のアルバムに
  控える（`keeperFor`）。直後の「元に戻す」がオリジナルを外すのは、代わっていた物が全部戻った時だけ。

**署名を作る所**

- Android アプリ: 保存済みサムネは端末の置き場から先に読む。サムネの無い物は原本を落として 512px JPEG を作り、
  書けるライブラリならそれをサムネとして置いてから、同じバイト列で署名する。残りが 300 件を超えると、通信量を見せて
  同意を待つ。画面を離れると止まり、次は続きから。
- Web 版: 保存済みサムネのある物だけ（`ui.ImageDescriptor` が使えないため `package:image` で読む）。サムネの無い物は
  「この端末では照合できない物」と出して、Android か PC に任せる。
- PC ツール `tools/similar-signatures.mjs`（`core.ts` を Node の型除去でそのまま読む。sharp でデコードする）:

```sh
# 読み取り専用の報告（本番にも向けられる）。.work/similar-report/<id>/ に stats.json と report.html だけを書く
R2G_ENDPOINT=https://... R2G_TOKEN=... node tools/similar-signatures.mjs report --lib <id> --probe-dims [--include-originals]
node tools/similar-signatures.mjs --score labels.json   # report.html で付けたラベルから札ごとの適合率を出す
node tools/similar-signatures.mjs --purge --lib <id>    # 報告を消す
# 署名を作ってサーバーへ送る（アプリより速い）
R2G_ENDPOINT=... R2G_TOKEN=... node tools/similar-signatures.mjs write --lib <id> [--check-expected <file>]
```

  `R2G_ENDPOINT` と `R2G_TOKEN` は表示も保存もしない。report.html には実際の写真の縮小が入るので、commit・
  アップロード・公開をしない。合成画像だけで手元で通す手順は `tools/similar-fixture-seed.mjs`（127.0.0.1 / localhost
  以外には送らない）と `doc/evidence/similar-local/README.md` にある。

**見つけられない物・限界**

- 3〜5% を超える切り抜き、90°/180° の回転、上下反転、枠や帯の追加、強い色変え・フィルター、コラージュ、
  同じキャラクターの別の絵は見つけない（局所特徴や埋め込みが要る。次の段階）。
- 動画はバイト単位で同じ時だけ。
- 32px の格子 1 マスより小さい描き足しは「ほぼ同じ」になり得る。原本の寸法が先頭 64 KB で読めない時は「差分かも」の
  印が付かない。確かめの画面の種類ごとの件数、30 日のゴミ箱、直後の「元に戻す」で取り返せるようにしている。
- サムネの作り手（端末の JPEG、PC の WebP、`package:image`）の違いで数 bit 揺れる。透過 PNG は、黒の上に平らにした
  端末のサムネと白の上に合成した署名とで食い違うことがある。
- 端末・Web・PC で 1 bit も違わないのは、同じ画素（デコードした後の RGBA）から作った時だけ。同じファイルでも
  デコーダが違う（アプリは `package:image`、PC ツールは sharp の libjpeg-turbo / libwebp）と JPEG・WebP では画素が
  少し違い、手元の比べでは pHash 差 2・dHash 差 3・輝度差の最大 2 まで揺れた（PNG は同じ）。札はどれも「ほぼ同じ」の
  ままだったが、差分かもの境（輝度差の最大 > 3）の余裕をこの揺れが食うので、PC ツールの報告での調整は、
  アプリが作った署名との揺れを見込んで余裕を残す（ship の条件の「輝度差の最大 ≤8」に締める時も同じ）。
- しきい値は imagehash / imagededup の慣習から取った物で、持ち主が実際のライブラリの報告にラベルを付けて
  「ほぼ同じ」の適合率 98% 以上を確かめるまで調整していない。
- 新しく上げた物はアップロード時には署名しない。次に画面を開いた時に差分だけ作る。
- 束ねる計算は `GET /similar` の度に 32 の置き場を読む（isolate に etag で控える）。5 万枚の冷えた状態で CPU 1〜3 秒の見積もりで、
  デプロイ後に `wrangler tail` で確かめる。

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
