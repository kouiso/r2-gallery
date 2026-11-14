title: fix: 検知一覧のサムネが一度の失敗や data: の表紙で出ないままになるのを直す
base: main
head: fix/39-detected-thumb (099833f)
---
Refs #39

## 何を直したか
検知一覧（取り込み）のサムネがアイコンのままになる経路を 2 つ、コードとテストで確認して直しました。`flutter/lib/src/webdl/detected_thumb.dart`

1. **失敗が居座る**: 取れなかった（null）結果も成功と同じようにキャッシュしていたため、一時的な通信失敗が 1 回あると、一覧を開いている間ずっとアイコンのままでした。失敗は 30 秒（`failureTtl`）だけ覚え、期間内は通信せず（スクロールで同じ失敗を叩かない）、過ぎたら次の表示で取り直します。
2. **`data:` の表紙を読めない**: 動画の `poster` が `data:` URL の時、HTTP の取得役に渡して失敗し、表紙が使われませんでした（`_poster`）。通信せずその場で読み、http(s) と同じ上限（16MB）で縮小します。

## テスト（main では失敗、この PR では成功）
- `一時的に取れなかった画像は、期間を置いた次の表示で取り直す（失敗が居座らない）`
- `動画の表紙が data: URL の時は、通信せずその絵を縮小して使う`

main の実装に戻して同じ 2 件を流すと 2 件とも失敗することを確認済みです。

## 確認したこと / していないこと
- `flutter analyze`: 7 infos（main と同数。今回は増減なし。#83 で別 PR）
- `flutter test`: 476 件成功、失敗 0。全体を流した 1 回目だけ `pin_test` の時間計測テストが負荷で落ちたが、単独・再実行で成功（この変更と無関係）
- `RUNNER_TEMP=… node .github/ci/run.mjs fast`: 成功 / `node tools/sync-ai-rules.mjs --check`: 成功
- **実機での再現は未確認**です。報告の実際の症状（どのサイト・どの形式か）が分かっておらず、上の 2 つが報告の原因だったとは断定していません。#39 を閉じる材料（実機証跡）はこの PR にありません。
- 見た目の変更は無い（既存の行の描画は同じ）ため、スクリーンショットはありません。

## 注意
main へのマージは本番の Web / APK の配布を走らせます。持ち主の OK を待ってからマージしてください。

🤖 Generated with [Claude Code](https://claude.ai/code)

https://claude.ai/code/session_01Cv4a6EYroSzGSReCUes9tm
