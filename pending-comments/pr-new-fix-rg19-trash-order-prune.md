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

## レビュー指摘の対応
- 「今ゴミ箱にいるか」は、控えがあり、かつ `.trash` の実体も元の key も無い物だけを purge 済みと見なす。restore は実体を先に元の key へ戻してからアルバムを更新するので、元の key も見ないと、その間に別の操作が刈り込みを走らせた時に戻している途中の物の枠が落ちる（#120 の head では起きない後戻りだった）。回帰テスト2件（ファイルが戻った後に `items/remove` が入る／同じ状態で同じアルバムの別の物を trash する）は、直す前の head では `[a, c, b]` で失敗し、直した後は `[a, b, c]` で通る。
- 控えの一覧（`META.list`）と head の結果は、1リクエストの中で使い回す。`mutateAlbums` がやり直す時だけ捨てる（並行した trash が書いた控えを見落として落とさないため）。
- 誤ってコミットされていた `node_modules` のシンボリックリンクを外し、`.gitignore` の `node_modules/` を `node_modules` にして、リンクも無視されるようにした（このPRの範囲外の変更だが、再発防止のために含める）。新しい detached worktree で `pnpm install --frozen-lockfile` が通ることを確認した。

## 計測
2000件のテストは単独で約180ms（miniflare、他のテストと並行せず）。時間の assert はぶれるので入れず、正しさだけを assert しています。O(n) になったことの根拠はこの計測（と、#120 の再レビューでの修正前の計測、2000件で約111ms）です。

## 残り
- purge で控えファイルそのものが消えない件は #51 で扱います（コメント案: issue-51-comment.md）。
- 控えを書いた後、同じ物が別のアルバムへ同時に足され、さらに控えの書き直しが失敗する窓は受け入れています（#120 の CodeRabbit スレッドの返信案を参照）。

## テスト
#120 の head（01936fb）では刈り込みの2件だけが落ちます。restore の枠の回帰2件は、この PR の前の head（1f96179）で落ちていた後戻りを捕まえるもので、01936fb では通ります（独立審査で確認）。8件並行のテストと 2000件のテストは修正前でも通る coverage-only のテスト（前者は見張り、後者は正しさの確認で、O(n) の証拠ではありません）。
`pnpm test:worker` 69 passed / 0 failed、`pnpm lint` ok、`node .github/ci/run.mjs fast` ok、`sync-ai-rules --check` ok。

マージで本番の Web/APK がデプロイされるため、マージはオーナーの判断を待ちます。

Refs #48 #49

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01Cv4a6EYroSzGSReCUes9tm
