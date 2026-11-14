title: chore: flutter analyze の指摘を 0 件にする
base: main
head: chore/83-analyze-clean (337a5ae)
---
Closes #83

## 何をしたか
main の `flutter analyze` の指摘 7 件（すべて info）を 0 件にしました。動作は変えていません。

- `use_null_aware_elements`（`client.dart` 3 か所）: `if (cursor != null) 'cursor': cursor` を `'cursor': ?cursor` に
- `camel_case_types`: `Page_` を `PageOf` に（参照は `models.dart` 内のみ）
- `unnecessary_import`: `app_state.dart` の `dart:typed_data`
- `avoid_renaming_method_parameters`: `SelKey.operator==` の引数名 `o` を `other` に
- `overridden_fields`: `test/import_gallery_test.dart` の `_App` を、フィールドの上書きから getter の上書きに

## 確認（main では 7 件、この PR では 0 件）
- main: `flutter analyze` → 7 issues found
- この PR: `flutter analyze` → No issues found!
- `flutter test`: 474 件成功、失敗 0
- `node .github/ci/run.mjs fast`、`node tools/sync-ai-rules.mjs --check`: 成功

## 補足
- 依頼では `detected_thumb.dart` の `_poster` も指摘に含まれる想定でしたが、main の `flutter analyze` にその指摘はありません（上の 7 件のみ）。そのため #39 の PR とは重なっておらず、この PR は main から独立して作っています。
- 見た目の変更は無いため、スクリーンショットはありません。

## 注意
main へのマージは本番の Web / APK の配布を走らせます。持ち主の OK を待ってからマージしてください。

🤖 Generated with [Claude Code](https://claude.ai/code)

https://claude.ai/code/session_01Cv4a6EYroSzGSReCUes9tm
