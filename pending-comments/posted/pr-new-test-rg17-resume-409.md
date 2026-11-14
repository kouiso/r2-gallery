title: #121 の再開時 409 経路のテストを足す
base: fix/rg17-same-name-upload
head: test/rg17-resume-409 (5e092d228c367b51f8601c6cab762fec24d2a665)
draft: false

## 位置づけ
#121（`fix/rg17-same-name-upload`）の上に積んだ PR です。#121 が main にマージされたら、base を main に付け替えます。#121 の head（4e24c2a）は変えていません。

## 足したテスト（`flutter/test/transfer_queue_test.dart`）
- 完了は通っていたが応答が落ちた行（uploadId あり・全パート確定）の完了が 409 → 中身が同じなら新しい object を作らず完了（create 0 回・パート送信 0 回）
- 同じ状況で中身が別物 → abort して `name (2).ext` で最初から保存
- 小さいファイルの再開で PUT が 409 → 同じ中身なら完了、別の中身なら `name (2).ext`
- 照合の読み出し（保存済みの取得）が 500 → 完了にせず失敗の行で残り、直れば再試行で完了

## fail-before
origin/main の `flutter/lib/src/transfer/*.dart` に差し替えたコピーで実行。コンパイルは通り、挙動で失敗します（タイムアウト・`Expected: <0> Actual: <1>`・`v (2).mp4` が無い、等。合計 6 件失敗＝追加分 4 件＋#121 の 2 件。小さいファイル・同じ中身のテストは main でも通る：main は 409 を黙って「完了」にするため。その欠陥は「中身が違う」側のテストと照合失敗のテストが捕まえる）。ログは /home/user/wt-rg17b-failbefore.txt。

## 本物の Worker での確認（`flutter/test_live/live_conflict_test.dart`）
`wrangler dev --local`（miniflare R2）に対し、既存キーへの単発 PUT・multipart 開始・multipart 完了（別 upload が先に完了／完了済み uploadId の再完了）がすべて 409 になることを確認（3件成功）。流し方は `flutter/test_live/README.md`。

## 確認の状況
flutter test 482 件成功、`pnpm test:worker` 55/55、sync-ai-rules 一致。`run.mjs fast` は、他の作業でマシンの負荷が高い間（load average 約40）に tools の別テスト（leak-check / index-upload）がタイムアウトで落ちました。このPRは flutter/ だけの変更で、単体で流すと index-upload は 29/29 成功です。

Refs #41 #42 #43

🤖 Generated with [Claude Code](https://claude.ai/code)

https://claude.ai/code/session_01Cv4a6EYroSzGSReCUes9tm
