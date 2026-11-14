title: 複数枚の「元に戻す」後に残る並びの控えを掃除し、復元を線形時間にする
base: fix/rg19-trash-album-restore
head: fix/rg19-trash-order-prune
draft: false

## 概要
#120 に積む続きの PR です（#120 の head は変えていません。#120 が先にマージされたら base を main に付け替えます）。#120 の再レビューで出た want を対応します。

## 変更
- `trashOrder`（アルバムごとの「ゴミ箱の物も含めた並び」）が増え続けないようにしました。trash・restore・`items/remove` のたびに、アルバムにも今のゴミ箱にも無い key を落とし、ゴミ箱の物が無くなれば `trashOrder` ごと消します。「今ゴミ箱にいるか」は、控え（`.system/trash-albums/<lib>/<epoch>/<key>.json`）と `.trash` 側の実体の両方で見ます。期限切れ purge は控えを消さないので、実体が無ければ purge 済みと見なします（objects.ts には触れていません）。
- `insertByTrashOrder` を O(n) にしました（現在位置の Map を一度だけ作る）。#120 の再レビューで、2000件で約111ms、5000件で約530ms だった箇所です。
- テストを追加しました。8件を `Promise.all` で並行に送り、1件ずつ戻して元の並び・`trashOrder` が消えること（#120 の本文の「8件並行」は、#120 のテストでは2件だったので、この PR で8件のテストを足します）／捨てて戻さないまま purge された key と `items/remove` で外した key が `trashOrder` から落ちること／ゴミ箱の物が無くなれば `trashOrder` が消えること／2000件のアルバムで3件を送って戻し、並びが元どおりになること。

## 計測
2000件のテストは単独で約180ms（miniflare、他のテストと並行せず）。時間の assert はぶれるので入れず、正しさだけを assert しています。

## 残り
- purge で控えファイルそのものが消えない件は #51 で扱います（コメント案: issue-51-comment.md）。
- 控えを書いた後、同じ物が別のアルバムへ同時に足され、さらに控えの書き直しが失敗する窓は受け入れています（#120 の CodeRabbit スレッドの返信案を参照）。

## テスト
`pnpm test:worker` 67 passed / 0 failed、`pnpm lint` ok、`node .github/ci/run.mjs fast` ok、`sync-ai-rules --check` ok。

マージで本番の Web/APK がデプロイされるため、マージはオーナーの判断を待ちます。

Refs #48 #49

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01Cv4a6EYroSzGSReCUes9tm
