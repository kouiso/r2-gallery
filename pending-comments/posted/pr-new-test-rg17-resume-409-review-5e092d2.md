REVIEW | reviewer: general-purpose subagent, opus 5.5 medium | authored no commit on this PR | head 5e092d2 | axes: pass line, design, scope, tests, body vs diff, evidence | verdict PASS | must 0 want 1 nit 3

## 合否ライン（5e092d228c367b51f8601c6cab762fec24d2a665 で確認）
- Scope check: `git diff --stat origin/fix/rg17-same-name-upload...HEAD` lists 3 files: `flutter/test/transfer_queue_test.dart` (+104), `flutter/test_live/README.md` (+11), `flutter/test_live/live_conflict_test.dart` (+70). merge-base = 4e24c2a (#121 head), and the PR has 1 commit. **No `lib/` change.** #121's passed code is unchanged.
- Flakiness: I ran `flutter test test/transfer_queue_test.dart` on head 7 times. 6 runs passed with `+23 All tests passed`. Run 1 (cold, right after `pub get`, load average about 14-18) failed in the pre-existing test `:292` (see nit 1). None of the 5 new tests failed in any run.
- fail-before, re-run myself: I put a scratch copy of the head `flutter/` tree in my scratchpad and copied all 6 of origin/main's `flutter/lib/src/transfer/*.dart` over it (checked that it matches main with `diff`). The build compiles, and the run ends `+17 -6`. 4 of the new tests fail for behavioural reasons:
  - `:664` (lost complete response, contents match): `Expected: <0> Actual: <1>`. On main the code calls `multipartCreate` again instead of using the stored session.
  - `:678` (complete 409, contents differ): `v (2).mp4` is missing (`Actual: <null>`).
  - `:702` (small file, contents differ): `a (2).jpg` is missing. This is main's silent `return` on 409, the data-loss branch.
  - `:714` (compare fails): `timed out waiting for error`. On main the row ends as done.
  - The other 2 failures are #121's own tests (`:562` concurrent same-name, `:608` resume mismatch).
  - `:691` (small file, contents match) **passes on main**. That is expected, because main marks every resume 409 as done, so a matching case cannot tell main and head apart. It works as a no-duplicate regression guard, and `:702` covers the mismatch case.

## must
0件

## want
1. Body and LOCAL-CHECK, the fail-before count. The body says 「追加分で5件失敗」. The LOCAL-CHECK says "5 new tests fail … plus the 2 from #121", which makes 7. My re-run and the author's own log `/home/user/wt-rg17b-failbefore.txt` (`[E]` at lines 72/78/115/124/161/197) both show **6 failures: 4 new plus 2 from #121**. Please correct both texts to "追加5件中4件が失敗（小さいファイルの同一中身 `:691` は main でも完了になるので fail-before にならない。別中身の `:702` が main の黙って完了を捕まえる）＋#121 の2件".

## nit
1. `flutter/test/transfer_queue_test.dart:292-303` (pre-existing, not in this diff): 1 of my 7 runs, the cold first run under load, failed 「選んだファイルは退避してから上がり…」. The test checks the stage dir and ledger right after `status == done`, which may race with cleanup. It is out of scope here, but worth a follow-up issue if it shows up again.
2. `flutter/test/transfer_queue_test.dart:34-37`: the new `failOpen` lines were inserted between the existing comment 「multipart の完了要求を受け取ったまま返さずに止めておく」 and the field it describes (`holdComplete`). That comment now sits above `failOpen`'s comment. Moving the 2 new lines above the old comment fixes it.
3. `flutter/test/transfer_queue_test.dart:724`: the comment says 「退避ファイルは残り」, but nothing asserts that the staged file exists before the retry. The retry reaching done implies it indirectly. An explicit `File(staged).existsSync()` check would make the comment's claim tested.

## 観点ごとに見た所
- **(b) paths exercised**:
  - `:664` and `:678` build a ledger row with `uploadId: 'up1'` and 2 confirmed parts (size 2000, part 1024). So `_place` goes into the existing-session branch (`transfer_queue.dart:675-678`, `_multipart` with no parts left to send). The fake's complete returns 409 because the key exists (fake `:157`), the error is rethrown at `:683`, and `_upload` sends it to `_storedSame` (`:645`).
  - The match test asserts `creates == 0` and `partsRequested isEmpty`, which proves the stored session was used and nothing was re-created. The mismatch test asserts that the original is kept, `v (2).mp4` holds the local bytes, and `aborts` contains `up1`.
  - `:691` and `:702` use size 500, below the 1024 threshold, so they go through `putObject` 409 (fake `:123`) and then `_storedSame`.
  - All of this covers both wants from #121's review.
- **(d) compare failure**: `:714` sets `failOpen` so the `/o/` read returns 500. The row ends as `TransferStatus.error`, not done, and `objects` keeps only `v.mp4`. After `failOpen=false`, `retryAllFailed()` resumes with the same key and uploadId, gets the complete 409 again, the contents match, and the row is done with no duplicate.
- **(e) live test**:
  - `flutter/test_live/live_conflict_test.dart` drives the real `ApiClientTransferApi` against `wrangler dev --local`, using `wrangler.live-trash.toml` (library `a`, token `live-token`, which match the defaults). Keys are unique per run (`conflict-$run/`), and state lives in `.work/`, which is git-ignored (`.gitignore:16`).
  - It covers 4 cases: PUT to an existing key, a second complete after another upload completed first, create on an existing key, and re-complete of an already-completed uploadId (the lost-response case). These are exactly the server assumptions the queue logic relies on.
  - It is not run in CI: nothing in `.github/` mentions `test_live`, and the only CI `flutter test` (`maestro.yml:69`) runs with no arguments, so only `test/` is picked up, as the README states.
  - The live output `/home/user/wt-rg17b-live.txt` shows 4 `-> 409` lines and `+3 All tests passed`.
- **design / scope**: tests and documentation only. `failOpen` is a small switch on the fake and is off by default, so existing tests are unaffected. The `ledgerRow` and `restored` helpers stay inside the group. New comments are in Japanese and explain why.
- **body vs diff**: the list of added tests, the live-test description, the README run steps and the "#121 head unchanged" claim all match the diff. The only mismatch is the fail-before count (want 1).
- **evidence**: LOCAL-CHECK names the full head SHA. The `run.mjs fast` timeouts under load are disclosed and are in tools tests this PR does not touch. I did not re-run the full suite or analyze; I ran only `transfer_queue_test.dart`, as instructed for a loaded machine.

---
_Generated by [Claude Code](https://claude.ai/code)_
