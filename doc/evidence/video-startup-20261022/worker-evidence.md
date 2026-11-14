# 動画の読み込み経路とローカル検証（2026-10-22）

対象は Worker の署名原本配信です。Flutter の初回再生を速くしたという結論は出していません。変更は `worker/src/routes/media.ts` に限定し、本番 R2/D1・実メディア・Cloudflare 設定にはアクセスしていません。

## 確認できた不具合と変更

- `Range: bytes=-N` は旧パーサが解釈せず、原本全体を 200 で返していました。R2 の suffix range に渡し、要求部分だけ 206 で返します。
- HEAD でも R2 GET を呼び本文ストリームを作っていました。HEAD は R2 HEAD のみを呼び、本文を取得しません。原本・保存済みサムネ・サムネの原本フォールバックで同じ扱いにしました。
- GET/HEAD の Content-Length を明示し、範囲外・suffix 0・空ファイルへの Range は本文なしの 416 と `Content-Range: bytes */size` を返します。通常の成立する Range は R2 GET 1 回のままで、範囲外エラーの時だけ HEAD でサイズを確認します。
- 署名・期限の検証順、ETag、CORS、private cache-control は維持しました。HEAD の Range/If-Range は全体メタ情報へ影響させません。GET の If-Range 評価や multi-range 応答は今回追加していません（multi-range は従来どおり無視して全体応答）。

