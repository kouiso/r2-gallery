# #24 Web 版の復帰・署名 URL 差し替え・控え起動の実走記録（2 回目）

記録日: 2026-11-27（時刻はすべて JST +09:00。CDP 側の `Date` による）。
試したコミット: `321d58b`（`fix(state): resume tracking on web and library snapshot on baked connect (#24)`）。
この実走は `321d58b` で行った。その後のコミット（ビューア・動画のロック周りの変更、`e4f702a` まで）は flutter test のみで確かめていて、実走はしていない。
前回（`22c740b`）の実走で見つかった次の 2 件を直した後の再実走。前回の記録はこのリポジトリには置いていない。

- Web で `paused` が来ず `onBackground()` が呼ばれない → `resume`（`awayMs`）・再ロック判定が出なかった。
  `isBackgroundedState`（`flutter/lib/src/store/lock_policy.dart`）で web だけ `hidden` も裏扱いにした。Android は `paused` のみのまま。
- 焼き込み接続（`_connectBaked`）と `connect()` が `_lastEndpoint` を入れず、ライブラリの控えが書かれなかった → 接続を張った所で入れるようにした。

## 環境
- Worker: `pnpm exec wrangler dev --local --port 8787 --config worker/wrangler.test.toml --var URL_TTL_SECONDS:60`（miniflare の R2/D1、トークンは公開のテスト用 `test-access-token`）。
  署名 URL は発行から 60〜120 秒で切れる。「一覧の応答の `e=` の最大値 + 10 秒」まで隠した。
- アプリ: Flutter 3.44.6、`flutter build web --release --dart-define=R2_PERF_LOG=true --dart-define=R2_BAKED_ENDPOINT=http://127.0.0.1:8787 --dart-define=R2_BAKED_TOKEN=test-access-token`。
  作業用の detached worktree（`321d58b`）でビルドし、`python3 -m http.server 8080` で配信した。
  - ビルド成果物の `flutter_bootstrap.js` にだけ `config: { canvasKitBaseUrl: "canvaskit/" }` を足した（この環境から www.gstatic.com に出られず CanvasKit が読めないため。ソースは変えていない）。
- ブラウザ: Playwright 同梱の Chromium を `--headless=new --no-sandbox` で直接起動し、生の CDP で操作（1280x800、deviceScaleFactor 2）。
  Playwright は `Emulation.setFocusEmulationEnabled` で `visibilityState` を `visible` に固定してしまうため使わない（前回確認済み）。
  別タブを CDP の `/json/new` で開いて前に出すと、アプリのタブが本当に `hidden` になる。
- データ: ライブラリ `a` に 480x480 の JPEG 200 枚（`photo-001.jpg`〜`photo-200.jpg`）を PUT。23:36:40 までに 200 件とも 201。
  一覧は `GET /v1/a/folders?…&sort=new` の 1 回で 200 件（ページ送り無し）。

## 手順と見えた物
1. 23:38:18.635 新しいプロファイルで `http://127.0.0.1:8080/` を開く。焼き込みの接続で `init.read`(168ms) → `libs.net n=2`(1717ms)。
   23:38:30 に下の「写真」を押し、一覧 200 件が出た（`01_grid_loaded.png`）。
2. 23:38:42 ホイールで 4 回下へ（`02_before_hide.png`）。この時点のサムネ（`/t/a/`）は 182 件、すべて `e=1795790400`（= 23:40:00）。
3. 23:38:47.536 2 枚目のタブを前に出し、アプリのタブが `visibilitychange hidden`（`visibilityState=hidden`）。
   23:40:10.166 まで 約 82.6 秒（23:38:47.536→23:40:10.166、`awayMs` 82345）隠したまま（`e` の 23:40:00 を過ぎた）。その間 Worker へのリクエストは無し。
4. 23:40:10.179 アプリのタブを前に戻す。
   - `r2g.perf {"ev":"resume","awayMs":82345,"locked":false}` が出た（前回は出なかった）。
   - 続けて `GET /v1/a/folders?…&sort=new` が 1 本（23:40:10.357）、`r2g.perf {"ev":"resign.done","n":200,"left":0,"pages":1,"ms":222}`。
   - スクロール位置: `02_before_hide.png` と `03_after_return_1s.png`（および 8 秒後）は **ピクセル単位で同一**（PIL の差分 bbox が None。撮影した 2560x1600 の原画で比較。ここに置いたのは 1600 幅に縮めた物）。
5. 23:40:23 下端までスクロール（`04_after_return_scrolled_bottom.png`）。隠す前に取っていなかった 001〜018 のサムネを
   23:40:18〜 新しい `e=1795790520` で **18 件取得、すべて 200**。403 は 0 件、欠けたタイルも見えなかった。
6. 23:40:28 タイル（photo-027）を押してビューアが開き、`GET /m/a/photo-027.jpg?e=1795790520` が 200 で画像が出た（`05_viewer.png`）。
   同時に `GET /v1/a/meta?key=photo-027.jpg` が 3 回とも 500（Worker のログ: `D1_ERROR: no such table: image_review`）。
   ローカル D1 に `image_review` テーブルを作っていないためで、今回の修正とは関係ない。画面は崩れていない。
   （ビューアの時刻が 14:36 なのはヘッドレス Chromium のタイムゾーンが UTC のため。）

## 同じプロファイルでの開き直し（コールドスタート）
23:41:10.823 に同じプロファイルで開き直した（`console_reopen_r2g_perf.txt`）。
- `init.read`(42ms) → **`libs.cached n=2`(44ms)** → **`grid.cached n=200`(134ms)** → その後の 23:41:12.575 に `GET /v1/libraries` と `GET /v1/a/folders`、`libs.net n=2`(1287ms)。
  つまり `libs.cached` が `libs.net` より前に出て、`grid.cached` も出た。前回は焼き込みの初回接続で控えが書かれず、1 回目の開き直しでは `libs.cached` が出なかった。
  今回は最初の起動（手順 1）で書かれた控えが 1 回目の開き直しで使われた（`06_reopen_cached_1.8s.png`：開いて 1.8 秒の画面。Web 版は起動時に「取り込み」タブが開く）。

## 観察していない事・うまくいかなかった事
- Android 実機の `paused` 経路は今回も実走していない（flutter test の純関数テストのみ）。
- 動画は CDP の `Page.startScreencast` のフレームを webm にした物。隠していた約 82 秒はフレームが来ないので、3 秒の説明カードに置き換えてある（実時間ではない）。
  画面の上下に黒帯があるのは screencast の出力サイズによる。Playwright の recordVideo は上記の理由で使えない。
- `/v1/a/meta` の 500 は上のとおり（ローカル環境の D1 にテーブルが無い）。
- 1 回の実走で、複数回の測定（p50/p95）ではない。ローカル Worker・合成 JPEG での確認で、実機や本番の Worker での数値ではない。

## ファイル
- `pr229_resume_resign.webm` — 実走の動画（約 59 秒、隠していた間はカード）
- `01_grid_loaded.png` `02_before_hide.png` `03_after_return_1s.png` `04_after_return_scrolled_bottom.png` `05_viewer.png` `06_reopen_cached_1.8s.png`（1600 幅に縮小）
- `console_r2g_perf.txt` — 実走中の `r2g.perf`（`frames` 以外）と visibilitychange の行。`ev229.visibilitychange …` は計測用に足したリスナーの出力で、アプリの出力ではない
- `console_reopen_r2g_perf.txt` — 開き直しの `r2g.perf`・手順・`/v1/` のリクエスト
- `network_excerpt.txt` — Worker へのリクエストの抜粋（署名 `s=` は `<redacted>`）
