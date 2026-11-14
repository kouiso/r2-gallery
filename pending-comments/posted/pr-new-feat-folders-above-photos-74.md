title: フォルダを開いた時、下位フォルダを写真の上に出す
base: main
head: feat/folders-above-photos-74 (31eb486)
body:
## 概要
フォルダの画面で、下位フォルダのカードを写真の後ろ（末尾）から、見出し「フォルダ N」のすぐ下の横に送れる1段へ移しました。デザイン `doc/design/project/review/ReviewFolder.dc.html` に沿っています（カード 112x88・角丸12・地 `#1E1E2B`）。下位フォルダが無い時は段ごと出ません。数が多くても段の高さは変わらず、写真は押し出されません。

## 変更
- `flutter/lib/src/grid/media_grid.dart`: フォルダの段を先頭に出す
- `flutter/test/grid_test.dart`: 下位フォルダが写真より上にある事、無い時は段が出ない事のテスト（main では前者が失敗）

## 補足
- デザインにある「すべて見る」と、見出しの道筋は入れていません（後者は #73 の完了条件外）
- #75（Android 実機の確認）は別作業です

## 注意
main にマージすると本番の Web と APK が配信されます。持ち主の OK を待ってからマージしてください。

Closes #74
Refs #73

🤖 Generated with [Claude Code](https://claude.ai/code)

https://claude.ai/code/session_01Cv4a6EYroSzGSReCUes9tm
