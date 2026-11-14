# 初回動画再生の経路診断と改善（2026-10-22）

基点は `3e93d7ca4b37fe1ef8127658085d7728621e0ceb`、作業ブランチは
`perf/video-startup-20261022`。保存隔離とmobile player lifecycleを維持した小さい追加修正。
実ユーザーの動画・秘密・本番APIは使っていない。Android SDK規約同意・導入・native buildは本人確認待ちで保留。

既存Range/HEAD修正時の報告は [Worker検証の原記録](worker-evidence.md) に内容を変えず保存した。
そこにあるSDK 403・ブラウザ起動失敗は当時の環境の記録であり、今回のFlutter成功と区別する。

## 変更と経路の点検

| 段階 | 確認した経路 | 今回の対応 |
|---|---|---|
| 一覧→再生操作 | 一覧の `MediaItem.url` を `openViewer` から `VideoPlayerController.networkUrl` へ渡す。再生時のfolder再取得やアプリ側全量download待ちは無い | URLの再取得・別player・先読みを追加しない |
| 付加情報 | `ViewerScreen._enterPage` が情報シート用AI講評 `ApiClient.meta` を先行取得していた。MP4コンテナの必須metadataとは別。従来もplayer初期化との並行処理で、直列awaitではない | **動画だけ情報シートを開くまで講評GETを遅延**。画像の取得、取得中/失敗/再試行、ページ移動時の古い応答無視は維持 |
| ネット動画 | `video_player.initialize` 内でplatform playerがURLから取得・コンテナを解釈する | Buffer/Range要求方式を推測して変更しない。DartからdownloadToFileは呼ばない |
| Worker Range/HEAD | 既存 `717378b` の `worker/src/routes/media.ts`。通常RangeはR2 getのstreamを直接返し、HEADはheadでbodyを読まず、416時だけ補助head | **変更無し**。Workerソースとlockfileの基点一致を `environment.json` に記録。既存15件の配信回帰を含むWorker全68件をlocal fastで実行 |
| 保存動画 | 接続認可→鍵→暗号文全体read→AES-256-GCM全体認証復号→private一時cacheへのwrite/flush→file controller初期化 | **256KiB以上の復号を `compute` の別isolateへ移す**。小さいデータは従来同様inline。鍵の読取・platform channelは元のisolate。アプリ内isolateへbytesと鍵だけを渡す |
| 再生許可 | `PlaybackSession.initialize` の同一controller初期化→OS bind、前景確定・認可・audio focus→play | 既存の認可とlifecycle待ちを省略しない。二重player・二重音声を導入しない |
| first frame | Android `STATE_READY`、iOS `AVPlayerItem.readyToPlay`、Web loadedmetadata/canplayに基づくinitializedは初回描画完了そのものではない | **実際のfirst frameは未測定**。mock play受付やinitializedをfirst frameとして報告しない |

保存暗号文の形式（nonce12byte + ciphertext + tag16byte）と鍵は変更していない。
全体のMAC認証成功前に平文をdecoderへ渡さない。破損ciphertext/tag・異なる鍵はnullとして拒否。
全量read/復号と一時cache準備の待ち、メモリ消費は残る。保存時の暗号化は今回の対象外。
Webではcomputeが同じevent loopで動くため、このisolate改善をWebへ一般化しない（Webのアプリ専用保存は従来通り非対応）。

## 同じ条件での前後比較

基点用の別worktreeはtracked product差分無し。同一内容の2つのprobe testだけを未追跡で置いた。
`probe-source-hashes.json` のSHA-256が両worktreeで一致することを確認した。
同じFlutter 3.44.6 / Dart 3.12.2、同じlockfile、同じ入力と遅延、各条件3サンプル。
before→afterを順番に実行し、Web buildと並行していない。JSONのvariantは出力ラベルのみで、処理を分岐しない。

| 測定対象 | before | after | 解釈 |
|---|---:|---:|---|
| 仮想時刻・独立した資源：mock play受付 | 410ms | 410ms | 対照条件。講評取得を削っても競合が無ければ変わらない |
| 仮想時刻・単一資源競合：mock play受付 | 650ms | 410ms | 講評240msがRange mock300msに先行する人工条件。実ネットワークの測定値ではない |
| 再生操作時の講評API呼出 | 1 | 0 | 情報シートを開くと1回取得する。初期化1回、mock Range1回/4096byte、追加URL取得0、全量download0を検査 |
| 1MiB：復号＋private cache準備の中央値 | 208.624ms | 153.773ms | 実Dart debug・一時fixture I/O |
| 1MiB：各サンプルの最大main isolateタイマー間隔の中央値 | 198.158ms | 14.442ms | 10ms周期timerの遅延。frame時間ではない |
| 8MiB：復号＋private cache準備の中央値 | 1231.610ms | 1175.832ms | 全量準備の待ちは約1.2秒残る |
| 8MiB：各サンプルの最大main isolateタイマー間隔の中央値 | 1201.189ms | 26.181ms | 大きい復号でUI操作やスピナーを止める負荷を別isolateへ移した |

ネット経路probeは実 `ViewerScreen` / playback coordinatorに、合成256KiBのtransport、controller、OS bridgeを注入。
講評240ms・Range300ms・初期化60ms・bind40ms・focus10msを同じ仮想時計で進める。
Dioとnative playerが実際に同一キューを使うと断定するものではない。全6サンプルのイベントを `probes/` に保存。

