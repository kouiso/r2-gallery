title: Web 版の名前・説明・起動色をアプリに合わせる
base: main
head: fix/web-manifest-60 (0ef025c)
body:
## 概要
Web 版に残っていた Flutter 雛形の表記を直しました（#60 のとおり）。
- `flutter/web/manifest.json`: name・short_name を「R2 Gallery」、background_color・theme_color をアプリの地の色 `#0A0A0F`（`AppColors.bg`）、description を雛形の文から変更
- `flutter/web/index.html`: title・apple-mobile-web-app-title を「R2 Gallery」、description を変更
- `flutter/pubspec.yaml`: description を変更
- `tools/web-manifest.test.mjs`: 上記の値を確かめるテストを追加（main では失敗）

## 確認
`flutter build web --release` したものをヘッドレス Chrome で開き、タブ名が「R2 Gallery」になる事を確かめました。アイコンは #59 の対象外です。

## 注意
main にマージすると本番の Web と APK が配信されます。持ち主の OK を待ってからマージしてください。

Closes #60
Closes #59

🤖 Generated with [Claude Code](https://claude.ai/code)

https://claude.ai/code/session_01Cv4a6EYroSzGSReCUes9tm
