REVIEW | reviewer: general-purpose subagent, opus 5.5 | authored no commit on this PR | head 69aad36 | axes: pass line, design, scope, tests, body vs diff, evidence | verdict PASS | must 0 want 1 nit 1

### 合否ライン
- c527b08 の must 1 は直っている（c527b08..69aad36 は `worker/src/index.ts` のコメントだけ）。`worker/src/index.ts:30-31` の見出しは「they rewrite META/.system/albums.json, the user albums shared by all libraries, where each item is stamped with its lib」になった。6 本はどれも `mutateAlbums` を通り（`worker/src/routes/write.ts:205,239,260,274,306,321`）、`mutateAlbums` が書くのは `${SYSTEM_PREFIX}albums.json`（`worker/src/lib/store.ts:112-116`）。lib を付けるのは `write.ts:245` の `{ ...src, lib }` / `{ key: k, lib, ... }`。説明どおり。6 本ともはじめに `writable()` を呼び、`readOnly` なら 403（`worker/src/lib/env.ts:52-56`）なので、「readOnly !== true only」も合っている。
- 前回の nit 1・nit 2 も直っている。`index.ts:8` の `GET /v1/:lib/albums` は「albums.json の利用者アルバム + index-<lib>.json の pipeline アルバム」になり、`routes/read.ts:125-130` の合成（shared → index.albums → その他）と合う。`index.ts:6` に `GET /, /health -> {ok:true} (no bearer needed)` が入り（`index.ts:106-107`）、末尾は「All /v1 API routes require Bearer」になった（`index.ts:110-115` の `requireAuth` は `/v1` と `/v1/*` だけに掛かる）。
- `doc/feature-parity.md` の内容は実装と合っている。
  - T3（この PR で変わった唯一の行）: `_TrashChild`（`flutter/lib/src/ui/home_shell.dart:57`）は `onOpenTrash: () => _pushAlbums(_TrashChild())`（`:202`）でアルバムタブの子として積まれる。入口は `albums_tab.dart:317-318` の「ゴミ箱」/「移した項目の確認と復元」、保持期間の案内は `trash_tab.dart:130,140` の `trashRetentionNotice`。
  - 表が挙げるテストファイル 16 個はすべてある（`flutter/test/*`、`flutter/test_live/live_trash_test.dart`、`webdl_*_test.dart` は `webdl_logic_test.dart`・`webdl_transfer_test.dart`）。表が挙げる ID（H1〜H15、A1〜A9、B1/B2、T1〜T4、S5、V1〜V4、X1、P3、S1〜S12 のうち挙げられたもの）は、どれも該当ファイルにテスト名として出てくる（grep で 1 件以上）。「書き込みガード」も `grid_test.dart`・`viewer_test.dart`・`albums_test.dart` にある。`doc/evidence/r2-4-bulk-trash-live/` もある。
  - 数値と部品名の抜き取り: 6 秒は `trash_undo.dart:9` の `trashUndoWindow`、`offerTrashUndo` は `trash_undo.dart:16`、3.5 秒は `video_view.dart:18` の `controlsAutoHide = 3500ms`、末尾 9 件手前は `album_widgets.dart:114`、`AppState.exportToDevice` は `viewer_screen.dart:289` から呼ばれる、「名前 (2)」の形は `webdl/media_name.dart:112-118` の `suffixedName`、`grid/day_label.dart` と `ui/album_picker.dart` はある。
- `flutter/README.md`: `--dart-define` の名前は `flutter/lib/src/config/baked.dart:4-5` の `R2_BAKED_ENDPOINT` / `R2_BAKED_TOKEN` と一致する。
- `AGENTS.md:47`: 「retired in PR #18 ...; issue #10 is still open」。#18 は closed の PR（「Pages直接連携へ移行しarchive中継を廃止する」）、#10 は open の issue で、書いてあるとおり。
- 新しい worktree（69aad36、detached）で:
  - `pnpm install --frozen-lockfile`: exit 0
  - `NO_PROXY=127.0.0.1,localhost RUNNER_TEMP=$(mktemp -d) CI_SCAN_BASE=$(git rev-parse origin/main) node .github/ci/run.mjs fast`: exit 0（lint、typecheck、tools 56 件、worker 55 件、gitleaks、leak-check clean 503 files）
  - `node tools/sync-ai-rules.mjs --check`: in sync

