# 重複・似ている写真を手元の Worker で通した記録（2026-11-27）

## 何を確かめたか

見た目の照合（vs1）を、手元の Worker（`wrangler dev --local`、miniflare の R2、`worker/wrangler.test.toml`）と
`tools/similar-fixture-seed.mjs` の合成画像（sharp で描いた図形とグラデーションだけ。実在の写真は1枚も使っていない）で
通した。本番の Worker には一度もつないでいない。トークンは `wrangler.test.toml` の確認用の値 `test-access-token`。

種まきの中身（seed 1）: 元絵 30 枚と、それぞれの別版（別フォルダの完全な写し・JPEG q40・半分の大きさ・WebP・PNG の再保存・
明るさ +8・40px の描き足し・同じ寸法の小さな描き足し・左右反転・幅 10% の切り抜き）、似ていない絵 6 枚、単色 1 枚、
中身が同じ `.mp4` の組。画像 337 枚のうち 245 枚にサムネ（JPEG か WebP）を置き、92 枚は無し。ライブラリ `a` にアルバム1つ（9件）。

### 手順 3: PC ツールで署名を作る

| 確かめた事 | 結果 | 記録 |
|---|---|---|
| 中身の計算を pending 0 まで回す | 1 回で pending 0（62 件を計算） | [step3-02-dup-scan.txt](step3-02-dup-scan.txt) |
| 照合の前の状況 | 画像 337・署名 0・残り 337（サムネあり 245・なし 92） | [step3-03-status-before.txt](step3-03-status-before.txt) |
| `similar-signatures.mjs write` → `--check-expected` | 337 件を送り、失敗 0。期待 339 件・61 組がすべて一致（6 秒） | [step3-04-tool-write-check.txt](step3-04-tool-write-check.txt) |
| 照合の後の状況 | 署名 337・単色 1・残り 0 | [step3-05-status-after.txt](step3-05-status-after.txt) |
| 別版の種類ごとの札 | 完全な写し → 同じファイル。q40・半分・WebP・PNG 再保存・明るさ → ほぼ同じ。同じ寸法の描き足し → ほぼ同じ＋差分かも。40px の描き足し → 似ている。左右反転 → 反転。切り抜きと単色 → どの組にも入らない（単色は数だけ出る）。動画は中身が同じ組だけ | [step3-06-groups-summary.txt](step3-06-groups-summary.txt) |
| 読み取り専用ライブラリ `b` と鍵なし | `POST /v1/b/similar/trash`・`/similar/undo` は 403。鍵なしの `/similar/status` は 401 | [step3-07-readonly-and-auth.txt](step3-07-readonly-and-auth.txt) |

### 手順 4: Web 版の画面で通す

保存先を新しくして種まきし直し（PC ツールは使わない）、接続先を焼き込んだ Web 版（`flutter build web --release`）を
Claude のブラウザ画面で開いた。サムネの無い 92 枚は Web では照合できないので、組の数は手順 3 より少ない（似ている 30 組 → 18 組）。

| 操作 | 確かめた結果 | 写真・記録 |
|---|---|---|
| 設定 → 「重複・似ている写真を探す」 | 中身の計算（一瞬）→ サムネのある 245 枚だけを数えて同意なしで照合（245 ≤ 300）→ 一覧 | [01](01-settings-entry.jpg)、[02](02-signing-progress.jpg) |
| 一覧 | 重複 31 組・似ている 18 組。見出しに「単色に近く比べなかった物: 1 件」「この端末では照合できない物: 92 件」 | [03](03-dup-tab.jpg) |
| 「すべての重複」 | 137 件・32.2 MB が選ばれる。オリジナルにはチェックが無く、差分かも・反転は選ばれない。サーバーの `identical`/`same`（差分かもでない）の数 137 件・33,843,064 バイトと一致。似ている段は何も選ばれていない | [04](04-select-all-dup.jpg)、[05](05-similar-tab-untouched.jpg)、[step4-02](step4-02-bulk-trash-curl.txt) |
| 「ゴミ箱に移動」→ 確かめ | 「完全に同じ 31件・ほぼ同じ 106件。…」。進み具合「ゴミ箱へ移動中 0 / 137」。終わると「137件をゴミ箱に移しました」と「元に戻す」 | [06](06-confirm-dup.jpg)、[07](07-trash-progress.jpg)、[08](08-after-trash-undo-snackbar.jpg) |
| 消した後に curl | ゴミ箱の元のキーの集合 = 選ばれた 137 件の集合。アルバムでは消した物の場所にオリジナルが入り、オリジナルが既にいたアルバムからは消した物だけが外れた。重複の段に選べる物は 0（反転と差分かもだけの 30 組が残る） | [step4-02](step4-02-bulk-trash-curl.txt) |
| ゴミ箱から1件ずつ戻す（`/ops/restore`） | ほぼ同じとして消した `s04-resave.png` は元の位置（オリジナル `s04.png` の直前）へ戻り、オリジナルも残った。同じファイルとして消した `x-copies/s01.png` はアルバムへ戻らなかった | [step4-03](step4-03-ops-restore.txt) |
| 似ている段で1件選んでゴミ箱へ → 6 秒以内に「元に戻す」 | 確かめに「『似ている』『差分かも』は別の絵のこともあります。」。`/similar/trash` の後に `/similar/undo`。アルバムは署名付き URL を除いて消す前と同じ JSON に戻り（入れたオリジナル `s03.png` も外れた）、取り消した物の控えは META に残っていない | [09](09-confirm-similar-warning.jpg)、[10](10-similar-trashed-before-undo.jpg)、[step4-04](step4-04-undo-curl.txt) |
| 開き直す | 戻した物（etag が変わる）を照合し直し、同じファイル・ほぼ同じ・似ている 18 組に戻る。スマートフォンの幅（375×812）でも崩れない | [12](12-mobile-dup-tab.jpg) |
| 読み取り専用ライブラリ `b` | 中身が空なので「重複も似ている写真も見つかりませんでした」。API の 403 は手順 3 の記録 | [11](11-library-b-empty.jpg) |
| `test_live/live_similar_test.dart`（新しい保存先に種まきし直して） | 2 件とも通った（署名 337 件、181 件をまとめて消してアルバムがオリジナルへ置き換わり、元に戻すで同じ並びに戻る。`b` は 403） | [step4-05](step4-05-live-similar-test-pass.txt) |
| 同じく、毎回新しい保存先で 3 回（見直しの後の Worker とアプリ） | 3 回とも 2 件が通った。2 回目の種まきでは手元の時計が最大 1,070 ms 戻り（102 件の上げた時刻が前の物より古い）、`s09` は写しの方が古くなった。種まきはそれを読み戻して、残す物の期待を写しにした | [step4-07](step4-07-live-similar-3-fresh-runs.txt) |

