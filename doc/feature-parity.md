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
| H7 | 長押しの個別メニュー（アルバムに追加／オフライン保存・保存済み削除／ゴミ箱へ、読み取り専用表示） | ◐ | 長押しメニューから「端末に保存」を外した。この廃止は**オーナー承認待ち**。`grid_test.dart` H7。Flutter全614件で実行済み。native実機の範囲は別記 |
| H8 | アプリ内のオフライン保存へ一本化（「端末に保存」の廃止はオーナー承認待ち） | ◐ | 接続別の永続暗号文を維持し、旧Dart/native書き出しを拒否。Android内部保存・backup/端末移行の除外、iOS sandbox/backup属性/端末限定Keychainを設定。保存削除で再生用平文も解放。Webは非対応を明示。Flutter/mock・静的点検のみ実施で、native/実機は未実施。旧exportや旧保存を自動削除しない |
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
| T3 | ゴミ箱の保持期間の案内 | ☑ | `trash_test.dart` T3/S5。Flutter 版のゴミ箱は下のタブではなく、アルバムタブの一覧の末尾（「その他」の下）にある「ゴミ箱」行から開く子画面（`home_shell.dart` の `_TrashChild`、開いている間も下タブはアルバムタブのまま）。入口の行の説明は「移した項目の確認と復元」で、保持期間の案内は開いた先のゴミ箱画面に出す |
| T4 | ゴミ箱行の表示（種類アイコン、日付とサイズ、更新、空、読み取り専用） | ☑ | `trash_test.dart` T4 |

## ビューワー・動画（#147、#141）

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| V1 | 下部の作品操作（情報／オフライン保存／アルバムへ／ゴミ箱へ） | ◐ | ナビゲーション4タブとは役割を分ける。可変高・安全領域・折返し、保存待ちと保存済みを分離。`viewer_test.dart` / `footer_ux_test.dart` を追加・更新、Flutter全614件PASS。Android release APK内のJP font一致を確認。実機画面は未確認。下部操作から「端末に保存」を外した件は**オーナー承認待ち** |
| V2 | 情報シート（種別・サイズ・日時・保存場所・メモ・講評） | ☑ | `viewer_test.dart` V2。講評は取得中・取れなかった（理由と再読み込み）・講評なしを分けて出し、開いた後に届いても出す（#113） |
| V3 | メモと上部バーの日時・N件目 | ☑ | `viewer_test.dart` V3 |
| V4 | ビューワー内のアルバム追加ピッカー | ☑ | `viewer_test.dart` V4 |
| X1 | 外部書き出しの拒否 | ◐ | H8 と同じく「端末に保存」の廃止はオーナー承認待ち。保存操作はアプリ内だけに統一し、古い API も外部書き出しを拒否する。未関連付けの既存内部保存は隔離し、外部保存済みファイルも勝手に変更しない |
| P1 | 明示した「明るさ・音量」パネル | ◐ | #198。mainの縦スワイプによる明るさ・音量調整は残したまま（何も削除していない）、明示パネルを追加した。パネルはこの画面の明るさとこの動画の音量をラベル・現在値付きで調整し、未知の明るさを書き換えない。`video_view_test.dart` を追加、Flutter全614件PASS、Android release build確認。実機の変更量と前後動画は未確認 |
| P2 | 操作ロック、±10秒、リプレイ、リトライ、読み込み中、一時停止アイコン | ☑ | `video_view_test.dart` |
| P3 | 3.5秒で操作バーを隠す | ☑ | `video_view_test.dart`、`viewer_test.dart` P3/V1 |
| P4 | 前景の動画再生中だけ画面保持 | ◐ | Android窓フラグ/Web Screen Wake Lockを実装。`screen_awake_test.dart` 18件とオフライン復帰操作回帰を追加。Android release build確認、実機/ブラウザ未検証 |
| P5 | バックグラウンド再生・ロック画面の操作・PiP | ◐ | #196/#197。Android/iOSの同一playerへsession・OS操作・PiPを接続。背景再生は動画ごとの明示許可。Dart/mock/widgetの回帰614件PASS。Android release build・APK設定/DEX検査PASS（Media3の不正な定数参照1行を修正）。iOS native build・両OS実機は未実施。最新範囲は `doc/evidence/android-build-20261023/README.md`、設計は `doc/evidence/mobile-playback-20261022/README.md` |
| P6 | 初回動画の付加情報取得と保存動画の復号負荷 | ◐ | 動画講評は情報シートまで遅延し、256KiB以上の保存復号は別isolate。mock/合成fixture前後比較と全614件PASS。実機first frameは未測定。`doc/evidence/video-startup-20261022/README.md` |

