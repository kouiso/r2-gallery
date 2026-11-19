REVIEW | reviewer: general-purpose subagent, opus 5.5 medium | authored no commit on this PR | head 1f96179 | axes: pass line, design, scope, tests, body vs diff, evidence | verdict FAIL | must 2 want 2 nit 1

## 合否ライン（手元で 1f96179 を再実行）
- `pnpm test:worker`（`NO_PROXY=127.0.0.1,localhost`）: 67 passed / 0 failed。
- `RUNNER_TEMP=$(mktemp -d) CI_SCAN_BASE=origin/main node .github/ci/run.mjs fast`: exit 0（tools 56 passed、worker 67 passed、`leak-check clean: 504 files`）。`node tools/sync-ai-rules.mjs --check`: exit 0。
  - ただし、これはコミットされた `node_modules` のシンボリックリンクを消して `pnpm install` し直した作業ツリーでの結果。リンクのままでは CI の install が通らない（must 1）。
- 修正前の確認: この PR の `worker/src/index.test.ts` を origin/fix/rg19-trash-album-restore（01936fb）の detached worktree に載せて流した。
  - 失敗したのは2件: `drops purged and removed keys from trashOrder so it stays bounded`、`clears trashOrder when nothing is left in the trash`。
  - 通ったのは2件: `keeps the album order when 8 items are trashed concurrently then restored in turn`、`restores into the right place in an album of 2000 items`。この2件は coverage-only だが、本文はそう書いていない（want 2）。
- CI はまだ走っていない（PR がまだ無い）。

## must
1. **`node_modules` のシンボリックリンクがコミットされている**（`node_modules`、cacabe9 で追加）
   - 中身は `/home/user/wt-rg19/node_modules` へのリンク（mode 120000）。`.gitignore` の `node_modules/` は末尾に `/` があるので、ディレクトリしか除外しない。そのため、リンクは除外されずに入った。
   - 範囲外の変更。本文の「変更」にも書かれていない。
   - リンク先が無い環境では install が落ちる。手元で、リンク先が存在しない状態を作って `pnpm install --frozen-lockfile` を流すと、`ENOTDIR: not a directory, mkdir '.../node_modules'` で exit 236 になった。CI のチェックアウトにはこのパスが無いので、check と test は install の段階で落ちるはず。
   - LOCAL-CHECK もこれを見落としている。手元の作業ツリーではリンク先が実在したので、通ってしまった。
   - 直し方: `git rm --cached node_modules` でコミットから外す（履歴に残したくなければ、cacabe9 を作り直す）。再発を防ぐなら `.gitignore` を `node_modules` にする（このPRの範囲を広げたくなければ、別のPRで）。
2. **restore の途中に刈り込みが入ると、戻した物が末尾に付く**（`worker/src/routes/write.ts:45-63`, `:322-331`）。#120 の head では起きない後戻り。
   - `liveTrashed` は、`.trash` 側に実体があるかどうかだけで「まだゴミ箱にいる」を決めている。
   - restore は、先に `moveObject` で実体を元の key へ戻し（`:322`）、その後で `mutateAlbums` で並びへ差し込む（`:325`）。この2つの間では、控えはあるが `.trash` の実体は無い。`liveTrashed` から見ると purge 済みと同じ状態になる。
   - この間に、同じアルバムで `pruneTrashOrder` が走ると（別の trash、restore、`items/remove`）、戻している途中の key が `trashOrder` から落ちる。ゴミ箱に他の物が無ければ、`trashOrder` ごと消える。その後の `insertByTrashOrder` は、`idx = -1` になって末尾に足す。
   - 次の2つの状況で同じことが起きる。
     - (a) #120 が対応した「ファイルは戻ったがアルバムの更新で落ちた restore のやり直し」（`resumed`、`:318`）。その間にアルバムの操作が1回でもあれば起きる。
     - (b) 別の端末や別の選択から、同時に操作が来た場合。
   - 手元で一時テストを2つ足して確かめた（コミットしておらず、削除済み）。
     - アルバム [a,b,c] から b を送る。restore のファイル移動が済んだ状態を作る（`LIB_A.put(b)` と `LIB_A.delete(tb)`。既存の `resumes a restore...` と同じ作り方）。その後、無関係な key で `items/remove` を呼び、`restore(tb)` を流した。
       - head: `[a, c, b]`
       - 01936fb: `[a, b, c]`
     - アルバム [a,b,c,d] で、同じ状態から d を trash して、`restore(tb)` を流した。
       - head: `[a, c, b]`
       - 01936fb: `[a, b, c]`
   - 所属そのものは失われない（items には戻る）。失われるのは並びだけ。ただ、#120 とこのPRが守ろうとしているのはまさにこの並び。
   - 直し方の案:
     - 控えがあって、`.trash` の実体も元の key も無い時だけ purge 済みと見なす。
     - または、restore の `mutateAlbums` で、自分の key を刈り込みの対象から外す。この案は (b) で、他の restore の途中の key を守れないので、前の案のほうがよい。
     - 上の2つの状況を、それぞれ回帰テストに足す。

