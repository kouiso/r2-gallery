STATE RUNNING 2026-11-14T12:16:14Z | counts pending
mission: それぞれのプロジェクトに書いてあるプランに書いてある作業をやること / どのプロジェクトもまず既存のPRを本質的に対処することを作業を優先してください。そうしないと溜まってばっかりなので
model claude-opus-5-5 (lead) | advisor present (fable, set 2026-11-14 by owner) | github via connector (gh: GH_TOKEN invalid) | push via git | png ok (playwright chromium)
goal: work plan r2-gallery until cycle DONE or DONE-WAITING (set 2026-11-14) | DONE-WAITING satisfies it: yes
rules read: r2-gallery CLAUDE.md/AGENTS.md (same content), .github/scrum-board.yml (project 43), .github/ci/README; archive CLAUDE.md. Stricter: comments Japanese why-only; PR titles Japanese; never edit pages-dist; feature-parity (never drop a feature without owner OK); run `node .github/ci/run.mjs fast` and `node tools/sync-ai-rules.mjs --check` before push; no PR template in either repo.
DEPLOY | kouiso/r2-gallery merge to main -> production | evidence .github/workflows/web-deploy.yml:4-6,33-48 (push main -> pages-dist = Pages production, CLAUDE.md:49) + CLAUDE.md:48 / .agents/skills/fad-distribute/SKILL.md:8 (merge to main ships APK to FAD testers)
DEPLOY | kouiso/r2-gallery merge to other bases (feature branches) -> nothing | evidence ci.yml:5-9, maestro.yml:7-16, web-deploy.yml:4-6 (only main triggers deploy)
DEPLOY | kouiso/r2-gallery pages-dist -> production (never edited by lane) | evidence CLAUDE.md:49
DEPLOY | kouiso/r2-gallery-archive merge to main -> production (treated so; unverified) | evidence ci.yml:7-8 is workflow_dispatch only, but archive CLAUDE.md:49 names an external "equus r2-web-deploy lane" producing pages-dist; no positive evidence that lane is retired for the archive -> ASK below
---
START 2026-11-14T12:16:14Z | lane r2-gallery (cloud) | packet 2026-11-14 20:36 JST part 1/1 | handoff: packet section 7 (next: fix #118 emulator 03-play failure)
worktree /home/user/r2-gallery main clean | nothing unpushed (main == origin/main 5dfe918)
worktree /home/user/notes notes/r2-gallery (this file)
worktree /home/user/r2-gallery-archive main (shallow, 13bddde) clean
DECIDED | every kouiso/r2-gallery merge to main is G5-excluded (production web + FAD) -> merges go to OWNER (RG-12 + bug-fix merge question); lane takes PRs to GATE-ready | reason DEPLOY line 1 | revert: owner says yes to RG-12 question
DECIDED | Mac-only items (APK build, Pixel recording RG-09, RG-31, #43 device test) -> DEVICE | reason cloud lane, 5.4 | revert: n/a
MANAGER agent a9b29b434b520f613 (fable high) | policy 2026-11-14:
  order: RG-17 > RG-19 > RG-20 > RG-22 > RG-18 > RG-21 > RG-23; #118 rework in parallel; then Project 43 iteration items > issues w/o claude-cloud > with claude-cloud; archive #207/#208/#220 open until #118 merges
  PASS LINE: all checks green on head (emulator incl.; red needs root cause, editing Maestro flow just to pass does not count); run.mjs fast + sync-ai-rules --check on that SHA; bug fix has fail-on-main/pass-on-head test; independent review PASS on that SHA; evidence image + GATE comment; no doc/feature-parity.md row removed/downgraded without linked owner OK. Issue "done" in lane = gate-ready + ledger row OWNER with exact remaining steps; issue stays open until owner merges.
  #118: keep one PR, review in 4 slices (Dart / Android / iOS fork via tools/verify-video-player-fork.py / worker); needs: full-scope title+body (whole #208 series), linked owner OK for removing 端末に保存 (H7/H8/X1) and P1 gesture-to-panel change (else OWNER question), GATE states whether worker/src/routes/media.ts must deploy first, emulator fixed, 6-scene device evidence listed as OWNER step.
RG-26 | しない: RG-Q3 = 2 (manager decision: record here only) | done
CYCLE 1 T=2026-11-14T12:18:56Z | PRs 3 (r2-gallery #118; archive #207 #208; excl. NOTES #119) | issues 106 (r2-gallery 100, archive 6) | ledger rows 13 | cycle-1.tsv
  skipped: owner's rule (-ux): 0 (no item assigned to/authored by i4zhdk-ux)
  iteration (Project 43): NOT READABLE — no ProjectV2 tool in this container (connector has no projects op; gh token invalid) -> rule 1(a) moved 0 to front
  pre-sort: OWNER (prod worker deploy SBIs) #47 #50 #53 #56; OWNER (owner-decision) #96 #97 #98 #99 archive#220; OWNER (prod data delete) archive#184 #185 #186; DEVICE (Android real device SBIs) #43 #68 #75 #80 #94 #107 #110 #113 #115
JUDGE b1 (manager): #118 emulator flow update accepted (intentional tested rename of same control viewer_screen.dart:513); gate-ready needs emulator green on 6454563, rename listed in PR body, fresh re-review vs 6454563 + CI Kotlin build green, "PiP closes" named device scene. Feature-parity: BLOCKED on owner (own question, separate from RG-12); PR must reword 本人承認済み -> 承認待ち, drop dead link doc/evidence/private-storage-20261022/README.md, note exportToDevice stub (app_state.dart:696).
#120 RG-19 | FIX->review | PR opened head f78bbf4 | local-check posted | reviewer running
#118 | FIX | member pushed 6454563 (03-play flow 閉じる->一覧に戻る) | emulator rerun in progress | local flutter test 614/0
DESIGN | owner shared https://claude.ai/artifact/6NsgHfP9kH9whED6j4ec26 (r2-gallery デザイン, version 1794408011-d892) | all 31 project/*.dc.html + canvas.json byte-identical to repo doc/design/project (PR #95) | UI items (#66/#67 ReviewConnectEdit, #73/#74 ReviewFolder, #76-#79 ReviewFoundation, #69-#72 ReviewLock, #92/#93 ReviewSettings, #96 Logo) build against doc/design/project/review/*.dc.html
JUDGE b2 (manager): RG-17..23 first; iteration items jump queue (unreadable here). OWNER confirmed #10 #11 archive#113 archive#212. DEVICE #1 #4 #15 #24 #25 #28 (+#2 #3 via #118, add Refs #2 #3 #13 to #118 body; #13 font redistribution terms in body). LATER (not this cycle): #27 #40 #30 #35 #26 #37 #38 #108 #109 #106 #112 #76-#79 #61/#62 #71/#72 #111 (after #118). OWNER question: #29 #32 #104. WORK now:
  A settings_tab.dart stack: #33/#34(label only; build-number automation OWNER) -> #92/#93 -> #66/#67 -> #69/#70
  B: #115 (emulator/web + local worker; if no repro -> owner question) -> #116/#117 -> #39 -> #83 -> #36
  C worker/docs: #84/#85 -> #103 -> #105 -> #86/#87 -> #88/#89 -> #90/#91 -> #81/#82 (web-deploy.yml minimal, called out in GATE)
  D: #73/#74 -> #59/#60 -> help B
  pass-line add: client PR must work against currently deployed Worker. Stacked PRs state merge order in GATE.
#120 | FIX | review FAIL must1 want4 nit1 https://github.com/kouiso/r2-gallery/pull/120#issuecomment-6877273847 (multi-item undo scrambles album order write.ts:190/:218) + CodeRabbit majors (record before mutate; resumable restore) | queued for fix member
#121 RG-17 | review running | head 4e24c2a
#122 RG-20 | review running | head c0437cf
#123 RG-21 | review running | head 04944bc
OWNER ANSWER 2026-11-14 (relayed by manager) | RG-12 + merges of RG-17..RG-23: 「中身がokなら問題ない1」 = YES if every SECOND EDITION gate holds on the current head (incl. evidence; #118 needs its device video). Merge one at a time; after each: web-deploy run green + pages-dist .source-sha == merge SHA, fad-dist-state .source-sha follows; if broken -> open + merge revert PR at once.
DECIDED | G5 production exclusion lifted for r2-gallery main merges of #118 and RG-17..23 PRs only (owner answer above) | revert: owner says 取り込みは止めて. Worker-side fixes still need RG-24 (worker prod deploy) separately; client PRs must work against deployed Worker. Other PRs (stream A-D) still OWNER for merge unless owner extends.
#121 RG-17 | review PASS must0 want3 nit4 https://github.com/kouiso/r2-gallery/pull/121#issuecomment-6877308115 | evidence evidence/121-4e24c2a.png | waiting: emulator green + manager JUDGE 3 (evidence bar, wants follow-up)
#123 RG-21 | FIX | review FAIL must1 (Closes #55 but methods list not single-sourced: http.ts:28 vs index.ts:85) https://github.com/kouiso/r2-gallery/pull/123#issuecomment-6877333888 | queued: resume RG-21 member when slot frees
#124 RG-22 | review running | head 989ca87
#125 #84/#85 (stream C) | PR opened | review after member report
#120 | FIX in progress (RG-19 member resumed)
JUDGE b3 (manager): evidence bar — worker-only #120 #122 #123 = LOCAL-CHECK image (#123 preflight must use production Pages Origin), issues stay open with RG-24 remaining; #124 = headless-Chromium recording vs local worker; #121 = LOCAL-CHECK + live run vs local wrangler dev showing real 409s (complete + put), test_live/ style; #121/#124 must not depend on undeployed worker changes. #121 HOLD: stacked test PR on #121 branch with want1+want2 tests, green+reviewed, then merge #121, retarget, merge tests; want3 -> follow-up issue named in GATE + confirm failure ends as error row. #118 still blocked (device video + export answer); after #121 merges #118 rebases (merge base) + PASS re-recorded.
  fail-before behavioural for #121 confirmed by reviewer (timeout "waiting for all done", v (2).mp4 missing) — not compile errors.
#122 RG-20 | review PASS must0 want6 nit1 https://github.com/kouiso/r2-gallery/pull/122#issuecomment-6877338927 | evidence: LOCAL-CHECK image (to make)
DECIDED | #122 handled like #121 (JUDGE b3 mechanics): want1 (purging expired trash entry deletes fresh same-name entry's thumb objects.ts:130), want2 (purge order orphans thumbs if loop dies objects.ts:125-131), want3 (deleteThumb throw after create -> 5xx -> client retry 409 -> duplicate; make best-effort) + want4 tests (copy/move/import) go into a PR stacked on #122's branch; head c0437cf unchanged; merge order #120 -> #122 -> stacked (per #51 "#49 first"). want5 (move leaves source thumb orphaned) + purge of .system/trash-albums -> follow-up issues named in GATE | reason want1/want3 are data-affecting, same bar manager set for #121 | revert: manager overrules
CAPACITY 2026-11-14 (manager relay of owner): cloud lane may run up to 8 members; reviews in parallel; workflow for classes of 5+.
#124 RG-22 | review PASS must0 want1 nit2 https://github.com/kouiso/r2-gallery/pull/124#issuecomment-6877362997 | want: Closes #57 needs browser network/console check -> evidence member running (headless Chromium vs local worker)
#126 RG-23 (#64 only) | review running | #65 needs owner decision
#127 RG-18 | review running | #44 index (no full enumeration) needs owner decision
#120 | reworked head 01936fb (trashOrder in albums.json; sidecar before mutate; resumable restore) | re-review running
#118 | emulator SUCCESS on 6454563 (12:33Z); check/test/secrets-scan success | next (queued for a member): doc/feature-parity.md 本人承認済み->承認待ち + drop dead link, PR body (rename 閉じる->一覧に戻る, Refs #2 #3 #13, font redistribution terms, exportToDevice stub app_state.dart:696, whether worker media.ts must deploy first), then fresh re-review; then waits on owner feature answer + device video
#121 | all 5 checks green incl. emulator (12:36Z) | HOLD for stacked test PR
#126 | CI `check` FAILURE: .github/ci/run.test.mjs:96 expected 37 actual 1 (5/8 fail) — member changed run.mjs fast phase | FIX after review returns
#120 | CodeRabbit still open on write.ts:196: concurrent membership add + failed sidecar rewrite can lose that membership; re-review running
#126 | FIX | review FAIL must1 (CI check red: run.mjs fast step breaks .github/ci/run.test.mjs) https://github.com/kouiso/r2-gallery/pull/126#issuecomment-6877448654 | fix: revert run.mjs change (drift already caught by tools/media-ext.test.mjs in test job), fix nit1 wording, add `node --test .github/ci/run.test.mjs` to LOCAL-CHECK | queued: resume RG-23 member at next free slot
#128 stream C #86/#87 docs | Devin note: README:82 needs "clear site data / new profile" precondition | review after member report
#123 | reworked head 91b67c1 (ALLOWED_METHODS single source; ACAO is "*", no prod origin in repo) | re-review running
BLOCK 12:55Z | GitHub secondary rate limit on comment/PR creation ("retry after ~58m") | queue: /home/user/notes/pending-comments/*.md; scheduled check-in 13:56Z (trig_01JHmGeWwF9ubYWSGhRQZ1jc) posts them; git push unaffected
#118 | head 9e1170f (feature-parity 承認待ち, dead link removed, body full scope; font OFL 1.1 Noto CJK subset w/ OFL.txt shipped; media.ts deploy-first recommended not required) | LOCAL-CHECK queued (rate limit) | re-review (4 slices) running
DECIDED 12:58Z | container has 4 CPUs / 15 GB; load avg hit ~40 with 8 members + reviewers running flutter -> timeouts in run.mjs fast | cap active members at 5 until load < 8; no two full `flutter test` runs started at once when avoidable | revert: load stays low
#121 stacked tests | branch test/rg17-resume-409 head 5e092d2 (5 new tests fail on main logic; live run vs local wrangler: put/complete/create/re-complete -> 409) | PR creation queued (rate limit) | run.mjs fast flaky under load -> rerun when load low
#127 RG-18 | FIX | review FAIL must2 want4 nit2 (queued comment pending-comments/127-review-5095781.md): M1 grid _askedAt not reset on sort change (media_grid.dart:85-90, key gallery_tab.dart:208) list stops at 200; M2 Closes #45 unmet (full listing per page read.ts:258-290) -> Refs #45; W1 failed first page keeps old cursor; W2 _adoptStoredThumbs ignores sort; W3 loadMore ignores page.sort across worker deploy; W4 what-comments | queued: resume RG-18 member when members < 5
#128 | note: gitleaks (unscoped) flags ac927b5 for "Bearer test-access-token" — the dummy token already defined in worker/wrangler.test.toml, not a real secret; reviewer to confirm .gitleaks.toml allowlist / CI secrets-scan result
#123 RG-21 | re-review PASS must0 want0 nit2 (queued pending-comments/123-review-91b67c1.md) | evidence evidence/123-91b67c1.png | CI 4/4 green | next: post review, GATE, merge after #124
#124 RG-22 | GATE-READY | review PASS https://github.com/kouiso/r2-gallery/pull/124#issuecomment-6877362997 | evidence evidence/124-989ca87.png+.webm (originals 10->0, console 0) | CI 4/4 green | evidence+GATE comments queued (0a/0b) -> merge first after rate limit
#122 stacked | branch fix/rg20-thumb-hardening head 27de2cd (4 tests fail on c0437cf, 66/66 pass) | PR creation queued
stream D | #74 branch feat/folders-above-photos-74 31eb486; #60 branch fix/web-manifest-60 0ef025c (description wording invented — reviewer to check vs #60) | PRs queued
OBS | transfer_queue_test.dart fails intermittently under load in several worktrees (also untouched branch wt-d-2) -> flaky-under-load; open an issue / fix timing after merges settle
#118 | re-review FAIL must2 (docs vs diff: P1 swipe actually KEPT; approval status incomplete H7/V1/O1/O1-2/S7/quarantine, app_state.dart:694 comment) want1 nit2 (queued 118-review-9e1170f.md) | code slices OK: exitPip fixed + Kotlin built in CI, iOS fork verified, media.ts OK, font OFL no RFN | doc fix member resumed
#118 | re-review PASS must0 want1 nit1 at 174bd20 (queued 118-review-174bd20.md) | CODE-READY; merge blocked: OWNER (feature answer ①③④) + DEVICE (6-scene + PiP closes video on real Pixel) | want: rerun PipPolicyProbe javac at head
stream C | #125 (5517eca) and #128 (ac927b5) open, reviews running; #88/#89 docs/kmp-era-cleanup 196973f and #90/#91 docs/feature-parity-t3 c527b08 PRs queued
HOUR 2026-11-14T13:08:55Z | merged 0 | closed 0 | output 0 | open PR 3->13 (r2-gallery #118 #120-#128 + archive #207 #208; 6 more PRs pushed, creation queued by rate limit) | open issues 106->106 | ledger open 13->12 (RG-26 done, RG-12 answered) | owner 6 (#118 features, #65, #44, #29, #32, #104; +RG-24 later) | device 10 issues + #118 video | stuck at review/rate-limit: GitHub secondary rate limit on comment+PR creation since 12:55Z blocks REVIEW/GATE posting (merges need GATE comment); first merge (#124) ready, posts at 13:56Z
  members running now: 2 (stream A, stream B) + reviewers 6 (#120, #126, #125, #128, #127, stacked #121/#122) | items in flight: 17 | merges/closes since last line: 0/0
  rule 1(a) iteration moved 0 (board unreadable) | rule 1(b) non-claude-cloud first: PBI-level work ordered first; 0 labels changed | skipped (-ux): 0
  narrowest point: review verdicts (5 FAIL→rework rounds) + rate limit; capacity raised to 8 members then capped to 5 for 4-CPU load
#126 RG-23 (#64) | re-review PASS must0 (queued 126-review-260d90f.md) | evidence evidence/126-260d90f.png | CI check/test/secrets green, emulator running | merge order: after #124, #123
MERGE QUEUE (one at a time, after rate limit): #124 -> #123 -> #126 -> (#120 if PASS) -> #122 -> #122-stacked -> #121 -> #121-stacked(retarget) -> #127 (if PASS)
#120 RG-19 | re-review PASS must0 want4 nit2 (queued 120-review-01936fb.md) | evidence evidence/120-01936fb.png | CI 4/4 green | stacked follow-up (trashOrder prune, O(n) insert, 8-way test) by RG-19 member; merge #120 at its turn then stacked right after (worker change only deploys with RG-24)
#125 #84/#85 | review PASS must0 nit1 (queued 125-review-5517eca.md) | evidence evidence/125-5517eca.png | CI 4/4 green | NOT an RG row: merge needs owner OK beyond RG-12 scope? -> RG-12 answer covers #118 + RG-17..23 only; stream PRs stay OWNER for merge (ask manager/owner to extend)
#121-stacked (test/rg17-resume-409 5e092d2) | review PASS must0 want1 (fail-before count 6=4 new+2; fixed in queued body/LOCAL-CHECK by lead, text only) | queued: PR + review
#122-stacked (fix/rg20-thumb-hardening 27de2cd) | review PASS must0 want2 — DECIDED: want1 (uncapped purge can get permanently stuck with 1000+ expired items; regression vs old progress) treated as blocking; member fixes on same branch before the PR is opened; fresh review after | reason production trash would never empty | revert: n/a
#127 RG-18 | re-review PASS must0 want1 nit2 at fcfc041 (queued 127-review-fcfc041.md) | want1 (old→new worker switch at #47 deploy loses later pages for non-default sorts until refresh; one-time) -> follow-up PR after merge | evidence needed: UI behaviour -> headless web recording vs local worker (sort old/name/size, page 2 after sort change) — queue for a member
#128 | review FAIL must1 (README:64 curl Bearer dummy token trips gitleaks locally; fix needs no force-push/no ignore entry) want3 (queued 128-review-ac927b5.md) | DECIDED: supersede with new branch docs/run-locally-v2 (TOKEN=$TOKEN form), then close #128 with replacement link | reason: no history rewrite, no safeguard weakening | revert: n/a
SECURITY FINDING | CI secrets-scan scans 0 commits on PRs and main pushes (ci.yml:69-71 + gitleaks.sh: merge-commit head + --no-merges --first-parent) | fix PR fix/ci-secrets-scan-range in progress (stream C member)
#127 | evidence evidence/127-fcfc041.png+.webm (old/name/size first-5 match seed; page 2 after sort change loads 50/50; console 0) | GATE-READY after review comment posted
stream C round 2 | docs/run-locally-v2 189b77c (supersedes #128) + fix/ci-secrets-scan-range cf913ae (drop --first-parent, PR head sha; 9/9 run.test) — PRs queued, reviews running; docs/kmp-era-cleanup 196973f + docs/feature-parity-t3 c527b08 reviews running
#122-stacked (fix/rg20-thumb-hardening 6c3d440) | re-review PASS must0 want0 nit2 (queued review file; lead corrected fail-before count 5->6 in queued body/LOCAL-CHECK, text only) | merge after #122
OWNER RULING 2026-11-14 (relayed): 「CIはローカルで通れば通ったものとみなしていいよ」 -> gate G3: a passing LOCAL-CHECK on the exact merge head (same checks CI runs for touched files: lint, typecheck, tests, build, gate scripts) counts as checks passed; hosted CI not waited on; failing local run = failed gate; never claim hosted CI green unless it is; a later real hosted failure on that head -> immediate follow-up fix PR. Overrides the manager pass-line item "emulator green" (owner words win). Other gate items unchanged.
fix/ci-secrets-scan-range cf913ae | review PASS must0 want1 nit2 (queued) | want (effect check wording) fixed by lead in queued body, text only; nits (ci.yml:70 comment, run.test.mjs:64 test name) -> follow-up
#120-stacked (fix/rg19-trash-order-prune 1f96179) | review FAIL must2 (committed node_modules symlink breaks CI install; restore window regression drops trashOrder slot) want2 | rework by RG-19 member | checked all lane branches: no other node_modules/.wrangler/.dev.vars/wrangler.toml committed
MERGED #124 RG-22 13:27Z | head 989ca87 == GATE head https://github.com/kouiso/r2-gallery/pull/124#issuecomment-6877963078 | merge 0b43385 | #57 #58 closed by GitHub | web-deploy run 43599833103 in progress; pages-dist/fad-dist-state still 5dfe918 -> confirm before next merge
stream A | PRs #129 (#33, 9e20f53) -> #130 (#92/#93, fbb6162) -> #131 (#66/#67, 3b748eb) stacked; evidence pr1/pr2/pr3 PNGs (goldens, Ahem font); #69/#70 OWNER-blocked on #29
OWNER INSTRUCTION 2026-11-14 (relayed): 「…デザイン通りになるように全部作ること」 -> design page = reference for everything on screen; queue position: after existing open PRs + iteration items. Design link: https://claude.ai/artifact/6NsgHfP9kH9whED6j4ec26 (opened OK 12:2xZ; identical to repo doc/design/project). Pages: current (10/27, 11/11 修正), review (11/11 proposals), redesign (10/11 KMP record).
stream B | #115 no repro (300 upload/export/offline OK in Dart VM + web; web tab crashed ~400MB heap; Android not tested) -> comment https://github.com/kouiso/r2-gallery/issues/115#issuecomment-6877981401 asks owner which save; #116/#117 blocked | PRs #133 (#39 detected thumb, 099833f, Refs), #134 (#83 analyze 7->0, 337a5ae, Closes), #132 (#36 duration, 7f054ef, Refs) — reviews next
CONFIRMED #124 in production: pages-dist .source-sha = 0b43385 at ~13:31Z (FAD state follows on its 15-min poll)
MERGED #123 RG-21 ~13:32Z | head 91b67c1 == GATE head https://github.com/kouiso/r2-gallery/pull/123#issuecomment-6877996800 | merge 0ea40e0 | Closes #55; #54 #56 open (RG-24 worker deploy)
DESIGN LINK confirmed by owner 2026-11-14 (relayed): 「https://claude.ai/artifact/6NsgHfP9kH9whED6j4ec26 これr2ギャラリー」 — same link already opened from this container at ~12:25Z (Artifact read OK; 31 boards byte-identical to doc/design/project). Design parity audit member running.
docs reviews | run-locally-v2 189b77c PASS (want: LOCAL-CHECK timestamp 13:40Z was future-dated -> regenerate honestly); kmp-era 196973f PASS; feature-parity-t3 c527b08 FAIL must1 (index.ts:29 wrong file albums.json vs index-<lib>.json) -> stream C member fixing
NOTE (for main session too): docs/run-locally branch (ac927b5, dummy token in curl) stays on origin — lane may not delete branches; without CI_SCAN_BASE, local `run.mjs fast` exits 2 in clones that have it. Owner may delete it after #128 is closed.
#120-stacked (fix/rg19-trash-order-prune 38404d1) | re-review PASS must0 want1 (body test section corrected by lead, text only) nit2 (stale sidecar keeps key; parallel head race — follow-up) | PR to be created after #120 merges
MERGED #126 RG-23 (#64) ~13:40Z | head 260d90f == GATE https://github.com/kouiso/r2-gallery/pull/126#issuecomment-6878060303 | merge c3dd80e | #64 closed; #63/#65 OWNER (#65 decision)
PROD #126 confirmed 13:37Z: pages-dist .source-sha == c3dd80e; fad-dist-state still 5dfe918 (operator lane polls).
MERGED #120 RG-19 (#48 #49) 13:41Z | head 01936fb == GATE https://github.com/kouiso/r2-gallery/pull/120#issuecomment-6878094387 | merge feda953 | worker-only, takes effect with RG-24
PR #141 = #120 stacked (fix/rg19-trash-order-prune, head 38404d1, base main) | review PASS posted https://github.com/kouiso/r2-gallery/pull/141#issuecomment-6878109592 | LOCAL-CHECK on merge with main feda953 running
#131 REVIEW FAIL at 3b748eb (must 1: same-lib endpoint switch keeps old state, trash sends A keys to B) https://github.com/kouiso/r2-gallery/pull/131#issuecomment-6878086868 → fix member running
stream C done: t3 69aad36 / run-locally-v2 3572d44 / kmp-era b16b51e (fresh LOCAL-CHECKs in queue) → re-review running

## LEDGER
(from packet; owner col of RG-17..23, RG-26 read as agent per plan.md:98 — packet 2-1)
| id | state | who | note |
|---|---|---|---|
| RG-10 | doing | agent | #118 open; evidence video = DEVICE |
| RG-11 | doing | agent | re-review of #118 after fixes |
| RG-12 | done | owner | answered 2026-11-14: 中身がokなら問題ない |
| RG-17 | todo | agent | #41 via #42 #43 |
| RG-18 | todo | agent | #44 via #45 #46 |
| RG-19 | todo | agent | #48 via #49 |
| RG-20 | todo | agent | #51 via #52 |
| RG-21 | done | agent | #123 merged; #54 waits RG-24 |
| RG-22 | done | agent | #124 merged 13:27Z |
| RG-23 | blocked | owner | #64 merged (#126); #65 needs owner decision |
| RG-26 | done | agent | しない: RG-Q3 = 2 |
| RG-24 | blocked | owner | worker prod deploy / prod test / delete thumbs |
| RG-09 | blocked | wait | DEVICE: APK + Pixel 7 Pro recording |
| RG-31 | blocked | wait | DEVICE |

## needs owner
- #114/#115: 写真数百枚の保存エラーは、どの操作（アップロード／端末への書き出し／オフライン保存）・どの端末と版・何枚目で止まったか・表示された文言を教えてほしい（手元の再現では 300 枚とも成功。Web はメモリで落ちる兆候あり）
- バグ直し以外（設定タブ・文書・小さな改善）の PR も、審査が通って証跡がそろっていれば、聞かずに 1 本ずつマージしてよいか（マージすると本番の Web とアプリが新しくなる）。ただし、機能をなくす・操作を変える物、配信の仕組み（web-deploy.yml など）を変える物、実機での確認が要る物は、これまでどおり 1 件ずつ聞く。（はい／いいえ）推奨: はい — 該当: #125 #128 ほか stream A-D の PR（除外: #118、#81/#82）
- #65（#63 の 2 つ目）: 一覧に出ない形式（HEIC など）は「上げる前に止める」か「HEIC を表示できるようにする」か。あわせて、既に上がっている一覧に出ないファイルをどうするか（そのまま／一覧に出す／書き出す）。推奨: 上げる前に止める・既存はそのまま
- #44: 並び替えのたびにバケット全体を数え上げない作りにするため、一覧の索引を META（R2 のファイル）か D1 に持つか。D1 はデータベースの変更になる。推奨: META の索引（データベースは触らない）
- #29 アプリ独自の PIN を撤去し端末の画面ロックに一本化してよいか（機能の撤去）（はい／いいえ）
- #32 設定タブのライブラリ切替チップを隠すか、課題を閉じるか（隠す／閉じる）
- #104 重複一覧 API のために本番 Worker の CPU 上限で読み取り量を測ってよいか（本番での計測・読み取りのみ）（はい／いいえ）
- #118 feature changes (separate from RG-12; blocks #118): ①「端末に保存」(端末ギャラリーへの書き出し) を廃止しアプリ内オフライン保存だけにする ③更新後、以前のオフライン保存は隔離され表示されない（消えはしないが移行手段なし）④O1・O1-2・S7 を実機確認待ちで ☑→◐ — それぞれ OK か（はい／いいえ）。推奨: ① はい、③ は移行を足すまで いいえ（訂正 13:05Z: 明るさ・音量のスワイプは残っており撤去ではないので問いから外した）
- ASK | Is kouiso/r2-gallery-archive's main still watched by any deploy lane (equus r2-web-deploy) so that a merge there would change production? yes/no/don't know | read: archive .github/workflows/ci.yml:7-8, archive CLAUDE.md:49, r2-gallery CLAUDE.md:49 ("retired in #10") | the retirement note covers the relay, not the external lane | on "don't know": never merge in the archive (only closes planned anyway)
- ひなたの 4 枚: ごみ箱から元のアルバムへ戻してよいか（期限 ~12-12）（はい／いいえ）

## for main session
- CI secrets-scan in r2-gallery has been scanning an empty commit range on PRs and pushes (reviewer finding 13:17Z); lane is fixing it in a PR. Other repos copying .github/ci/gitleaks.sh may share the bug
- GitHub secondary rate limit hit on comment creation at 12:55Z (all lane posts are from the owner account: reviews, LOCAL-CHECK, GATE comments). Queued locally; if it recurs, the comment-per-gate rule caps throughput at GitHub's content-creation limit
- second review identity: Codex review bot (chatgpt-codex-connector) hits usage limits on #118 and #120 ("You have reached your Codex usage limits") -> no route to its review; CodeRabbit runs (skips >100-file PRs)
- Project 43 iteration field unreadable from this cloud container (no ProjectV2 tool, gh token invalid): please send this/next week iteration issue numbers for r2-gallery, or give the lane a working gh token route
- gh CLI token (GH_TOKEN) invalid in this container; using GitHub connector
- ledger owner column for RG-17..23, RG-26, RG-31 still 'wait' (plan.md:98 rewrite)
MERGED #141 (#120 stacked) 13:44Z | head 38404d1 == GATE https://github.com/kouiso/r2-gallery/pull/141#issuecomment-6878132195 | merge 9f14722 | LOCAL-CHECK re-run on merge result 36ba6f8 | NOTE: merged before pages-dist showed #120 (feda953 confirmed right after) — order slip, no harm; back to confirm-before-next
PROD #120 confirmed: pages-dist .source-sha == feda953 ~13:45Z; #141 web-deploy in progress
HOSTED FAIL main feda953 maestro/emulator: 477/1, transfer_queue_test.dart:271 (staged file still present). Worker-only merge -> pre-existing intermittent test (OBS above). Follow-up fix member running on fix/transfer-queue-stage-cleanup (root cause, no skip). run https://github.com/kouiso/r2-gallery/actions/runs/43600783777
CLOSED #128 -> superseded by #142 (docs/run-locally-v2) https://github.com/kouiso/r2-gallery/pull/128#issuecomment-6878143585
POSTER done: new PRs #135 (#121 stacked) #136 (#122 stacked) #137 (#74) #138 (#60; body has both "Closes #59" and "#59 対象外" -> reviewer to check) #139 (kmp-era) #140 (feature-parity t3) #142 (run-locally-v2) #143 (CI scan range); issue #144 (#121 want3)
#122 conflicts with main (write.ts, after #120/#141) -> member merging main into fix/rg20-stale-thumbs then into fix/rg20-thumb-hardening; fresh review after. Queue reorder: #121 -> #135 -> #127 -> #122 -> #136
#121 merge-result LOCAL-CHECK (98bf444 = 4e24c2a + main 9f14722) running
#129 REVIEW PASS must0 want3 (footer vs design row → replaced by #130; "Closes #33" needs real Android/Web screenshots or Refs; non-Conventional commit subjects) https://github.com/kouiso/r2-gallery/pull/129#issuecomment-6878176192
#130 REVIEW FAIL must1 (test comment wrong, 4th heading オフライン保存 never asserted) want8 (design: grouped borders, offline row title/一覧>, lock subtitle, margin 12; untestable unsupported branch; 切断 connected test) https://github.com/kouiso/r2-gallery/pull/130#issuecomment-6878179095 → fix member running; #131 must merge #130's new head after both fixes
#136 Devin finding verified real: purge regex `.*` skips keys with newlines (assertUserKey allows them) → fix added to the #122/#136 merge member's task
PROD #141 confirmed: pages-dist == 9f14722 at 13:43Z (before #121 merge)
MERGED #121 RG-17 (#114-ish same-name upload) ~13:49Z | head 4e24c2a == GATE https://github.com/kouiso/r2-gallery/pull/121#issuecomment-6878229434 | merge 8154862 | merge-result check 98bf444: flutter +481, fast 0, analyze 7 info (same as main)
#135 retargeted to main; its earlier LOCAL-CHECK had fail 1 (ci fast timeouts under load) -> clean re-run on merge fbb248e (5e092d2 + main 8154862) running
#135 Devin (after retarget): 3 analysis-only suggestions (completesSeen assert, live re-read, comment wording) — optional, no push; carry to follow-up
#132 REVIEW FAIL must1 (v+d entries per video vs 200-entry receiver cap → >100 videos lose candidates permanently) https://github.com/kouiso/r2-gallery/pull/132#issuecomment-6878246909 | #133 PASS want2 (data: size check before decode; percent-encoded data: lost) https://github.com/kouiso/r2-gallery/pull/133#issuecomment-6878244654 | #134 PASS https://github.com/kouiso/r2-gallery/pull/134#issuecomment-6878242232 → fix member on #132+#133 running
docs re-reviews PASS: #140 t3 69aad36 (want: stale 注意 in body), #142 v2 3572d44, #139 kmp b16b51e → posting; merges need owner scope extension
PROD #121 confirmed: pages-dist == 8154862 (~13:54Z)
MERGED #135 (#121 stacked tests) ~13:56Z | head 5e092d2 == GATE https://github.com/kouiso/r2-gallery/pull/135#issuecomment-6878303408 | merge 4dad7a4 | merge-result fbb248e: flutter +486, fast 0 | Devin 3 optional suggestions -> follow-up
docs reviews posted: #140 https://github.com/kouiso/r2-gallery/pull/140#issuecomment-6878263306 | #142 https://github.com/kouiso/r2-gallery/pull/142#issuecomment-6878269184 | #139 https://github.com/kouiso/r2-gallery/pull/139#issuecomment-6878274802
DEVICE REQUEST sent to manager: iPhone Safari check of production web (upload confirm, video play, grid vs design)
#127 merge-result check (4e00845 = fcfc041 + main 4dad7a4) running; reviewer on #137+#138 running
DESIGN AUDIT done: design-parity.md + 31 side-by-side PNGs (evidence/design/, commit 66682de). 12/17 authoritative boards matched with diffs, 5 missing (PiP x3, Background, ReviewConnectEdit=#131). Top diffs: bottom nav, library chips, icon set, albums tab, photos badges, settings, lock, connect, viewer, folder screen. Chunks C1-C11. Contradictions 現行 vs review(承認待ち) boards -> Fable judge running (judge-design-1.md)
#122 / #136 updated by merge (no rewrite): #122 5fc8b7d (conflict only write.ts imports), #136 0bdc006 (+ newline purge fix, fail-before 88/1 -> 89/0). LOCAL-CHECKs posted https://github.com/kouiso/r2-gallery/pull/122#issuecomment-6878339291 https://github.com/kouiso/r2-gallery/pull/136#issuecomment-6878340560 | fresh review running
#145 opened = hosted-fail follow-up: transfer_queue done reported before staged delete (product order bug, not flake); fix + IOOverrides regression test 5/5 fail before, 30/30 pass after | LOCAL-CHECK https://github.com/kouiso/r2-gallery/pull/145#issuecomment-6878349294 | review running
stale queue files 0a/0b-124, issue-115 -> posted/stale (already handled)
