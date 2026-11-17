# 動画 UI・保存・再生ライフサイクルの追加対応

更新（2026-10-22）: 新クラウド環境での実行結果と退行修正、前後のwidget画像は
[追加検証記録](../video-ux-validation-20261022/README.md)を参照。以下は初回実装時点の記録を保持する。

基点は `3e82f57bcf9e3ac8d0d8c983ef662ef18f643258`、作業ブランチは
`fix/viewer-footer-ux-20261022`。本番データ・実メディアは使用していない。
この記録は**実装と実行済みの検証を区別する**。画面の変更前後の画像・動画は未取得であり、
本人指定の PR 証跡条件はまだ満たしていない。配布可能・全要件完了とは扱わない。

## 変更の対応表

| 依頼 | 実装 | 検証と残件 |
| --- | --- | --- |
| 一覧と動画のフッター | 一覧は4タブの場所移動、Viewer は作品操作、動画内は再生操作という役割を維持。作品操作はラベル計測で折り返しと列数を決め、共有した高さの直上に再生操作を置く。48dp以上の操作対象・左右と下の SafeArea・「一覧に戻る」を明示 | 合成動画による3画面条件の widget 操作・撮影 harness を追加。未実行、画像なし |
| [#198 明るさ・音量](https://github.com/kouiso/r2-gallery/issues/198) | 隠れた縦スワイプを廃止。「明るさ・音量」入口、現在値、動画内音量と画面の明るさを明示。確認できた明るさだけ5ポイントずつ変更し、退出で元の窓の設定へ戻す。OS音量やグローバル輝度設定を書き換えない | API代役での無操作・誤スワイプ・値取得失敗・上限変化・復元回帰を追加。未実行。自動輝度の現在値が不明なら操作を無効にして理由を表示 |
| 初回の動画読み込み | suffix Range の全量転送を部分応答に修正、HEAD の本文取得を回避。動画の先読みは追加しない | Worker の修正前8失敗→修正後15成功、全68成功。合成256KiB、初回+反復5回の局所測定。[ログ・全サンプル](../video-startup-20261022/README.md)。Flutter first frame や本番速度改善率は未測定 |
| 保存の一本化 | 外部へ書き出す UI と既定の Dart bridge を閉じ、接続に結び付いたアプリ内オフライン保存へ統合。「保存待ち」と「保存済み」、容量・個別削除・確認付き一括削除を区別 | [保存設計と追加回帰](../private-offline-20261022/README.md)。Flutter未実行、Android実機/backup未確認、Web内保存は未実装 |
| 復帰時の安全性 | 非同期ロック判定が終わるまで自動・手動再生/リプレイを始めない。判定中に再び背景化/復帰したら最新世代も評価。保存動画も背景で停止し、古い初期化結果・接続切替・手動停止を保護 | foreground 4回帰、保存境界と遅延APIの回帰を追加。未実行 |
| 前景再生中の画面保持 | Android の窓単位 API と Web Screen Wake Lock を接続。グローバル自動ロック設定・電源ボタンは変更対象にしない | [画面保持の設計・検証](screen-awake.md)に結果を記録。ネイティブ・ブラウザは未実機検証 |
| 日本語字形 | 正規ライセンスの JP face を同梱し、テーマと文字の locale を固定。サイズ・太さ・行間の指定値は維持 | [選定・資産検証と未取得の前後画面](japanese-font.md)。実機/Flutter画面は未検証 |
| [#196 背景/ロック画面操作](https://github.com/kouiso/r2-gallery/issues/196)・[#197 PiP](https://github.com/kouiso/r2-gallery/issues/197) | 現在の pause・認可ゲートを保全。media session/service と PiP は未実装で、Issue を close しない | [プラットフォーム別の必要実装と受入操作](playback-platform-plan.md)。画面保持の実装を背景再生の完了とは扱わない |

## 変更のコミット

- `c90bf7c`: 作品操作の可変レイアウトと戻る導線。
- `ac287ad`: 明示した明るさ・音量の操作と復帰判定の待機。
- `717378b`: Range と HEAD の不具合、再現・局所測定。
- `f18fe7a`: アプリ内保存の統合、接続認可・非同期境界と旧保存の保全。
- `0bd173f`: 前景再生中の画面保持、手動開始も含む認証ゲートと回帰。
- `d9f0364`: 動画初期化・保存目録の診断から例外の私的な詳細を除外。
- `0fa54ae`: 日本語フォント同梱・JP字形とライセンスの資産検証。
- 統合証跡と画面取得 harness は独立コミット。

## 意図して残す UI の違い

一覧の「写真・アルバム・取り込み・設定」は場所を移動するための NavigationBar。
全画面の Viewer は Navigator に積む作品表示なので、下に同じ4タブを置くと、
再生中の画面から別の場所へ移動する意味と、作品への操作が混在する。
そこで Viewer には「情報・オフライン保存・アルバムへ・ゴミ箱へ」を置き、
再生/停止・シーク・操作ロック・調整は動画の操作バーに分ける。
高さを固定値で見せかけて揃えず、文字倍率・ラベルの幅・安全領域を含めた配置を共有する。
戻る操作は元のタブと一覧の状態を復元する。

## 画面と操作の証跡（未取得）

`flutter/test/footer_ux_test.dart` は実際の HomeShell、openViewer、情報シートを使い、
デコーダーだけを FakeVideo に差し替える。本物の Flutter RenderRepaintBoundary を撮影し、
別実装のモック画面や架空のスクリーンショットで代用しない。

条件は320×640・文字1.3倍、320×640・2倍、640×360・文字1.3倍・左右44/下21の安全領域。
各条件で一覧→動画→+10秒→一時停止→調整→操作ロック/解除→情報→元一覧をたどり、
ラベルの省略、48dpの操作対象、安全領域、フッターと再生バーの境界、再生位置、破棄を確認する。
撮影予定は list/video/adjustments/locked/info/return の6段階。
通常は同梱の日本語フォントを読み込む。必要な場合だけ `FOOTER_EVIDENCE_FONT` で
利用許諾を確認した比較用フォントを明示できる。

```sh
cd flutter
flutter test test/footer_ux_test.dart \
  --dart-define=FOOTER_EVIDENCE_DIR=/tmp/r2-footer-after
flutter analyze
flutter test
flutter build web --release
```

変更前は別の一時 worktree に基点と同じ harness を置き、
`--dart-define=FOOTER_EVIDENCE_LOAD_BUNDLED=false` で新フォントを注入せず撮る。
旧実装では新しい期待値が
失敗する想定だが、撮影を先に行う構成。前後とも**まだ実行していない**。
実画面の動画記録、Androidタッチ操作とTalkBack、ブラウザ実再生・PiPも別途必要。

## 実行可能なチェックと環境障害

最初の `fast` は型検査と全119件のTS/Nodeテスト後、秘密値検査が合成動画名をAPIキーとして
検出し exit 2。[失敗ログ](fast-before-fixture-fix.txt)。公開前の自分の履歴の fixture 名を変更し、
作業用に自分が作成した退避ブランチを外し、通常の全履歴検査を再実行して成功した。
検査設定・allowlist・フック・検査範囲は変更していない。他担当のブランチと公開済み履歴は変更しない。

| 検査 | 結果 | 証跡 |
| --- | --- | --- |
| `node .github/ci/run.mjs fast` | PASS: lint、Worker型検査、tools 51件、Worker 68件、gitleaks、leak-check | [最終ログ](fast.txt) |
| `node --test .github/ci/run.test.mjs` | 8件 PASS。実際のCI起動ではなく実行制御の単体テスト | [ログ](ci-contracts.txt) |
| `node tools/sync-ai-rules.mjs --check` | PASS | [ログ](ai-rules.txt) |
| フォント資産 | PASS: 出典/hash、収録範囲、JP outline、太さ、許諾 metadata | [ログ](font-assets-validation.txt) |
| `git diff --check` / #195の同一ファイル差分のdry check | PASS | ローカル確認、変更の適用は無し |
| Flutter analyze / test / build、JS interop compile | 未実行 | SDK不在・下記403 |
| Android/iOS実機、Web実画面、前後スクリーンショット/動画 | 未実行・証跡なし | 下記の環境障害 |

これらの PASS は Dart の型検査・再生成功を含まない。禁則語リストは環境に無く、
leak-check のその部分はスキップ（成功と数えない）。workerd互換日fallbackと
空RangeのMiniflare assertionについては[性能検証記録](../video-startup-20261022/README.md)を参照。

- Flutter/Dart が環境に無い。公式 manifest
  `https://storage.googleapis.com/flutter_infra_release/flutter/releases/releases_linux.json`
  の通常取得は proxy CONNECT 403。親で保存環境の許可が変更された後の1回も403だった。
  さらに設定の公開済み確認を受け、同じ正規 URL を1回だけ再確認したが403継続。
  [ツール応答の記録](flutter-manifest-after-publish.txt)。この workspace への反映は未確認で、
  manifestのpayloadも保存されていない。その後の再試行・別ホスト・別経路は使用していない。
  Flutter analyze/test/buildは未実行。
- Chromium は通常 sandbox のまま起動すると、SUID sandbox helper の所有者/モード不整合で
  ナビゲーション前に SIGABRT。`--no-sandbox`、権限変更、別経路での回避はしていない。
  [正確なエラー](../video-startup-20261022/README.md#ブラウザのブロッカー)。
- Android SDK/実機・iOS実機は未使用。iOS は雛形があるが現行配布対象として確認できないため、
  新プラットフォームの提供は追加していない。実データ移行、既存外部ファイルの削除は行わない。

## 既存成果との分離

#174/#191 の原本保持・審査表示を重複実装しない。
[PR #195](https://github.com/kouiso/r2-gallery/pull/195) は別ブランチとして保全。
読戻し時は head `2f157ce7df986911d00680218ae0c5842bcb1edb`、open/readyだった。
他担当による検証・修正が進んでおり、こちらから更新・draft変更は行っていない。
今回の `transfers_ui_test.dart` は既存オフライン保存 group のみを調整し、#195 の再試行回帰には触れない。
その Mac 検証結果を、このブランチの Flutter PASS として流用しない。
同じファイルへの #195 の差分は現在の作業ツリーへ `git apply --check` で適用確認が成功した。
チェックだけで、適用・ブランチ統合は行っていない。

本番 R2/D1・実画像・個人データ、新規認証情報、通信/セキュリティ設定、契約、deploy、
merge、force/protected push、手動CI起動、外部担当への連絡は対象外。