ビューワーには #141 の動きも入っている（スワイプ、原本のキャッシュと縮小 decode、拡大した端からのページ送り、
表示中の動画だけがコントローラを持つ、背面で止めて戻ったら再開、ロック中は鳴らさない）。
`viewer_paging_test.dart` が通している。

## 転送・オフライン保存（#149）

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| O1 | 選択中のオフライン保存 | ◐ | 接続切替・ロック中の後続保存を止める回帰を追加。`transfers_ui_test.dart`、`grid_test.dart` H4。Flutter全614件で実行済み。native実機の範囲は別記。☑→◐への変更は実機確認待ち・**オーナー承認待ち** |
| O1-2 | オフライン保存（アプリ専用の暗号化保存・接続認可・保存済み表示・容量・削除） | ◐ | `offline_store_test.dart`、`offline_privacy_test.dart`、`private_offline_app_test.dart`、`transfers_ui_test.dart`。旧保存と外部ファイルは移動・削除しない。ただし更新前のオフライン保存は接続先を確認できないため隔離して一覧に出さない（`offline_screen.dart:157`、移行なし）。この隔離は**オーナー承認待ち**。Flutter全614件で実行済み。native実機の範囲は別記。☑→◐への変更は実機確認待ち・**オーナー承認待ち** |
| T1-2 | 転送キュー（一時停止・再開・再試行・取り消し・消す） | ☑ | `transfer_queue_test.dart`、`transfers_ui_test.dart` |
| T2-2 | 画面下の転送バー | ☑ | `transfers_ui_test.dart` 転送バーと転送シート。転送が何件あってもバーは1行で、取り込みの URL 欄をキーボード表示中も塞がない（#106）。先頭の失敗行の「やり直す」は 360x640・文字1.3倍でも画面内で押せ、その行だけやり直す（#111） |
| T3-2 | アップロードの再開耐性と自動再開 | ☑ | `transfer_queue_test.dart` |
| T4-2 | バックグラウンド転送（フォアグラウンドサービス＋通知） | ☑ | Android 実機（Pixel 7 Pro、#174）で確認。タスク一覧から消しても、取り込みとアップロードは通知つきのサービスとエンジンが残って最後まで走る。強制停止・画面オフ・通信断は次の起動か回線の回復で台帳から続きをやる。iOS は裏の長い処理が無いので続きから（B）だけ |
| U1 | アップロード確認画面 | ☑ | `transfers_ui_test.dart` アップロード確認。読み取り専用の判定は #145 の書き込みガード |

アップロードのキーは、KMP 版と同じくファイル名そのままになった（以前の Flutter 版は `uploads/<ミリ秒>-名前`）。
同じ名前がある時は「名前 (2)」〜「名前 (9)」にする。

HEIC・HEIF・BMP は一覧に出る。原本は作り変えずに保存し、Android のアプリが端末の読み込みで表示する。
HEIC を読めない環境（Web 版の Chrome・Edge・Firefox、Android 7.0〜8.1）には、Worker が JPEG の写しを返す。原本は変えない。

