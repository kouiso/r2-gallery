# KMP → Flutter 機能対応表

KMP 版（`1ae3879^:kmp/`）にあって Flutter 版に無かった、利用者が触る機能の一覧と、移植の状態。

2026-10-19 に、配るクライアントを Flutter 版だけにすると決めた。KMP 版へ戻す道は用意しない。
そのため `.fad-client` は使わない（FAD は常に Flutter 版の APK を配る）。
この表は「移植で何も落としていないか」を確かめるためのもので、配る版を切り替える条件ではない。

一覧は 2026-10-19 にコードを読んで突き合わせ、別のエージェントが反証を試みて確かめた。
状態は、移植の PR（#144 アルバム、#145 設定、#146 写真タブ、#147 ビューワー、#148 ゴミ箱、#149 転送）を
一本にまとめた時点のもの。

## 状態の決め方

- ☑：Flutter のテストが、その機能を利用者の操作（タップ → 状態 → 画面に出る結果）で通している
- ◐：Dart 側の流れはテストで通しているが、機能の中心がネイティブ（Kotlin）側にあり、実機で確かめていない
- ☐：まだ無い

どの行も、実機での確認はこの表の範囲外。APK は統合時にビルドが通ることだけを確かめた。

## 写真タブ（#146）

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| H1 | 並び替えメニュー（新しい順／古い順／名前順／サイズ順） | ☑ | `grid_test.dart` H1 |
| H2 | 日付見出し（今日／昨日／M月D日 曜日／年つき／日付不明） | ☑ | `grid_test.dart` H2。ゴミ箱・ビューアの日付も同じ `grid/day_label.dart` |
| H3 | 見出しの丸で、その日をまとめて選択／解除 | ☑ | `grid_test.dart` H3/H14 |
| H4 | 選択バーを「アルバムへ／オフライン／ゴミ箱へ」の文字付き3操作に | ☑ | `grid_test.dart` H4/H9、本物の Worker に対しては `test_live/live_trash_test.dart`（`doc/evidence/r2-4-bulk-trash-live/`）。「オフライン」は #149 のオフライン保存につないだ |
| H5 | 一括「アルバムへ」（既存か新規、200件ずつ、ライブラリ混在は送らない） | ☑ | `grid_test.dart` H5 |
| H6 | オフライン保存（選択 → 暗号化キューに追加） | ☑ | `grid_test.dart` H4、`transfers_ui_test.dart` オフライン保存 |
| H7 | 長押しの個別メニュー（アルバムに追加／端末に保存／ゴミ箱へ、読み取り専用表示） | ☑ | `grid_test.dart` H7。「端末に保存」は #147 の `AppState.exportToDevice` |
| H8 | 端末の Photos/Downloads への書き出し | ◐ | 長押しからの経路は `grid_test.dart` H7、取得と署名切れの取り直しは `viewer_test.dart` X1。MediaStore への書き込みは Kotlin で、実機未確認 |
| H9 | ゴミ箱へ送った後の「元に戻す」（6秒） | ☑ | `grid_test.dart` H4/H9、`trash_test.dart` T1、本物の Worker に対しては `test_live/live_trash_test.dart`（`doc/evidence/r2-4-bulk-trash-live/`）。#148 の `offerTrashUndo` に一本化 |
| H10 | 読み取り専用ライブラリの扱い（鍵、削除・追加を隠す） | ☑ | `grid_test.dart` H10、`settings_port_test.dart` S4、本物の Worker に対しては `test_live/live_trash_test.dart`（`doc/evidence/r2-4-bulk-trash-live/`） |
| H11 | アップロード前の確認シート | ☑ | `transfers_ui_test.dart` アップロード確認 |
| H12 | グリッド仕様（4列・2dp、動画バッジ、選択時の丸チェック、末尾9件手前で続き） | ☑ | `grid_test.dart` H12 |
| H13 | 空／エラー状態の案内 | ☑ | `grid_test.dart` H13 |
| H14 | 選択モードのヘッダー（N件を選択、すべて選択／解除、閉じる） | ☑ | `grid_test.dart` H3/H14 |
| H15 | フォルダ行から階層を辿る | ☑ | `grid_test.dart` H15、`albums_test.dart` B1（アルバムタブのフォルダ一覧から同じ画面を開く） |