保存probeは1MiB/8MiBの `i % 251` という合成bytesを実GCM暗号化して準備し、実復号とcache I/Oを測定。
暗号化setupは計測外。毎回新しいreaderを使うがOS filesystem cacheはsetupで温まっており、cold storageではない。
鍵はMemKvで、実Keystore/Keychainの時間を含まない。cache内容のSHAと削除を検査する。
最後の30ms paddingでtimerの遅れを拾うが、そのpaddingは準備時間に含めない。
3サンプルのdebug計測で統計的有意差・端末の体感改善・release性能は主張しない。

再実行例（各worktreeの `flutter/` で実行、出力先はリポジトリ外）：

```bash
flutter test --no-pub --concurrency=1 --reporter expanded \
  --dart-define=STARTUP_EVIDENCE_DIR=/tmp/r2-startup-probes \
  --dart-define=STARTUP_EVIDENCE_VARIANT=before \
  test/video_startup_probe_test.dart test/offline_video_startup_probe_test.dart
```

## 合成MP4のコンテナ点検

ffmpegのtestsrc2から160x90・12fps・2秒・音声無しH.264を生成し、同じ24packetを
`-c copy -movflags +faststart` でremuxしたfixtureを比較した。いずれも22688byte。
末尾moovはoffset21584/1104byteで先頭4096byteに収まらず、先頭moovはoffset32で収まる。
`fixtures/container-layout.json` とffprobeのpacket hashで同一符号化packetを確認。
これは末尾metadataが追加Range取得を要し得る構造の説明で、実HTTPやcodec再生時間の計測ではない。
ユーザー動画の変換・全量転送・自動remuxは行っていない。両fixtureと生成コマンドを同梱。

## 回帰・チェック

- `flutter test --no-pub --concurrency=1 --reporter expanded`：**531件PASS**（保存隔離時523件＋新規8件）。タイミング許容値を緩和せず直列実行。
- 情報シートの遅延取得/再利用、失敗時の再試行、A→Bで古い結果を表示しないことをwidget回帰で確認。
- 大きい暗号文のroundtrip、ciphertext/tag/鍵改変の拒否、復号待ちの接続変更で平文cache/decoderへ進まない回帰を追加。
- `flutter analyze --no-pub`：既存と同じ**6 info**、exit1。errors/warnings・新規info無し。`analyze-crypto.txt` に実出力を保存。
- `flutter build web --release --no-pub`：**PASS**。既存get_thumbnail_videoのdart:htmlによるWasm dry-run警告は残る。通常JSのWeb releaseを生成。
- local `node .github/ci/run.mjs fast`：**PASS**（tools51件/Worker68件、lint/typecheck、gitleaks/hygiene）。`node tools/sync-ai-rules.mjs --check`：**PASS**。`fast.txt` / `ai-rules.txt` を参照。禁止語リストは未提供で、その追加検査はskip（既存gitleaksは実行）。リモートCIは手動実行しない。
- 既存Miniflareの互換日fallback（2026-03-10）と空Rangeの内部assertionログは残るが、Workerの期待416回帰は成功。本番runtimeの検証とは区別する。

## mainと配布版の読取比較

親から通知されたAndroid 0.4.0 (682)のSHAは `75e8fe4017e2a6cc6830fe650a469c85a664cca6`。
このSHAと取得し直したorigin/mainは一致した（時刻と詳細は `main-overlap.json`）。
mainは `0738bee` / `4a77fd6` / `b93fa74` / `3e93d7c` を祖先に含まず、系列14commitの
`git cherry` はすべて `+`。**今回系列がその配布SHAに含まれるとは言えない**。

共通祖先 `3e82f57` 以降、mainは別のアップロード修正（PR205）を含む。
今回の性能修正の本体2ファイルはmain変更と重ならない。系列全体の重複は
`flutter/test/transfers_ui_test.dart` の1ファイルで、tempコピーに対する読取3-way比較は競合無し。
テキスト上の比較のみで、mainとの統合テスト・merge/rebase・別修正の取り込みは行っていない。
既存PR195には変更していない。

## 残課題と制約

実機/ブラウザでの初回frame、実回線のHTTP要求順序とcold cache、実Keystore/Keychain、
Android/iOS native buildと両OSの背景再生・PiP・ロック画面操作は未確認。
SDK規約同意/導入/native buildは引き続き保留で、SDK権限変更・sandbox/TLS無効化もしていない。
Flutter環境は維持。既存のmobile実装と保存隔離はそれぞれ
[mobile証跡](../mobile-playback-20261022/README.md) / [保存証跡](../private-storage-20261022/README.md) を参照。
新規認証・課金・本番通信/実データ変更、実機install、PR作成・merge・deployは行っていない。

根拠：
[Flutter compute](https://api.flutter.dev/flutter/foundation/compute.html)、
[Cloudflare R2 Workers API](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)、
[Workers best practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/)。
R2型定義 `@cloudflare/workers-types@5.20261022.1` を正規npm tarballで読取確認し、依存更新/導入はしていない。
platform初期化は固定依存のvideo_player_android2.12.2 / avfoundation2.12.1 / web2.4.0のソースを点検した。