## 接続・設定（#145）

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| S1 | r2g:// ペアリングリンクの形式互換 | ☑ | `settings_port_test.dart` S1 |
| S2 | ペアリング文字列を貼り付けて接続 | ☑ | `settings_port_test.dart` S2 |
| S3 | 接続入力の補正 | ☑ | `settings_port_test.dart` S3 |
| S4 | 読み取り専用ライブラリへの書き込み禁止 | ☑ | `settings_port_test.dart` S4、`grid_test.dart`・`viewer_test.dart`・`albums_test.dart` の「書き込みガード」 |
| S5 | ゴミ箱の保持日数の案内 | ☑ | `trash_test.dart` T3/S5 |
| S6 | ロックの切り替えと再ロック時間 | ☑ | `settings_port_test.dart` S6、`lock_test.dart` |
| S7 | オフライン保存の件数・容量表示と全削除 | ◐ | 現在の接続で認可された保存のみ。`transfers_ui_test.dart`。Flutter全614件で実行済み。native実機の範囲は別記。☑→◐への変更は実機確認待ち・**オーナー承認待ち** |
| S8 | 接続状態の表示 | ☑ | `settings_port_test.dart` S8 |
| S9 | 起動失敗バナー | ☑ | `settings_port_test.dart` S9 |
| S10 | 接続画面の「スキップ」 | ☑ | `settings_port_test.dart` S10 |
| S11 | 接続の復旧導線（失敗の積み直し、復帰時の再試行） | ☑ | `transfer_queue_test.dart`、`transfers_ui_test.dart` |
| S12 | ライブラリ切替の補助（鍵、切替元の一覧保持） | ☑ | `settings_port_test.dart` S12、`library_switch_test.dart` |
| S13 | エラーの詳しい理由を画面に出す切り替え（#237。既定は OFF、トークン・署名は伏せる） | ☑ | `error_details_test.dart`、`settings_headings_test.dart` |

## main に入っていたもの

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| LOCK | 今すぐロック・端末ロック・再ロック時間 | ☑ | `lock_test.dart`、`lock_prefetch_test.dart`。生体認証と FLAG_SECURE の Kotlin 側は実機未確認 |
| WEBDL | アプリ内ブラウザから見つけて R2 に保存 | ☑ | `import_ui_test.dart`、`import_lock_test.dart`、`webdl_*_test.dart` |

## 重複・似ている写真

設定タブの入口を、中身が同じ物だけを出す `DuplicatesScreen`（#106）から、見た目の照合も入れた `SimilarScreen` に
付け替えた（入口の文字は「重複・似ている写真を探す」）。古い画面の機能を1つも落としていないかを、この表で突き合わせる。
`DuplicatesScreen` は消さずに残し、見た目の照合に対応していない古い Worker（`/similar/status` が 404）ではそのまま出す。

この節だけ、☑・☐ に加えて次の印を使う。

- △：機能はあり、Dart の流れか Worker のテストでは通しているが、Flutter の画面の操作としてはテストで通していない
  （下の「残っている穴」）

手元の Worker と合成画像だけで画面を通した記録は `doc/evidence/similar-local/README.md`。

### 古い画面にあった物