## アルバム・フォルダ（#144）

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| A1 | アルバム作成 | ☑ | `albums_test.dart` A1 |
| A2 | アルバム長押し：名前変更／削除（確認つき） | ☑ | `albums_test.dart` A2 |
| A3 | フォルダ閲覧の複数選択 → アルバムへ追加 | ☑ | `albums_test.dart` A3。ピッカーは写真タブと同じ `ui/album_picker.dart` |
| A4 | アルバム内：選択して外す | ☑ | `albums_test.dart` A4 |
| A5 | アルバム内の並び替え（前へ／後ろへ） | ☑ | `albums_test.dart` A5 |
| A6 | アルバム画面の選択モード | ☑ | `albums_test.dart` A6/A8 |
| A7 | アルバム画面：ゴミ箱へ＋元に戻す、アイテム長押しメニュー | ☑ | `albums_test.dart` A7 |
| A8 | プルリフレッシュ、続きの自動読み込み、タイトル＋件数、読み取り専用アルバム | ☑ | `albums_test.dart` A6/A8 |
| A9 | アルバム／フォルダ切替、フォルダ一覧、フォルダ作成 | ☑ | `albums_test.dart` A9 |
| B1 | フォルダ閲覧画面（階層、タイトル、空フォルダ） | ☑ | `albums_test.dart` B1。写真タブのフォルダ画面（H15）と同じ1つの画面 |
| B2 | フォルダ閲覧の並び替え・日付見出し・日単位まとめ選択 | ☑ | `albums_test.dart` B2 |

## ゴミ箱（#148）

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| T1 | 「元に戻す」6秒スナックバー（単発／一括） | ☑ | `trash_test.dart` T1。写真タブの長押し・アルバム・ビューワーも同じ部品 |
| T2 | 復元失敗理由（409／403／404）と行ごとの復元 | ☑ | `trash_test.dart` T2 |
| T3 | ゴミ箱の保持期間の案内 | ☑ | `trash_test.dart` T3/S5。Flutter 版のゴミ箱は下のタブなので、アルバムタブに入口の説明は置いていない |
| T4 | ゴミ箱行の表示（種類アイコン、日付とサイズ、更新、空、読み取り専用） | ☑ | `trash_test.dart` T4 |

## ビューワー・動画（#147、#141）

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| V1 | 下部の操作バー（情報／オフライン／端末に保存／アルバムへ／ゴミ箱へ） | ☑ | `viewer_test.dart` V1。「オフライン」は #149 のオフライン保存 |
| V2 | 情報シート（種別・サイズ・日時・保存場所・メモ・講評） | ☑ | `viewer_test.dart` V2。講評は取得中・取れなかった（理由と再読み込み）・講評なしを分けて出し、開いた後に届いても出す（#113） |
| V3 | メモと上部バーの日時・N件目 | ☑ | `viewer_test.dart` V3 |
| V4 | ビューワー内のアルバム追加ピッカー | ☑ | `viewer_test.dart` V4 |
| X1 | 端末に保存（ギャラリーへ） | ◐ | H8 と同じ。Kotlin の MediaStore と保存許可は実機未確認 |
| P1 | 左半分で明るさ、右半分で音量 | ◐ | ドラッグの扱いは `video_view_test.dart`。明るさと音量を変える所は Kotlin で、実機未確認 |
| P2 | 操作ロック、±10秒、リプレイ、リトライ、読み込み中、一時停止アイコン | ☑ | `video_view_test.dart` |
| P3 | 3.5秒で操作バーを隠す | ☑ | `video_view_test.dart`、`viewer_test.dart` P3/V1 |