公式仕様: [R2 ranged reads](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/#ranged-reads)、[HTTP Range](https://www.rfc-editor.org/rfc/rfc9110.html#section-14)。本変更で共有 CDN キャッシュは追加していません。

## 再現・回帰テスト

既存の `worker/wrangler.test.toml` にあるローカル専用 R2/D1 を利用します。データは 256 KiB の決定的な合成バイト列です。MP4 の拡張子を使いますが動画デコードを検証するファイルではありません。

| 検証 | 旧処理 | 変更後 |
|---|---|---|
| suffix 4 バイト | 200、262,144 B、範囲指定なし R2 GET 1 回 | 206、4 B、`suffix:4` の R2 GET 1 回 |
| HEAD | R2 GET 1 回、R2 HEAD 0 回 | R2 GET 0 回、R2 HEAD 1 回 |
| 通常・終端超過・大き過ぎる suffix | 一部未対応 | 実際に返す範囲・長さ・本文が一致 |
| 空・範囲外・suffix 0 | 200 又は R2 例外 | 416、サイズ付き Content-Range |
| 署名改変 | 403 | 403、R2 読み出しなし |

[修正前ログ](worker-before.txt): 最初に追加した 13 件のうち 8 件失敗・5 件成功。
[最初の修正後ログ](worker-after.txt): 同じ 13 件成功。
その後 GET/HEAD の ETag 一致と無関係な R2 障害を 416 に変換しないケースを 2 件補い、[最終全体ログ](worker-all.txt)で新規 15 件を含む Worker 全 68 件の成功を確認しました。

実行コマンド:

```sh
cd worker
WRANGLER_LOG_PATH=/tmp/r2-video-startup-wrangler.log ../node_modules/.bin/vitest run --reporter=verbose
cd ..
pnpm worker:typecheck
pnpm exec eslint worker/src/routes/media.ts worker/src/media_startup.test.ts
git diff --check
```

型検査・変更 TS ファイルの ESLint・差分の空白検査は通過しました。既設テスト実行環境は `@cloudflare/vitest-pool-workers 0.12.21` ですが、その実行に使われる Miniflare/workerd は 2026-03-10 系で、要求する互換日 2026-09-01 から fallback する警告があります。空ファイルの Range では Miniflare 内部の assertion ログも出ますが、Worker が境界を 416 として返すテストは成功しています。本番ランタイムの代替検証とは扱いません。

## ローカル初回・反復の内訳

[再実行用スクリプト](local-worker-probe.mjs) は本体 Worker をメモリ上でバンドルし、合成 R2 と D1 の審査行を作ります。旧処理は `3e82f57` の media.ts だけを差し替え、各版で別の Miniflare インスタンスを起こします。保存先は永続化しません。認証用の値は既存 test config の fixture を再利用し、結果には出しません。

```sh
node doc/evidence/video-startup-20261022/local-worker-probe.mjs
```

[全サンプル JSON](local-worker-results.json)。末尾 65,536 B の GET と meta を並行要求した結果です。

| 局所測定（ms） | 旧処理の初回 | 変更後の初回 | 旧処理の反復 5 回の範囲 | 変更後の反復 5 回の範囲 |
|---|---:|---:|---:|---:|
| 署名 URL 生成 | 0 | 0 | 0–1 | 0 |
| Worker 呼出開始→原本応答ヘッダ | 3 | 4 | 1–2 | 1–2 |
| 同→最初の本文チャンク | 4 | 4 | 1–2 | 1–2 |
| 同→本文読出し完了 | 5 | 5 | 2–3 | 2–4 |
| 並行 meta 読出し完了（D1 の合成行） | 8 | 9 | 2–3 | 2–3 |
| 応答本文 bytes | 262,144 | 65,536 | 262,144 | 65,536 |

初回は新しいローカル Worker 内での最初の署名要求です。反復は同じ isolate/R2/D1/HMAC キーを再利用します。プロセス起動・runtime ready・fixture 投入は測定外です。Worker の時計は I/O 更新の刻みがあるため、0 ms は計算が無コストという意味ではありません。

時刻の前後差は小さく、この測定から速度改善率や本番のボトルネックは判断できません。確認できた改善は suffix を使う要求の転送量と HEAD の本文取得回避です。

## Flutter 経路との対応・未測定範囲

| 区間 | 現行コードから分かること | 実測の有無 |
|---|---|---|
| 署名 URL の取得 | ApiClient.folder → Worker の一覧応答に URL が含まれ、Viewer は item.url を直接使う。タップごとの再署名 API は無い | ローカル署名生成のみ測定。一覧全体・実回線は未測定 |
| Range | 原本への要求は Worker の HMAC 検証→対象 R2 GET。meta/list の完了を待つ経路は無い | 合成 R2 の要求量・呼出回数・局所時刻を測定 |
| meta | ViewerScreen._loadReview は非同期で開始し、VideoView の initialize を待たせない | 合成 D1 の局所時刻のみ測定 |
| player initialize | video_player が item.url を使用。Dart の ApiClient の Dio と同じ経路ではない | Flutter/native は未測定 |
| initial buffer / 最初の描画 | isInitialized や isPlaying だけでは実際の最初の映像描画時刻とは同一視できない | 未測定 |
| cache | 画像用 thumbCache / CachedNetworkImage と動画の native バッファは別物。ネット動画の永続 cache 設定は現行 VideoView に無い | 実端末・実回線での cold/warm cache hit は未測定 |

次の実機検証では、同じ合成 MP4（先頭 moov と末尾 moov を区別）・同じネットワーク条件で、URL 取得、プレイヤー生成、initialize 完了、buffer 状態、ネイティブの first frame、送受信 bytes を別々に計測する必要があります。全動画先読みや原本一括ダウンロードは追加していません。

## ブラウザのブロッカー

通常の sandbox を有効にした `p.chromium.launch(executable_path='/usr/bin/chromium', headless=True, chromium_sandbox=True)` は、ナビゲーション前に SIGABRT で失敗しました。

```
FATAL:sandbox/linux/suid/client/setuid_sandbox_host.cc:172
The SUID sandbox helper binary was found, but is not configured correctly.
You need to make sure that /usr/lib/chromium/chrome-sandbox is owned by root and has mode 4755.
```

状態: ブラウザ起動は環境理由で失敗。設定変更、別経路の試行、`--no-sandbox` は行わず停止しました。合成 video 要素の再生測定・スクリーンショットは取得していません。Flutter SDK 取得の 403 も既知のまま再試行していません。API テストや上記局所測定を、Flutter/Android/iOS の再生確認の代用として扱いません。
