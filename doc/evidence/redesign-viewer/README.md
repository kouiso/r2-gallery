# ビューア・情報シート（再設計 #37 の PR4/5）

**実機ではなく Compose Desktop（Skia）でのレンダリング**。実際の `ViewerTopBar`・`ViewerMemo`・
`ViewerActionBar`・`ViewerInfoContent` を `tools/render-harness` で描いたもの（背景の写真は合成グラデーション）。
フォントは実機と異なる。ページャー・動画再生・ModalBottomSheet・Dialog は描いていない。

| 画面（キャンバス番号） | ファイル接頭辞 |
|---|---|
| 03 ビューア（画像・メモあり） | `07-viewer_*` |
| 03 ビューア（動画・オフライン保存済み） | `08-viewer-video-saved_*` |
| 04 情報シート（保存場所・メモ・レビュー） | `09-viewer-info_*` |

サイズ: `320dp×文字1.3`（最も厳しい）／`390dp×1.0`／`390dp×1.3`／`412dp×1.0`。
320dp×1.3 では操作ラベルが2行に折り返す（「アルバムへ」は「アルバム／へ」）が、消えない。