### 手順 5: Android

| 操作 | 結果 | 記録 |
|---|---|---|
| `flutter build apk --release`（AOT） | 通った（`app-release.apk` 80.2 MB）。成果物は配っていない | [step5-01](step5-01-build-apk-release.txt) |

## 流し方

```bash
# リポジトリのルートで。ほかの確認と取り合わないよう、ポートと保存先を分ける
pnpm exec wrangler dev --local --port 8797 --config worker/wrangler.test.toml --persist-to .work/t3-e2e/state1 &
node tools/similar-fixture-seed.mjs --endpoint http://127.0.0.1:8797 --token test-access-token --lib a \
  --out .work/t3-e2e/expected.json
curl -X POST -H "Authorization: Bearer test-access-token" http://127.0.0.1:8797/v1/a/duplicates/scan  # pending 0 まで
R2G_ENDPOINT=http://127.0.0.1:8797 R2G_TOKEN=test-access-token \
  node tools/similar-signatures.mjs write --lib a --check-expected .work/t3-e2e/expected.json

# 画面: 別の保存先で種まきし直し、接続先を焼き込んだ Web 版を配る（成果物は配らない）
cd flutter && flutter build web --release --output ../.work/t3-e2e/web \
  --dart-define=R2_BAKED_ENDPOINT=http://127.0.0.1:8798 --dart-define=R2_BAKED_TOKEN=test-access-token
python3 -m http.server 8091 --bind 127.0.0.1 --directory ../.work/t3-e2e/web
```

## 確かめていないこと・気づいたこと

- 実機（Android の FAD 版）と本番の Worker。サムネの無い物を端末で縮小して置く経路は、画面では通していない
  （Web 版はその経路を使わない）。`live_similar_test.dart` が Dart の VM でその経路を通している。
- 【まだ通していない】ゴミ箱の画面から戻す操作は、画面ではなく、その画面が呼ぶのと同じ `POST /v1/a/ops/restore` を
  curl で呼んだ（137 件の中から画面で探すのを省いた）。Worker 側の動き（元の位置へ戻る・オリジナルが残る・同じファイルは
  オリジナルの居るアルバムへ戻らない）は `similar-trash.test.ts` と [step4-03](step4-03-ops-restore.txt) で確かめている。
- 【まだ通していない】長押しからの「オリジナルにする」と、その後に前のオリジナルを消す操作は、ブラウザの画面では
  通していない（ブラウザの操作で長押しを送れなかった）。同じ流れは `similar_screen_test.dart`「オリジナルを選び直した後、
  前のオリジナルを消すと新しいオリジナルを残す物として送る」が画面の部品の上で通している。
- 仕様の手順 4 は「消した後の `GET /v1/a/similar?tab=dup` は 0 組」としていたが、実際は 30 組残る。残るのは選ばない約束の
  反転・差分かもだけの組で、選べる物（同じファイル・ほぼ同じ）は 0 件、空けられる量も 0。正しい動き。
- 中身の計算の画面（「中身を確認中… あと N 件」）は一瞬で終わり、写真に撮れていない。文字は `similar_screen_test.dart`
  「中身の計算の途中は残りの件数を出す」で確かめている。
- `live_similar_test.dart` が 1 回目に落ちた件（[step4-06](step4-06-live-similar-test-flaky-fail.txt)。元絵 `s16`・`s17` より
  別フォルダの写しの方がオリジナルになった）の原因は、手元の時計の戻り。R2（miniflare）の上げた時刻は手元の時計で付き、
  種まきは元絵を先に上げるが、時計が戻ると後で上げた写しの方が古くなる。Worker は決まりどおり（同じ中身の中では古い順 → キー）
  に選んでいた。見直しの後の 3 回の実行（[step4-07](step4-07-live-similar-3-fresh-runs.txt)）の 2 回目で同じ事が起き
  （最大 1,070 ms 戻り、`s09` の写しが古くなった）、上げた時刻を読み戻すようにした種まきが、期待を実際の古さに合わせて通った。
  種まきは時計の戻りを `warning:` で出す。
