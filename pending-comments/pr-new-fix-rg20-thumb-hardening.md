title: #122 のサムネ削除を堅くする（期限切れの同名・途中失敗・作成後エラー）
base: fix/rg20-stale-thumbs
head: fix/rg20-thumb-hardening (6c3d440)

## 概要

#122 (RG-20) の上に積んだ PR です（stacked on #122）。#122 がマージされたら base を `main` に付け替えます。#122 の head は変更していません。

レビューの wants 1〜4 に対応します。

- purge: 期限切れエントリと同名の「まだ新しい」ゴミ箱エントリ、または同名の実体が残っている間はサムネを消さない。ゴミ箱を先に全件 list してから判定するので「ゴミ箱にあるものはサムネが残る」が成り立つ
- purge: 期限切れを `PURGE_BATCH`（100件）ずつ、「サムネ → 本体」の順に完結させる。途中で落ちても済んだ batch の本体は消えているので、実行のたびに必ず先へ進む。落ちた batch は本体が残るので次回やり直され、サムネだけ孤児にならない。冪等
- 注意: META の障害が長く続く間は、サムネ削除で止まるため purge が進まない（再試行できる側に倒れる設計）
- upload / multipart / copy / move / import: 作成成功後のサムネ削除は best-effort（失敗はログのみ）。META の障害で保存済みの物が 5xx になり、再送で 409・二重保存になるのを防ぐ
- テスト追加: copy / move / import、上記の各点、multipart complete の META 失敗でも 201、purge が途中失敗を挟んでも次の実行で進むこと

#122 の c0437cf で失敗するのは5件（同名の期限切れ＋新しい項目、purge の順序、作成後エラーで 5xx にしない、import、batch の途中失敗）。copy / move のテストは base でも通り、カバレッジを足すだけです。

対象外（issue は未作成、作成後に番号を記載）: move 元のサムネ孤児（既存の挙動）、purge 時の `.system/trash-albums/` 記録の掃除。issue to be filed.

## 確認

- `pnpm test:worker` 68 件通過、`pnpm lint`、`node .github/ci/run.mjs fast`、`node tools/sync-ai-rules.mjs --check` OK

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01Cv4a6EYroSzGSReCUes9tm