| ID | 機能 | 新しい場所 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|---|
| D1 | 中身が同じ物の組 | 「重複」の段の「同じファイル」 | ☑ | `similar_screen_test.dart`「オリジナルに札が付き…」、`similar.test.ts`「同じ中身の束（/duplicates）は、全部が重複の段に…」（`/duplicates` の組がどれも「同じファイル」で出る） |
| D2 | 既定で一番古い物を残す | 「オリジナル」の札 | ☑ | `core.test.ts`「keeps the oldest member of an exact node…」。見た目だけの組では、原本の画素数 → PNG → バイト数 → 古い順に変わる（README「見た目の照合」） |
| D3 | 残す物を選び直す（「こちらを残す」） | 長押しの「オリジナルにする」 | ☑ | `similar_screen_test.dart`「長押しからオリジナルを選び直すと…」、`similar_controller_test.dart`「relabel の札に入れ替え…」、`similar.test.ts`「残す物を変えると…」。新しいオリジナルと別物と分かった物は選べなくなる |
| D4 | 1件ずつゴミ箱へ | 長押しの「この1件だけゴミ箱へ」、または丸いチェックで1件だけ選んで下のボタン | ☑ | `similar_screen_test.dart`「長押しからこの1件だけゴミ箱へ送れる」、`similar_controller_test.dart`「長押しの1件だけゴミ箱は他の選択に触らない」。古い画面のように札の下に「ゴミ箱へ」ボタンは並べず、長押しの中に移した |
| D5 | 消した後の「元に戻す」 | 同じ6秒のスナックバー（`offerOptimisticTrashUndo`）。中身は `POST /similar/undo` | ☑ | `similar_screen_test.dart`「確かめの文に…後で元に戻せる」、`similar_controller_test.dart`「取り消しは 40 件ずつ…」、`similar-trash.test.ts`「消す前のアルバムにそのまま戻し…」、本物の Worker に対しては `test_live/live_similar_test.dart` |
| D6 | まだ確認できていない物・大きすぎて確認できなかった物の件数 | 重複の段の見出しの内訳（「まだ中身を確認できていない物」「大きすぎて中身を確認できなかった物」に、見た目の照合の内訳が加わる） | ☑ | `similar_screen_test.dart`「まだ中身を確認できていない物があれば、その件数を重複の段の頭に出す」（`hashPending`）、「大きすぎて…」と照合の内訳は同じファイルの一覧のテスト |
| D7 | 読み取り専用ライブラリの案内（組は見せ、消させない） | 同じ。チェックと下のボタンを出さない | ☑ | `similar_screen_test.dart`「読み取り専用のライブラリでは組だけ見せ…」、`similar-trash.test.ts`（403） |
| D8 | タップでビューアを開き、ビューアで消したら読み直す | 同じ | ☑ | `similar_screen_test.dart`「タップでビューアを開く」「ビューアでゴミ箱へ送って閉じると一覧を読み直す」（`onChanged` → `reload`） |
| D9 | 続きのページを読む | 同じ（末尾が見えたら次の組を読む。失敗したら「続きを読み込む」） | ☑ | `similar_screen_test.dart`「末尾まで来たら続きのページを読む」、`similar_controller_test.dart`「すべての重複は先に全ページを読み…」「「すべての重複」の後に届いた古い続きのページは…」、`similar.test.ts`「カーソルで 1 束ずつたどっても…」「消した後もカーソルがずれない」 |
| D10 | 古い Worker（404）の案内 | 見た目の照合の 404、または大きすぎて見た目の照合を断るライブラリ（`/similar/status` の `tooMany`、413 `too_many_for_similar`）では古い画面へ。上限を超える時は照合を始めず、写真の枚数・上限・PC ツールを古い画面の上に出す。一覧の口だけが落ちた時（5xx など）はエラーの画面から「同じファイルだけを探す」で古い画面へ移れる。古い画面は、重複の確認も無い Worker では今までどおり「まだ重複の確認に対応していません」 | ☑ | `similar_screen_test.dart`「見た目の照合が無い古い Worker（404）では…」「見た目の照合を断る大きなライブラリ（413）では…」「上限を超えると status が言えば…」「一覧の口だけが落ちた時は…」、`similar_controller_test.dart`「一覧の 413 too_many_for_similar は…」「status が上限を超えると言えば…」、`duplicates_screen_test.dart`「古い Worker の 404 は未対応と出す」「設定タブから開き、見た目の照合が無い古い Worker では…」 |
| D11 | 失敗した時の再試行 | 同じ | ☑ | `similar_screen_test.dart`「読めなかったら再試行で読み直せる」、`similar_controller_test.dart`「status のそれ以外の失敗は error で…」 |
| D12 | 中身の計算の進み具合（「確認中… あと N 件」、画面を離れたら止まる） | 「中身を確認中… あと N 件」 | ☑ | `similar_screen_test.dart`「中身の計算の途中は残りの件数を出す」、`similar_controller_test.dart`「計算 → 状況 → 照合…」「計算が進まなくなったら打ち切って…」「dispose: 計算の繰り返しを止める」 |
| D13 | アップロード前の「もうある」確認 | 変えていない | ☑ | `upload_check_test.dart`、`duplicates_api_test.dart` |

