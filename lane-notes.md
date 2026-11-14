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

## LEDGER
(from packet; owner col of RG-17..23, RG-26 read as agent per plan.md:98 — packet 2-1)
| id | state | who | note |
|---|---|---|---|
| RG-10 | doing | agent | #118 open; evidence video = DEVICE |
| RG-11 | doing | agent | re-review of #118 after fixes |
| RG-12 | blocked | owner | merge #118 (production) |
| RG-17 | todo | agent | #41 via #42 #43 |
| RG-18 | todo | agent | #44 via #45 #46 |
| RG-19 | todo | agent | #48 via #49 |
| RG-20 | todo | agent | #51 via #52 |
| RG-21 | todo | agent | #54 via #55 |
| RG-22 | todo | agent | #57 via #58 |
| RG-23 | todo | agent | #63 via #64 #65 |
| RG-26 | done | agent | しない: RG-Q3 = 2 |
| RG-24 | blocked | owner | worker prod deploy / prod test / delete thumbs |
| RG-09 | blocked | wait | DEVICE: APK + Pixel 7 Pro recording |
| RG-31 | blocked | wait | DEVICE |

## needs owner
- #29 アプリ独自の PIN を撤去し端末の画面ロックに一本化してよいか（機能の撤去）（はい／いいえ）
- #32 設定タブのライブラリ切替チップを隠すか、課題を閉じるか（隠す／閉じる）
- #104 重複一覧 API のために本番 Worker の CPU 上限で読み取り量を測ってよいか（本番での計測・読み取りのみ）（はい／いいえ）
- #118 feature changes (separate from RG-12; blocks #118): ①「端末に保存」(端末ギャラリーへの書き出し) を廃止しアプリ内オフライン保存だけにする ②明るさ・音量のスワイプを明示パネルに置き換える ③更新後、以前のオフライン保存は隔離され表示されない（消えはしないが移行手段なし）④O1・O1-2・S7 を実機確認待ちで ☑→◐ — それぞれ OK か（はい／いいえ）。推奨: ①② は既に作られた変更なので はい、③ は移行を足すまで いいえ
- ASK | Is kouiso/r2-gallery-archive's main still watched by any deploy lane (equus r2-web-deploy) so that a merge there would change production? yes/no/don't know | read: archive .github/workflows/ci.yml:7-8, archive CLAUDE.md:49, r2-gallery CLAUDE.md:49 ("retired in #10") | the retirement note covers the relay, not the external lane | on "don't know": never merge in the archive (only closes planned anyway)
- RG-12 (+ bug-fix merges): 審査が通り証跡が付いた PR を、あなたの OK を待たずにマージしてよいか（マージすると本番の Web と FAD が新しくなる）。壊れたら戻し PR も即取り込んでよいか。（はい／いいえ） — recommend: はい
- ひなたの 4 枚: ごみ箱から元のアルバムへ戻してよいか（期限 ~12-12）（はい／いいえ）

## for main session
- second review identity: Codex review bot (chatgpt-codex-connector) hits usage limits on #118 and #120 ("You have reached your Codex usage limits") -> no route to its review; CodeRabbit runs (skips >100-file PRs)
- Project 43 iteration field unreadable from this cloud container (no ProjectV2 tool, gh token invalid): please send this/next week iteration issue numbers for r2-gallery, or give the lane a working gh token route
- gh CLI token (GH_TOKEN) invalid in this container; using GitHub connector
- ledger owner column for RG-17..23, RG-26, RG-31 still 'wait' (plan.md:98 rewrite)
