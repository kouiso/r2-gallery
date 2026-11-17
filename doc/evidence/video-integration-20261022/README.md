# 動画UI系列とmainの独立統合検証（2026-10-22）

作業ブランチは `integration/video-ux-main-20261022`。
保全した系列head `c85bc935deb9e7bb4fdeabbbb5cd91b96a99180b` から作成し、
取得し直したmain `75e8fe4017e2a6cc6830fe650a469c85a664cca6` をこの作業ブランチに統合した。
本流main・既存PR195・既存の各作業ブランチは変更していない。

統合commitは `0eb5d2820c2afdbbd95d35781d288309a8233bd4`。
parentsは上記c85bc93と75e8fe4の2つで、競合の手修正・再実装・squashは無い。
この後に追加したものは本検証の証跡だけ。

## 系列全体の保全

`integration-ancestry.json` に全15コミットの祖先関係を保存した。
`feature-product-preservation.json` では、共通基点以降に系列で変更されたFlutter本体・native設定・
plugin・assets・pubspec/lockとWorker非test sourceの88ファイルについて、統合前後のGit blob一致を確認した。
これはnativeの実行成功を示す検査ではない。

| 対象 | 含まれる実装・確認系列 |
|---|---|
| フッター・日本語フォント | `c90bf7c` / `0fa54ae` / `4a77fd6`。可変幅フッターと日本語字形の修正 |
| 明るさ・音量・前景画面保持 | `ac287ad` / `0bd173f` と後続のplayer lifecycle |
| Range/HEAD | `717378b`。suffix RangeとHEAD body取得回避 |
| 接続別専用保存・backup除外 | `f18fe7a` / `3e93d7c`。Webの専用保存非対応表示を含む |
| 背景再生・PiP・lockscreen | `a7c3e83` / `b93fa74`。Android/iOS同一playerへの実装、native/実機未確認 |
| 初回再生 | `c85bc93`。講評取得の遅延と大きい保存復号の別isolate化 |

mainから入った差分は9ファイル。galleryの取り込み完了時refresh、アップロード回帰とその証跡を含む。
両系列で重なった `flutter/test/transfers_ui_test.dart` は自動統合され、main側の120行追加が保持されている
（`merge-transfer-test.patch`）。その後、統合した実ファイルを全件テストした。
本体差分は [mainから統合commitへの比較](https://github.com/kouiso/r2-gallery/compare/75e8fe4017e2a6cc6830fe650a469c85a664cca6...0eb5d2820c2afdbbd95d35781d288309a8233bd4)、
取り込んだmainの差分は [c85bc93からの比較](https://github.com/kouiso/r2-gallery/compare/c85bc935deb9e7bb4fdeabbbb5cd91b96a99180b...0eb5d2820c2afdbbd95d35781d288309a8233bd4) と
`diff-vs-main.txt` / `diff-vs-startup.txt` を参照。

## 統合後の検証

Flutter 3.44.6 / Dart 3.12.2、既存の検証済みSDK・pub cache・lockfileを使用。
合成fixture/mockとローカルWorker環境のみを使用し、実ユーザー保存物・本番APIを扱っていない。

| 検証 | 結果 | 証跡 |
|---|---|---|
| `flutter test --no-pub --concurrency=1 --reporter expanded` | **535件PASS**。従来531件＋main追加4件 | `full.txt` / `full.json` |
| `flutter build web --release --no-pub` | **PASS**。通常JS releaseを生成。既知get_thumbnail_video/dart:htmlのWasm dry-run警告あり | `web-release.txt` |
| local `node .github/ci/run.mjs fast` | **PASS**。tools51件/Worker70件、lint・型検査・gitleaks・hygiene | `fast.txt` |
| `node tools/sync-ai-rules.mjs --check` | **PASS** | `ai-rules.txt` |
| `flutter analyze --no-pub` | errors/warnings **0**、**7 infoでexit1** | `analyze.txt` / `analyze-comparison.json` |

解析の7 infoは、従来6件をそのまま保持し、mainの `test/import_gallery_test.dart:69` の
`overridden_fields` が1件増えたもの。同ファイルのGit blobはmainと一致し、main側の
AppStateにも既にwebQueue fieldがある。解析結果をPASSとは記録せず、抑制・許容値変更はしていない。

fastは既存Miniflareの互換日fallback（2026-03-10）と空Rangeの内部assertionログを含むが、
期待する416の回帰を含む全70件が成功。本番runtimeを代替するものではない。
gitleaksは実行済み。追加の禁止語リストは未提供なので、その検査はskipしている。

件名をリポジトリ規約に整えた際も検証対象のコードtreeは不変
（`0e3d836905d4689632e5969d7ca0513b09d7ff52`、`integration-ancestry.json` に照合結果）。

`test-preservation.json` により、従来のFlutter test/support 47ファイル中45ファイルは同一、
残るtransfer2ファイルはmainの追加行だけで、既存test行の削除が無いことも確認した。

全Flutterテスト中はWeb compiler/Worker testを並列に起動せず、元のタイミング検査を維持した。
ログには失敗応答を意図的に注入したtestの診断出力も含まれる。終了コードと最終test summaryを記録する。
`SHA256SUMS` で添付物の完全性を確認できる。

## 未実施・承諾待ち

Android SDK規約同意・SDK導入・native buildは本人承諾待ちで実行していない。
iOS native build、両OS実機、背景再生/PiP/lockscreenのOS上の動作、実機first frameも未確認。
全件Dart/mock/widget成功やWeb build成功を、それらの実証とは扱わない。
Flutter実行環境は維持。sandbox/TLS無効化・権限変更・OS設定変更は行っていない。

既存の段階別証跡：
[UI/日本語](../video-ux-20261022/README.md)、
[mobile lifecycle](../mobile-playback-20261022/README.md)、
[専用保存](../private-storage-20261022/README.md)、
[初回再生の前後比較](../video-startup-20261022/README.md)。
初回再生の既存数値は合成データの局所測定であり、この統合で実機性能を再測定したものではない。

成功した本作業ブランチだけを通常pushする。PR作成・本流mainへのmerge・force push・
手動のリモートCI・配布/deploy・実機installは行わない。
