title: #122 のサムネ削除を堅くする（期限切れの同名・途中失敗・作成後エラー）
base: fix/rg20-stale-thumbs
head: fix/rg20-thumb-hardening (27de2cd)

## 概要

#122 (RG-20) の上に積んだ PR です（stacked on #122）。#122 がマージされたら base を `main` に付け替えます。#122 の head は変更していません。

レビューの wants 1〜4 に対応します。

- purge: 期限切れエントリと同名の「まだ新しい」ゴミ箱エントリ、または同名の実体が残っている間はサムネを消さない。ゴミ箱を先に全件数えてから判定するので「ゴミ箱にあるものはサムネが残る」が成り立つ
- purge: サムネを本体より先に消す。途中で落ちても期限切れの本体が残り次回また通るので、サムネだけ孤児になることはなく、何度走っても同じ結果
- upload / multipart / copy / move / import: 作成成功後のサムネ削除は best-effort（失敗はログのみ）。META の障害で保存済みの物が 5xx になり、再送で 409・二重保存になるのを防ぐ
- テスト追加: copy / move / import、上記3点（#122 の c0437cf では失敗し、この PR で通ることを確認済み）

対象外: move 元のサムネ孤児（既存の挙動）、purge 時の `.system/trash-albums/` 記録の掃除は別 issue にします。

## 確認

- `pnpm test:worker` 66 件通過、`pnpm lint`、`node .github/ci/run.mjs fast`、`node tools/sync-ai-rules.mjs --check` OK

🤖 Generated with [Claude Code](https://claude.ai/code)

https://claude.ai/code/session_01Cv4a6EYroSzGSReCUes9tm
