# 手元の Worker に対する確認（test_live）

`flutter/test/` のテストは fake API で画面を見る。ここは**本物の Worker**（`wrangler dev --local`）に対して、
本物の画面と `ApiClient` を通す確認を置く。`flutter test` を引数なしで流しても拾わない（`test/` しか見ない）。

## live_trash_test.dart — 複数選択→ゴミ箱

- 書けるライブラリ `a`: 4枚を長押し→すべて選択→ゴミ箱へ。Worker の一覧から消え `.trash/` に4件入ること、
  「元に戻す」で4件が元のキーに戻りゴミ箱が空になることを、Worker 側を読み直して確かめる。
- 読み取り専用ライブラリ `b`: 選択（オフライン保存用）には入るが「ゴミ箱へ」「アルバムへ」が出ないこと、
  API で直接 `POST /v1/b/ops/trash` を送っても 403 で中身が残ることを確かめる。

## live_conflict_test.dart — 同名への書き込みは 409

転送キューは、再開時の 409 を「サーバーの物と手元の中身を照合する」合図として使う（#121）。その前提を本物の Worker で確かめる。
単発 PUT・multipart の開始・multipart の完了（別の upload が先に完了した場合と、完了済みの uploadId を
もう一度完了する場合＝応答が落ちた再開）が、どれも 409 になること。

```bash
(cd worker && npx wrangler dev --local --port 8799 -c wrangler.live-trash.toml --persist-to ../.work/live-conflict) &
cd flutter && flutter test test_live/live_conflict_test.dart --dart-define=LIVE_ENDPOINT=http://127.0.0.1:8799
```

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

## live_similar_test.dart — 重複・似ている写真（見た目の照合）

`tools/similar-fixture-seed.mjs` が合成画像（図形とグラデーションだけ）を種まきした手元の Worker に対して、
本物の `ApiClient` と画面と同じ `SimilarController` を通す。PC ツールの sharp の署名は Dart では流し込めないので、
署名は本物の取得経路（`ApiSignatureSource`、Android と同じ: サムネのある物は保存済みサムネ、無い物は原本から
`makeImageThumb` で作って PUT し直してから）と `vs1FromEncoded` で作る。

- 書けるライブラリ `a`: 中身（SHA-256）を数え切り、署名を補って pending が 0 になること、サムネの無かった物に
  サムネが置かれること、`GET /similar` の組が `expected.json` の期待どおりで、`/duplicates` の組がどれも重複の段に
  「同じファイル」で入ること。
- 「すべての重複」は全ページを読んでから、同じファイルとほぼ同じ（差分かもではない）物だけを選び、オリジナルと
  似ている段には触らないこと。まとめてゴミ箱へ送ると、ゴミ箱に選んだ物がちょうど入り、アルバムでは消した物の場所に
  オリジナルが入ること。
- 直後の「元に戻す」（`POST /similar/undo`）で、項目が元のキーに戻り、アルバムが消す前と同じ並びに戻る（入れた
  オリジナルも外れる）こと。開き直した時と同じく照合をやり直すと、消す前と同じ組に戻ること
  （`wrangler.test.toml` は分割コピーの下限が 64 バイトなので、戻した物は etag が変わり署名を作り直す）。
- 読み取り専用ライブラリ `b`: 照合の状況は読めるが、`POST /v1/b/similar/trash`・`/similar/undo` は 403 になること。

```bash
# リポジトリのルートで。他の確認と取り合わないよう、ポートと保存先を分けている
rm -rf .work/live-similar/state
pnpm exec wrangler dev --local --port 8796 --config worker/wrangler.test.toml \
  --persist-to .work/live-similar/state &
node tools/similar-fixture-seed.mjs --endpoint http://127.0.0.1:8796 --token test-access-token --lib a \
  --out .work/live-similar/expected.json
cd flutter && flutter test test_live/live_similar_test.dart \
  --dart-define=LIVE_ENDPOINT=http://127.0.0.1:8796 \
  --dart-define=LIVE_EXPECTED=../.work/live-similar/expected.json
```

トークンの既定は `worker/wrangler.test.toml` の `test-access-token`、期待ファイルの既定は種まきの既定の出力先
（`../.work/similar-e2e/expected.json`）。テストは `LIVE_ENDPOINT` が 127.0.0.1 / localhost 以外なら通信前に止まる。
ゴミ箱に前の実行の残りがあると止まるので、その時は保存先を消して種まきし直す（成功した後なら同じ状態でもう一度流せる）。
