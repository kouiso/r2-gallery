# 手元の Worker に対する確認（test_live）

`flutter/test/` のテストは fake API で画面を見る。ここは**本物の Worker**（`wrangler dev --local`）に対して、
本物の画面と `ApiClient` を通す確認を置く。`flutter test` を引数なしで流しても拾わない（`test/` しか見ない）。

## live_trash_test.dart — 複数選択→ゴミ箱

- 書けるライブラリ `a`: 4枚を長押し→すべて選択→ゴミ箱へ。Worker の一覧から消え `.trash/` に4件入ること、
  「元に戻す」で4件が元のキーに戻りゴミ箱が空になることを、Worker 側を読み直して確かめる。
- 読み取り専用ライブラリ `b`: 選択（オフライン保存用）には入るが「ゴミ箱へ」「アルバムへ」が出ないこと、
  API で直接 `POST /v1/b/ops/trash` を送っても 403 で中身が残ることを確かめる。

## 流し方（リポジトリのルートで）

```bash
pnpm install
# 1. Worker を立てる（状態は .work/ に置く。.work/ は git に入らない）
(cd worker && npx wrangler dev --local --port 8787 -c wrangler.live-trash.toml --persist-to ../.work/live-trash) &

# 2. 読み取り専用ライブラリには API で置けないので、wrangler で直接入れる
node -e "require('fs').writeFileSync('.work/p.png', Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==','base64'))"
for k in ro/p0.png ro/p1.png; do
  (cd worker && npx wrangler r2 object put "live-b/$k" --file ../.work/p.png --local --persist-to ../.work/live-trash -c wrangler.live-trash.toml)
done

# 3. 流す（書けるライブラリ a の4枚はテストが自分で置く）
cd flutter && flutter test test_live/live_trash_test.dart
```

接続先とトークンは `--dart-define=LIVE_ENDPOINT=... --dart-define=LIVE_TOKEN=...` で変えられる。
**本番の Worker には向けない**（ゴミ箱へ送って戻すので、本物の写真を動かす）。

結果の記録: `doc/evidence/r2-4-bulk-trash-live/README.md`