### must
0 件。

### want
- **want 1**（本文の「注意」）: 「依存: #87 と #55 を先に入れる前提です（…）。先に入った場合はこの PR で競合解消が必要になります。」は二つの点で今の状態と合わない。(1) #55 はもう closed で、その修正（CORS の PATCH、#123 `0ea40e0`）は main に入っている。(2)「先に入れる前提」と「先に入ったら競合解消が要る」が一文の中で逆を言っている。実際には `git merge-tree` で、今の origin/main とも、#87 の `docs/run-locally-v2`（3572d44）とも競合しない。main + この PR + `docs/run-locally-v2` + `docs/kmp-era-cleanup` を順に合わせた木でも `sync-ai-rules --check` は in sync だった。「依存なし。#87（docs/run-locally-v2）とは AGENTS.md の別の行を変えるだけで、どちらが先でも競合しない」のように直すこと。

### nit
- nit 1 `worker/src/index.ts:26-27`（前からある行で、この PR の対象外）: main に入った #120（`f78bbf4`・`01936fb`）で、`ops/trash` はアルバムから外して `META/.system/trash-albums/<lib>/...json` に控えを置き、`ops/restore` はその控えから元のアルバムへ戻すようになった（どちらも `albums.json` を `mutateAlbums` で書き換える。main の `routes/write.ts:7-17,338,372`）。この PR が main に入った後の一覧は、trash/restore の行が「物を動かすだけ」に読める。この PR で直す必要はなく、次に一覧に触る時に `(also drops it from albums; restore puts it back)` を足すとよい。

### 各軸
- **pass line**: 上のとおり 3 本とも exit 0 / in sync。
- **design**: 見出しの書き換え先、`GET albums` の合成、認証の掛かる範囲が、どれも 1 行で実装の場所を指していて、読む人が `store.ts` と `read.ts` に辿り着ける。前回の指摘の取り込み方として妥当。
- **scope**: `git diff origin/main...origin/docs/feature-parity-t3` は 8 ファイル（`doc/feature-parity.md` 1 行、`flutter/README.md`、`worker/src/index.ts` のコメント、`AGENTS.md` 1 行とそこから生成された 4 ファイル）。#90/#91 の範囲から出ていない。`index.ts` はコードに触れていない。注意: 分岐元は `5dfe918` で、その後 main は #120/#123/#124/#126 で進んでいる。`git diff origin/main origin/docs/feature-parity-t3`（二点）に出る `write.ts` などの差はこの分のずれで、PR の変更ではない。`git merge-tree` で main との競合は無い（main の `index.ts` の変更は import と method guard の 2 行だけ）。
- **tests**: コメントと文書だけの変更なので新しいテストが無いのは妥当。fast で worker 55 件・tools 56 件が通ることを確かめた。Flutter のテストは手元に `flutter` が無く動かしていない。表の記述は flutter/lib と flutter/test を読んで突き合わせた。
- **body vs diff**: 概要の 4 点（T3 の説明・状態 ☑ のまま、API 一覧に 6 本と書き換え先 `albums.json`・`GET albums` の合成・`/`・`/health`、flutter/README、AGENTS.md の PR #18 と #10 を閉じない）は差分と一致する。「注意」の依存の記述だけが古い（want 1）。`Closes #91` / `Closes #90` は、#91 の 4 か所が揃ったので妥当。
- **evidence**: LOCAL-CHECK（13:36Z）の内容（fast exit 0、件数、sync in sync、env に `CI_SCAN_BASE` を明記）は手元の再実行と一致した。前回の nit 3（env を書くこと）は直っている。秘密は 0 件。

---
_Generated by [Claude Code](https://claude.ai/code)_
