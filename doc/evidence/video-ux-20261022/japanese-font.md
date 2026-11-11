# 日本語字体の固定と検証（2026-10-22）

更新: 新環境でのFlutter描画、フッターの文字継承修正と前後画像は
[追加検証記録](../video-ux-validation-20261022/README.md)を参照。以下の未実行表記は初回実装時点の記録。

## 調査と変更

変更前はアプリの `fontFamily`、`fontFamilyFallback`、`TextStyle.locale` が未指定で、フォント資産も同梱されていなかった。Android のシステムフォントと Web のブラウザ・Flutter エンジンの fallback に依存するため、日本語の同一字形は保証できない構成だった。実画面で中国語字形が出ていたかは未確認。

変更後は正規の環境内資産 Noto Sans CJK **JP** の日本語 face をもとにした `R2GalleryJP` を同梱し、テーマと独自 AppBar/SnackBar の文字に使用する。本文・見出し・ラベルの `TextStyle.locale` は `ja_JP` とする。日本語と英数字が混ざるファイル名・容量・再生時刻も同じ family で描画する。元の fontWeight / fontSize / height / letterSpacing の指定値は変更していない。400/700 以外の太さは Regular/Bold による近似となり、字幅や改行が変わる可能性は残る。

`flutter_localizations` の追加や lockfile 手編集はしていない。MaterialApp の framework locale 解決は既存のままにして、字形は同梱 JP face と TextStyle.locale で指定する。標準 Material 部品の翻訳を日本語化したという変更ではない。

Android では APK 内にフォントを含む。Web ではアプリ自身のフォント資産として配信するため、初回の資産取得は必要だが、外部フォントサービスや日々の追加ダウンロードには依存しない。ブラウザキャッシュの存続・容量・削除はブラウザ管理なので、Web の完全オフライン可用性は保証していない。

## 出典・許諾・収録範囲

- 取得元: 既設 Debian package `fonts-noto-cjk 1:20240730+repack1-1`。ネットワーク取得なし。
- 元ファイル: `/usr/share/fonts/opentype/noto/NotoSansCJK-{Regular,Bold}.ttc` の face 0、`Noto Sans CJK JP`。
- 元版: `Version 2.004;hotconv 1.0.118;makeotfexe 2.5.65603`。
- 正規 upstream: [notofonts/noto-cjk](https://github.com/notofonts/noto-cjk)。ローカル package の copyright とフォント内の著作権・SIL OFL metadata を確認した。
- [OFL 全文](../../../flutter/assets/fonts/OFL.txt)を同梱し、アプリの LicenseRegistry にも登録する。OFL 条項 3 の Reserved Font Name を踏まえ、変更版の family/PostScript/CFF 名は `R2 Gallery JP` / `R2GalleryJP` に変更し、元の著作権表示を保持する。
- JIS X 0213（Python `euc_jis_2004` の両面）、Latin U+0020–024F、一般句読点 U+2000–206F、和文記号・かな U+3000–30FF、かな拡張 U+31F0–31FF、半角・全角 U+FF00–FFEF、および元フォントが提供する対象文字の異体字 selector を保持する。
- GSUB/GPOS の既定・日本語 JAN shaping を保持し、中国語・韓国語 LangSys 専用の置換先を除いた。指定した元フォント対応文字の coverage は削っていない。
- 両 face は各 14,392 Unicode mapping / 16,044 glyph。指定範囲の元フォント対応 14,391 codepoint を包含する。範囲外の文字・絵文字等は既存の platform fallback に委ね、全 Unicode の日本語字形や異体字表示を保証しない。

| 資産    |     bytes | SHA-256                                                            |
| ------- | --------: | ------------------------------------------------------------------ |
| Regular | 4,306,852 | `63563be433f3f9be61a826a7acd3155a4998e60bf9c956e763c527d9cc86c110` |
| Bold    | 4,419,896 | `7a33dd400cd6ea38f9ee836ee8573a03d78ec25a71b08ebd23967683bc5976bd` |

元ファイルの SHA-256 と生成物のサイズ・版は [manifest.json](../../../flutter/assets/fonts/manifest.json) に記録した。再生成には Python と FontTools 4.61.1 が必要で、実行時アプリの依存ではない。

```sh
python tools/fonts/prepare-japanese-font.py
python tools/fonts/verify-japanese-font.py
```

## 実行済みと未検証

[フォント資産検証ログ](font-assets-validation.txt)は実行済み PASS。生成物と元ファイルの hash、JP face、指定範囲 coverage、Regular/Bold family・weight・OFL metadata、既定/日本語 shaping の保持を確認した。代表字「骨・直・令・辺・門・葛・辻・道・週・返」および和文 UI と混在 Latin の outline が元 JP face と一致することを FontTools で検証した。これは Flutter で表示されたという証拠ではない。

合計 **8,726,748 bytes（約 8.32 MiB）** の資産増加がある。最初の試作は地域別の置換先を含み約 16.86 MB だったが、不要な LangSys を除いて削減した。Web の cold start ではフォント転送・復号・レイアウトが動画の初回通信と競合し得る。通信量・APK/Web圧縮後サイズ・キャッシュ cold/warm 時の描画時間・動画開始時間への影響は未測定で、速度改善は主張しない。

実 Flutter の [字体 capture harness](../../../flutter/test/japanese_font_test.dart) を追加した。テーマ、実フォント、代表漢字、かな・英数字、400/700、文字倍率 1.0/2.0 を実 Flutter widget で描画する。既存の footer harness も通常は同梱フォントを読み込む。実行環境の Flutter SDK 取得 403 と Chromium の通常 sandbox 起動失敗（SUID 構成エラー）が既知の障害で、設定公開後の承認済みの同一公式 manifest URLへの1回も403で、SDKは取得できなかった。
[最新結果](flutter-manifest-after-publish.txt)。以後の再試行・迂回は行っていない。Flutter analyze / widget test / Android 実機 / Web 実ブラウザ / 前後 screenshot は **未実行**。画像を代作していない。

SDK が許可済み環境で利用できる際の実行例（リポジトリルートから）:

```sh
cd flutter
flutter test test/japanese_font_test.dart \
  --dart-define=JAPANESE_FONT_EVIDENCE_DIR=../doc/evidence/video-ux-20261022/screenshots \
  --dart-define=JAPANESE_FONT_EVIDENCE_STAGE=after
```

変更前は font 変更直前の基点に同じ harness だけを置き、`JAPANESE_FONT_LOAD_BUNDLED=false` と `JAPANESE_FONT_EVIDENCE_STAGE=before` を指定する。変更前に新フォントを注入せず、同じ viewport・文字倍率・OS/ブラウザ条件で比較する。capture は実行時のみ PNG を出力し、現時点では前後画像は存在しない。次回は代表字形・文字切れ・行間・Latin 混在・実 UI footer に加え、Android/Web 双方の cold/warm 資産転送と初回動画開始を確認する。