## want
1. **`liveTrashed` が、`mutateAlbums` のやり直しのたびに、アルバムごとに、控えを全部 list する**（`write.ts:45-63`, `:301`, `:330`, `:413`）
   - head() はキーごとではない。候補（ghost）の中で控えがある物にだけ、1回ずつ打つ。ここは要求どおり上限がある。
   - ただし、`META.list` は `.system/trash-albums/<lib>/` 全体を毎回最後のページまで読む。読む量は、候補の数ではなく、そのライブラリの控えの総数に比例する。
   - 期限切れ purge は控えを消さない（#51）ので、控えの総数は時間とともに増える。
   - これを、対象のアルバムの数 × `mutateAlbums` の試行（最大8回）だけ繰り返す。
   - list と head は、albums.json の get と条件付き put の間に入る。そのため、読み書きの窓が広がる。アプリは8件を並行に送る（`trash_ops.dart:29`）ので、etag 競合と `albums_store_contended` が増える方向に効く。8件のテストは今は通っている。
   - 直し方の案:
     - list の結果（控えの key から epoch への対応）は、`mutateAlbums` の外で一度だけ作る。またはリクエストの中でキャッシュする。
     - head の結果も、1リクエストの中で使い回す。
     - #51 で、控えを purge と一緒に消す。
2. **coverage-only のテストが本文に書かれていない**（PR 本文「テスト」「変更」）
   - 8件並行のテストと 2000件のテストは、01936fb でも通る。
     - 8件並行のテストは、#120 の再レビューの want 4 で求めた「見張り」なので、それでよい。
     - 2000件のテストは、時間を assert していないので、O(n) にしたことの証拠にはならない。
   - 本文に、次の2つを書いてほしい。
     - 修正前に落ちるのは刈り込みの2件だけで、残りの2件は coverage-only であること。
     - O(n) にしたことの根拠は計測（約180ms）であること。

## nit
1. `pruneTrashOrder` のコメント（`write.ts:66-68`）は、並行して送った物は落ちないと書いている。その理由は trash の向きにしか当てはまらない。restore の向きでは落ちる（must 2）。must 2 を直す時に、コメントも合わせてほしい。

## 各軸で見たこと
- **設計**:
  - want1 の刈り込み: trash、restore、`items/remove` の3か所すべてで、`mutateAlbums` の中から呼ばれている。アルバムにもゴミ箱にも無い key は落ちる。ゴミ箱の物が無くなれば `trashOrder` は消える。これはテストと手元で確かめた。
  - trash の向き: 控えを書き、移動し、アルバムを更新する、の順なので、送っている途中の物はまだ items にいて、落ちない。
  - 所属が失われないか: 刈り込みが触るのは `trashOrder` だけで、`items` には触れないので、所属は失われない。
  - #120 より前に送った控えの無い物について: もともと `trashOrder` に無く、restore でも所属を戻さない（`saved` が null）。なので、刈り込みで不当に落ちる枠は無い。
  - 問題は、restore の向きの窓だけ（must 2）。
  - want2 の `insertByTrashOrder`: `Map` を一度だけ作る形になり、O(n) になった。`every` による `trashOrder` の削除は `pruneTrashOrder` に移った。
- **範囲**: `write.ts` と `index.test.ts` のほかに、`node_modules` のリンクが入っている（must 1）。`objects.ts`、`store.ts`、アプリには触れていない。
- **テスト**:
  - 新しい4件は、名前どおりの assert をしている。
  - purge の再現（`.trash` の実体だけを消す）は、実際の purge と同じ状態になっている。
  - restore の途中の窓のテストが無い（must 2）。
- **本文と差分**:
  - 刈り込みの条件、O(n) にしたこと、テスト4件、67 passed は、差分と手元の再実行に合っている。
  - ずれは2つ。`node_modules` が本文に無いこと（must 1）と、coverage-only を明記していないこと（want 2）。
- **証拠**:
  - LOCAL-CHECK は head 1f96179 を名指ししていて、数字は手元の再実行と一致する。
  - ただ、その環境ではリンク先が実在した。CI と同じ、何も無い状態からの install は確かめていない。

---
_Generated by [Claude Code](https://claude.ai/code)_
