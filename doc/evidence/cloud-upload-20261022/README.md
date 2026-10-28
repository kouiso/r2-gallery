# クラウドでのアップロード・表示回帰確認（2026-10-22）

基点: `3e82f57bcf9e3ac8d0d8c983ef662ef18f643258`（確認時の origin/main）。
作業ブランチ: `fix/cloud-upload-regressions-20261023`。
開始時の未コミット変更は無し。他担当のブランチは変更していない。

[AGENTS.md](../../../AGENTS.md)、ローカル worker-deploy スキル、Cloudflare スキル、
現在の Issue と PR を読んだ。公開中の PR は検索結果で 0 件だった。
[#174](https://github.com/kouiso/r2-gallery/pull/174) と
[#191](https://github.com/kouiso/r2-gallery/pull/191) は merged を API で確認し、
両 merge commit が基点の祖先であることも確認した。原本保持と審査表示の実装は変更していない。

| 報告                                                                       | 現行コードの確認と今回の変更                                                                                                                                              | 今回の実行状況                                                                |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| [#109 リロード中の失敗](https://github.com/kouiso/r2-gallery/issues/109)   | 既存の台帳・multipart 復元を維持。2本の動画を2度復元する回帰を追加。同じセッション、確定パートの非再送、内容一致、完了イベント各1回、台帳と退避ファイルの片付けを検証する | Flutter 全体 426 件 PASS（Mac）。#109 の不具合自体は実行再現していない                |
| [#110 動画完了後の不可視](https://github.com/kouiso/r2-gallery/issues/110) | 未解決の通知欠落を特定。写真タブは通常アップロードの doneEvents のみ購読し、WebTransferQueue の完了を受け取っていなかった。完了した保存先の一覧だけを取り直す監視を追加   | 新規 widget 2件 PASS、修正を戻すと 2件 FAIL（下の「Flutter 検証」）。API 回帰2件 PASS                                    |
| [#111 再試行へ届かない](https://github.com/kouiso/r2-gallery/issues/111)   | 失敗だけのバーと先頭操作の既存修正を維持。完了行の4秒後の自動削除をまたいで、360×640・文字1.3倍でバー→詳細→再試行をたどる回帰を追加                                       | 新規 widget 1件 PASS（Mac）                                                       |
| [#113 審査メモ欠落](https://github.com/kouiso/r2-gallery/issues/113)       | #191 の項目保持・両スコア・古い応答除外・空状態と既存 viewer 回帰を確認。重複実装しない                                                                                   | Flutter 全体は PASS。本番 REVIEW_DB / REVIEW_LIBS / r2_key 結合は未確認 |

写真タブの変更は、進捗通知で何度も取り直さず、新たに完了した行の保存先だけを更新する。
完了行削除で追跡 ID も取り除き、画面破棄時には監視を解除する。
新規 widget は実 WebTransferQueue と合成 fetcher・一時ファイル・メモリ API を使う。
gallery_tab.dart を main の版に戻すと取り込み後も galleryCalls が1のままで、
追加した 2件が失敗する。実行結果は下の「Flutter 検証」に記録した。

API 回帰は小容量と5 MiB超の multipart 合成動画を、ローカル Miniflare R2 に保存する。
未完了の非表示、完了応答のキー・サイズ、索引に無い日本語名の動画の一覧出現、
2度の新しい一覧要求、署名 URL の MIME・SHA-256 内容一致・206 範囲応答、別ライブラリへの非混入を確認した。
合成バイト列による通信契約テストであり、動画デコードの成功を保証するものではない。

## 今回の変更に対して実行したチェック

Node `24.19.0`、pnpm `9.15.9`、gitleaks `8.24.3`。
依存は frozen lockfile で取得し、追跡対象の設定・lockfile は変更していない。

| コマンド                               | 結果                                                                     | 証跡                                 |
| -------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------ |
| `node .github/ci/run.mjs fast`         | PASS: lint、Worker 型検査、tools 51件、Worker 55件、gitleaks、leak-check | [fast.txt](fast.txt)                 |
| `node --test .github/ci/run.test.mjs`  | 8件 PASS                                                                 | [ci-contracts.txt](ci-contracts.txt) |
| `node tools/sync-ai-rules.mjs --check` | PASS                                                                     | [ai-rules.txt](ai-rules.txt)         |
| `git diff --check`                     | PASS                                                                     | ローカル実行                         |

禁則語リストは供給されておらず、leak-check の禁則語部分はスキップ（成功と数えない）。
gitleaks、追跡ファイル、コミットメールの検査は実行した。
ローカル workerd は要求された互換日付 `2026-09-01` を扱えず `2026-03-10` へ
フォールバックする既存警告がある。本番ランタイムの検証ではない。

## Flutter 検証（Flutter 3.44.6、2026-10-23 に作り直した branch の head で再実行）

- Mac: `flutter test` 全体 426 件が成功。`flutter analyze` は error と warning が 0 件
  （info 7件。6件は未変更ファイル、1件は追加テストの overridden_fields）。
- `node .github/ci/run.mjs fast` も同じ head で成功（[fast.txt](fast.txt)、leak-check は作者メール全て noreply）。
- `lib/src/ui/gallery_tab.dart` を main の版に戻すと、`import_gallery_test.dart` の 2 件が失敗した（Windows で再確認、`+0 -2`）。
  動画が一覧に出ず（0 widgets found）、保存先の取得が personal 1 回のまま（期待 2）だった。修正を戻すと成功する。
- `transfers_ui_test.dart` の再試行テストは、台帳の書き込みが止まって完了しなかった。
  メモリ台帳に替え、実時間を進めながら pump する形に直した。
- Windows では main でも `transfer_queue_test.dart` の再開テスト 1 件が失敗するため、Flutter の検証は Mac で行った。
- 未実施: web build とブラウザ確認、禁則語リストの検査。

## 未検証範囲

- web build と実ブラウザ確認（合成 fixture のみで行い、本番へ配布しない）。
- 禁則語リストの検査（リストが供給されていない）。
- Android / iOS 実機、OS 終了・画面オフ・回線断の新たな実機検証、実データ移行、
  本番データや配布済みビルドでの再現、本番 D1 の結合確認。
- 本番 R2/D1、実画像、個人データは閲覧・変更・削除していない。
  認証情報の新規作成・保存、通信/セキュリティ設定変更、契約、deploy、merge、force push、
  保護ブランチ push、CI 明示起動、フック回避、外部担当への連絡は行っていない。