ビューワーには #141 の動きも入っている（スワイプ、原本のキャッシュと縮小 decode、拡大した端からのページ送り、
表示中の動画だけがコントローラを持つ、背面で止めて戻ったら再開、ロック中は鳴らさない）。
`viewer_paging_test.dart` が通している。

## 転送・オフライン保存（#149）

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| O1 | 選択中のオフライン保存 | ☑ | `transfers_ui_test.dart`、`grid_test.dart` H4 |
| O1-2 | オフライン保存（暗号化端末保存・保存済み表示・全削除） | ☑ | `offline_store_test.dart`、`transfers_ui_test.dart` |
| T1-2 | 転送キュー（一時停止・再開・再試行・取り消し・消す） | ☑ | `transfer_queue_test.dart`、`transfers_ui_test.dart` |
| T2-2 | 画面下の転送バー | ☑ | `transfers_ui_test.dart` 転送バーと転送シート。転送が何件あってもバーは1行で、取り込みの URL 欄をキーボード表示中も塞がない（#106）。先頭の失敗行の「やり直す」は 360x640・文字1.3倍でも画面内で押せ、その行だけやり直す（#111） |
| T3-2 | アップロードの再開耐性と自動再開 | ☑ | `transfer_queue_test.dart` |
| T4-2 | バックグラウンド転送（フォアグラウンドサービス＋通知） | ☑ | Android 実機（Pixel 7 Pro、#174）で確認。タスク一覧から消しても、取り込みとアップロードは通知つきのサービスとエンジンが残って最後まで走る。強制停止・画面オフ・通信断は次の起動か回線の回復で台帳から続きをやる。iOS は裏の長い処理が無いので続きから（B）だけ |
| U1 | アップロード確認画面 | ☑ | `transfers_ui_test.dart` アップロード確認。読み取り専用の判定は #145 の書き込みガード |

アップロードのキーは、KMP 版と同じくファイル名そのままになった（以前の Flutter 版は `uploads/<ミリ秒>-名前`）。
同じ名前がある時は「名前 (2)」〜「名前 (9)」にする。

## 接続・設定（#145）

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| S1 | r2g:// ペアリングリンクの形式互換 | ☑ | `settings_port_test.dart` S1 |
| S2 | ペアリング文字列を貼り付けて接続 | ☑ | `settings_port_test.dart` S2 |
| S3 | 接続入力の補正 | ☑ | `settings_port_test.dart` S3 |
| S4 | 読み取り専用ライブラリへの書き込み禁止 | ☑ | `settings_port_test.dart` S4、`grid_test.dart`・`viewer_test.dart`・`albums_test.dart` の「書き込みガード」 |
| S5 | ゴミ箱の保持日数の案内 | ☑ | `trash_test.dart` T3/S5 |
| S6 | ロックの切り替えと再ロック時間 | ☑ | `settings_port_test.dart` S6、`lock_test.dart` |
| S7 | オフライン保存の件数表示と全削除 | ☑ | `transfers_ui_test.dart` |
| S8 | 接続状態の表示 | ☑ | `settings_port_test.dart` S8 |
| S9 | 起動失敗バナー | ☑ | `settings_port_test.dart` S9 |
| S10 | 接続画面の「スキップ」 | ☑ | `settings_port_test.dart` S10 |
| S11 | 接続の復旧導線（失敗の積み直し、復帰時の再試行） | ☑ | `transfer_queue_test.dart`、`transfers_ui_test.dart` |
| S12 | ライブラリ切替の補助（鍵、切替元の一覧保持） | ☑ | `settings_port_test.dart` S12、`library_switch_test.dart` |

## main に入っていたもの

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| LOCK | 今すぐロック・端末ロック・再ロック時間 | ☑ | `lock_test.dart`、`lock_prefetch_test.dart`。生体認証と FLAG_SECURE の Kotlin 側は実機未確認 |
| WEBDL | アプリ内ブラウザから見つけて R2 に保存 | ☑ | `import_ui_test.dart`、`import_lock_test.dart`、`webdl_*_test.dart` |
