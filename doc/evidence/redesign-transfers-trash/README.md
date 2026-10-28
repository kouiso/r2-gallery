# 転送バー・転送シート・ゴミ箱（再設計 #37 の PR5/5 の一部）

**実機ではなく Compose Desktop（Skia）でのレンダリング**。実際の `TransfersStrip`・`TransfersSheetContent`・
`TrashContent` を `tools/render-harness` で描いたもの（転送中の項目は合成データ、背景は無地）。
フォントは実機と異なる。ModalBottomSheet・ViewModel・実際の通信は描いていない。

| 画面（キャンバス番号） | ファイル接頭辞 |
|---|---|
| 07 転送バー（実行中＋失敗あり） | `10-transfers-strip_*` |
| 07 転送バー（失敗のみ） | `11-transfers-strip-failed_*` |
| 07 転送バー（オフライン・接続待ち） | `12-transfers-strip-offline_*` |
| 07 転送シート（要対応／進行中／待機中／完了） | `13-transfers-sheet_*` |
| 08 ゴミ箱（一覧・復元中） | `14-trash_*` |
| 08 ゴミ箱（空） | `15-trash-empty_*` |
| 08 ゴミ箱（読み込み失敗） | `16-trash-error_*` |
| 08 ゴミ箱（読み取り専用：復元ボタンなし・説明つき） | `29-trash-readonly_*` |
| 08 ゴミ箱（一覧表示中の再読み込み失敗：バナー） | `30-trash-refresh-failed_*` |

サイズ: `320dp×文字1.3`（最も厳しい）／`390dp×1.0`／`390dp×1.3`／`412dp×1.0`。
転送シートは縦スクロールなので、描画画像の下端で切れている行は実機ではスクロールで見える。
