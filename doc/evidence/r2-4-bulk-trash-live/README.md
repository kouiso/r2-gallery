# 複数選択→ゴミ箱を本物の Worker に通した記録（2026-10-19）

## 何を確かめたか

それまでの ☑（H4／H9／H10／T1）は fake API のテストだけで、Flutter の `bulkTrash` →
`POST /v1/:lib/ops/trash` が本物の Worker の中身を動かすかは誰も通していなかった。
ここでは手元の Worker（`wrangler dev --local`、miniflare の R2）に対して、本物の画面（`HomeShell`）と
本物の `ApiClient` で通し、Worker 側を読み直して結果を確かめた。

| 対象                       | 操作                                | 確かめた結果                                                                                                               |
| -------------------------- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| 書けるライブラリ `a`       | 4枚を長押し→すべて選択→「ゴミ箱へ」 | `POST /v1/a/ops/trash` が4回 200。`bulk/` の一覧が空になり、`.trash/<時刻>/bulk/p*.png` が4件                              |
| 同上                       | 出てきた「元に戻す」を押す          | `POST /v1/a/ops/restore` が4回 200。`bulk/` に4件が元のキーで戻り、ゴミ箱は0件                                             |
| 読み取り専用ライブラリ `b` | 長押し                              | 選択には入る（オフライン保存は読むだけで済むため。KMP 版と同じ）。「ゴミ箱へ」「アルバムへ」は出ず、「オフライン」だけ出る |
| 同上                       | API で直接 `POST /v1/b/ops/trash`   | 403。`ro/` の2件はそのまま残る                                                                                             |

- 画面とテスト: `flutter/test_live/live_trash_test.dart`（流し方は `flutter/test_live/README.md`）
- Worker の設定: `worker/wrangler.live-trash.toml`（確認用の固定トークン。本番の値ではない）
- テストの出力: [flutter-test.txt](flutter-test.txt)
- Worker が受けた要求: [worker-requests.txt](worker-requests.txt)

## 確かめていないこと

- 実機（Android の FAD 版）で、本番の Worker に対して押した結果。これは 430 で持ち主が確かめる。
- 画像の表示そのもの（テストではサムネの取得を外へ出していない。ゴミ箱の動きとは別の話）。
