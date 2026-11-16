# デザインの写し（r2-gallery デザイン）

- 正: デザインアーティファクト <https://claude.ai/artifact/6NsgHfP9kH9whED6j4ec26>（種類: Design、題名「r2-gallery デザイン」）
- 写した版: `1794408011-d892`
- 写した日時: 2026-11-12 05:00 UTC（`date -u` の値）

正はアーティファクトです。この写しは、実装する人と AI がリポジトリの中で読むための物です。
アーティファクトと食い違ったら、アーティファクトを正とします。アーティファクトが更新されたら、写しも取り直します。

## 置いた物

`project/` の下は、アーティファクトの `project/` をそのまま（1 バイトも変えずに）置いた物です。

- `project/canvas.json`: キャンバスの目次。画面ごとの名前・大きさ・どのページに載るか・並び順。
- `project/**/*.dc.html`: 画面 1 枚ごとの HTML（31 枚）。

各 `.dc.html` は `./support.js`（アーティファクトの種類が持つ描画用スクリプト）を読む作りなので、このリポジトリの中で開いても、そのままでは描けません。
見た目を確かめる時はアーティファクトを開いてください。文言・色・寸法・部品の並びは HTML を読めば分かります。

## 画面の一覧

キャンバスは 3 ページです。今の正は「現行画面・新規機能」と「レビュー提案（11/11）」です。
「リデザイン（10/11）」は、廃止した KMP 版に向けた記録です（色が青、ファイルの場所が古い）。

### 現行画面・新規機能（10/27、11/11 修正）

| ファイル | 画面 |
|---|---|
| `project/Main.dc.html` | 現行 · 写真タブ |
| `project/Albums.dc.html` | 現行 · アルバムタブ |
| `project/Import.dc.html` | 現行 · 取り込みタブ |
| `project/Settings.dc.html` | 現行 · 設定タブ |
| `project/Lock.dc.html` | 現行 · ロック画面 |
| `project/Connect.dc.html` | 現行 · 接続画面 |
| `project/Viewer.dc.html` | 現行 · 動画ビューア |
| `project/Logo.dc.html` | #103 ロゴ案（案A / 案B） |
| `project/PipPlayer.dc.html` | #197 小窓ボタン付きプレイヤー |
| `project/PipWindow.dc.html` | #197 他アプリ上の小窓 |
| `project/PipBlocked.dc.html` | #197 小窓が使えない時の案内 |
| `project/Background.dc.html` | #196 バックグラウンド再生（通知・ロック画面） |

### レビュー提案（11/11）

| ファイル | 画面 |
|---|---|
| `project/review/ReviewSettings.dc.html` | 提案 · 設定（見出しで区切る・接続先の変更・版数） |
| `project/review/ReviewConnectEdit.dc.html` | 提案 · 接続先を変更 |
| `project/review/ReviewFolder.dc.html` | 提案 · フォルダ（下位フォルダを上に） |
| `project/review/ReviewLock.dc.html` | 提案 · ロック画面（文言） |
| `project/review/ReviewFoundation.dc.html` | 見た目の土台（現行と提案） |

### リデザイン（10/11・KMP版向けの記録）

| ファイル | 画面 |
|---|---|
| `project/redesign/Main.dc.html` | 01 写真タブ（ホーム） |
| `project/redesign/Select.dc.html` | 02 選択モード |
| `project/redesign/Viewer.dc.html` | 03 ビューア |
| `project/redesign/ViewerInfo.dc.html` | 04 ビューア 情報シート |
| `project/redesign/Albums.dc.html` | 05 アルバムタブ |
| `project/redesign/AlbumDetail.dc.html` | 05b アルバム詳細（1件選択中） |
| `project/redesign/Upload.dc.html` | 06 アップロード確認 |
| `project/redesign/Transfers.dc.html` | 07 転送シート |
| `project/redesign/Trash.dc.html` | 08 ゴミ箱 |
| `project/redesign/Import.dc.html` | 09 取り込み（Web） |
| `project/redesign/Settings.dc.html` | 10 設定 |
| `project/redesign/Lock.dc.html` | 11 ロック |
| `project/redesign/States.dc.html` | 12 状態（空・エラー・取り消し・未接続） |
| `project/redesign/Spec.dc.html` | 13 実装仕様（KMP版向けの記録） |

## 写さなかった物と理由

| 物 | 理由 |
|---|---|
| `index.html`、`SKILL.md`、`artifact-type/` の下（編集画面のスクリプト・CSS・翻訳・フォント・参考文書・サムネイル） | アーティファクトの種類（Design）が持つ編集画面の部品で、このデザインの中身ではないため。 |
| `support.js` | アーティファクトの配信時に付く描画用スクリプトで、デザインの中身ではないため。 |
| 画像・動画 | このデザインは画像や動画を持っていない（アップロード無し。写真の所は色の四角）。 |

## 写す前に確かめた事

このリポジトリは公開なので、写す 32 ファイルの全文を読んで、次の物が無い事を確かめました。

- 実名・メール・電話番号・鍵・トークン・実在の接続先（Worker の URL、バケット名、アカウント ID）・個人の写真や動画
- 外へ読みに行く URL は Google Fonts（Noto Sans JP）だけ
- 接続先・ライブラリ名・ファイル名などは `[接続先ホスト]` `[ライブラリ1]` のような仮の値か、`example.com` などの例示用の名前