### 新しく加わった物

| ID | 機能 | 状態 | 確かめているテスト・補足 |
|---|---|---|---|
| N1 | 「重複」「似ている」の2つの段、札（同じファイル／ほぼ同じ／反転／差分かも／似ている） | ☑ | `similar_screen_test.dart`「オリジナルに札が付き…」、`similar.test.ts`「重複の束: …」「似ている束は別の段に…」、`core.test.ts` の pair labels。似ている段には「別の絵のこともあります」の案内 |
| N2 | 「すべての重複」（全ページを読んでから、同じファイルとほぼ同じだけ。反転・差分かも・似ている・オリジナルは選ばない） | ☑ | `similar_screen_test.dart`「「すべての重複」は残りのページを読み切ってから…」、`similar_controller_test.dart`「すべての重複は先に全ページを読み…」「ページを読み切れなければ何も選ばない」 |
| N3 | まとめてゴミ箱へ（40件ずつ、同時に2本、進み具合と中止） | ☑ | `similar_controller_test.dart`「40 件ずつ、同時に 2 本までで送り…」「中止したら…」、`similar_screen_test.dart`（進み具合のダイアログ）、`similar-trash.test.ts`「アルバムの書き込みは 1 回…」 |
| N4 | 確かめの文に種類ごとの件数、似ている・差分かもを含む時の注意 | ☑ | `similar_screen_test.dart`「確かめの文に種類ごとの件数…」「似ている物や差分かもを選ぶと…」。件数が 0 の種類は文に出さない |
| N5 | 直後の「元に戻す」はアルバムまで消す前と同じに戻す | ☑ | `similar-trash.test.ts`「消す前のアルバムにそのまま戻し、消した時に入れた残す物を外す」、`test_live/live_similar_test.dart` |
| N6 | アルバムでは消した物の場所にオリジナルが入る。ゴミ箱から1件戻すと元の位置へ戻る（同じファイルとして消した物は、オリジナルがいるアルバムへは戻らない） | ☑ | `similar-trash.test.ts`「ファイルを移し、消した物の位置に残す物を入れ…」「ゴミ箱から戻すと元の位置へ戻り…」「同じファイルとして消した物は…」 |
| N7 | 移せなかった物を元の組の元の位置へ戻し、件数を知らせる | ☑ | `similar_screen_test.dart`「移せなかった物は元に戻して件数を知らせる」、`similar_controller_test.dart`「一部が移せなければ…」 |
| N8 | 見た目の照合の同意（残り 300 件超で通信量を見せる）と、この端末での照合（続きから・画面を消さない・途中の結果） | ☑ | `similar_screen_test.dart`「照合が 300 件を超えると…」「300 件以下ならすぐ照合し…」「Web の同意の画面では…」、`signature_backfill_test.dart`、`visual_signature_test.dart` |
| N9 | Web ではサムネのある物だけ照合し、無い物は「この端末では照合できない物」と出す | ☑ | `similar_controller_test.dart`「Web はサムネのある物だけを数え…」、`signature_backfill_test.dart`「Web でサムネの無い物は手を付けずに残す」 |
| N10 | PC ツール（読み取り専用の報告・適合率・署名の書き込み） | ☑ | `tools/similar-signatures.test.mjs`。本物の手元の Worker に対しては `doc/evidence/similar-local/`（手順 3） |

### 残っている穴

- 実機（Android の FAD 版）と本番の Worker では通していない。サムネの無い物を端末で縮小して置く流れ（Android だけの経路）は
  fake のテストと `test_live/live_similar_test.dart`（Dart の VM で動く）だけ。
