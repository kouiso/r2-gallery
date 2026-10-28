# 写真タブ・アルバムタブ・選択UI（再設計 #37 の PR3/5）

**実機ではなく Compose Desktop（Skia）でのレンダリング**。実際の `HomeContent`・`AlbumsTabContent`・
`SelectionOpsBar`・`BottomTabs`・`MediaGrid` を `tools/render-harness` で描いたもの。
写真は合成グラデーション。フォントは実機と異なる（`tools/render-harness/README.md` 参照）。

| 画面（キャンバス番号） | ファイル接頭辞 |
|---|---|
| 01 写真タブ | `01-photos_*` |
| 02 選択モード（アルバムへ／オフライン／ゴミ箱へ） | `02-photos-selected_*` |
| 05 アルバムタブ（アルバム） | `03-albums_*` |
| 05 アルバムタブ（フォルダ・ゴミ箱の入口） | `04-folders_*` |
| 12 空の状態 | `05-photos-empty_*` |
| 12 読み込み失敗 | `06-photos-error_*` |

サイズ: `320dp×文字1.3`（最も厳しい）／`390dp×1.0`／`390dp×1.3`／`412dp×1.0`。
