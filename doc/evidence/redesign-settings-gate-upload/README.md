# 設定・ロック・接続・アップロード確認・取り込み（再設計 #37 の PR5/5 の残り）

**実機ではなく Compose Desktop（Skia）でのレンダリング**。実際の `SettingsContent`・`LockContent`・
`NoCredentialContent`・`ConnectContent`・`UploadConfirmContent`・`DetectionBar`・`DetectedSheetContent` を
`tools/render-harness` で描いたもの。フォントは実機と異なる。ModalBottomSheet・認証ダイアログ・WebView・
実際の通信は描いていない。取り込みシートの行アイコンは確認用に共通の丸アイコンで代用している
（実機では種類ごとに 動画/音声/画像/ファイル）。

| 画面（キャンバス番号） | ファイル接頭辞 |
|---|---|
| 10 設定（接続中・ロックON） | `17-settings_*` |
| 10 設定（未接続・画面ロック無し・オフライン0件） | `18-settings-nolock-disconnected_*` |
| 11 ロック | `19-lock_*` / `20-lock-failed_*` |
| 12 画面ロック無し | `21-no-credential_*` |
| 12 接続 | `22-connect_*` / `23-connect-unreachable_*` |
| 06 アップロード確認（複数・サイズ不明あり） | `24-upload-confirm_*` |
| 06 アップロード確認（読み取り専用） | `25-upload-confirm-readonly_*` |
| 09 取り込み（検出バー・たたんだ1行。ページに重ねず下に場所を取る） | `26-import-bar_*` |
| 09 取り込み（検出シート・未接続／読み取り専用） | `27-import-sheet_*` / `28-import-sheet-noconn_*` / `31-import-sheet-readonly_*` |

サイズ: `320dp×文字1.3`（最も厳しい）／`390dp×1.0`／`390dp×1.3`／`412dp×1.0`。
設定・シートは縦スクロールなので、画像の下端で切れている行は実機ではスクロールで見える。
