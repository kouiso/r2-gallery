# Design parity: product judgment 1 (2026-11-14)

Inputs: `design-parity.md` (sections 2, 4, 6, 7), `doc/design/README.md`, ReviewFoundation board, side-by-sides (ReviewSettings, ReviewLock, Albums), issues #66/#67/#69/#73/#76/#77/#92/#93/#96, diffs of PRs #129/#130/#131.

## Key tension: 現行 boards vs review boards (承認待ち)

**DECIDED (provisional): where both pages cover the same thing, the review board wins. 現行 boards stay the authority for everything the review page does not redraw.**

- Reason: each review board already has a backlog item on the owner's account that names that board as its design: #66/#67 (接続先を変更), #92/#93 (設定の見出し), #69 (ロック文言), #73 (フォルダ), #76/#77 (見た目の土台). #67/#77/#93 are dispatched. The owner then pointed at the whole artifact as "the design". The 現行 boards are by their own description a drawing of today's code, so following them where a review board exists would mean building nothing.
- Not proven: I could not confirm the owner personally wrote those issues (bodies are agent-generated), so this is confirmed with owner question Q1, bundled with the merge OK he must give anyway.
- Revert: owner answers Q1 with "現行 until approved". Then C1b, C6, the lock half of C7 and the 切断 move stop; nothing already merged needs undoing except the #130 headings/#131 row if he says so.
- Working assumption, not asked: colour stays 黒地に金 (the Foundation's own open question; all boards and the product are gold).

## PRs #129 / #130 / #131

**DECIDED: no design objection; they may merge in stack order (#129, #130, #131) without waiting for Q1.**

- They are additive: real version string (the current "Flutter 0.1.0" is factually wrong), headings, a 接続先を変更 screen.
- Feature check: nothing is dropped. #130 keeps 切断 (with its confirm dialog) inside the 接続 group, and #131 does not touch it. The new ConnectEdit screen has no 切断 button yet.
- The existing gate stays: #131's body says merging to main waits for the owner's OK (it ships web + APK). This judgment does not replace that OK.
- Later 切断 move (settings row to 「切断して接続情報を消す」 in 接続先を変更): a move, not a drop, but only as one PR that adds the button and removes the row together, keeps the confirm dialog, and only after Q1 = A.
- Revert: owner rejects the review boards in Q1.

## Section 7 decisions

| # | Topic | Verdict | Choice / reason / revert |
|---|---|---|---|
| 1 | Settings and Lock: review or 現行 | DECIDED (provisional) | Review boards (see above). Lock: title 20/28, copy アプリを使うには…, r14 buttons, outlined PIN button, PIN label above, border #6E6C7C. Revert: Q1 = B. |
| 2 | Icon set | DECIDED | Use the design's own icons: the boards contain them as inline SVG, so extract those paths into one app icon set and use it wherever a board draws an icon; Material Icons stay only where no board draws one. Reason: "デザイン通り" and it is difference no. 3 on every screen. Own chunk (C1c). Revert: owner says Material icons are fine, or the SVG set costs an unacceptable dependency (then Material Symbols Outlined as fallback, flagged in the PR). |
| 3a | Screen title weight | DECIDED | 700 (Foundation "title 20/28 Bold"; product is already 700). Drop the extra letterSpacing 0.2. Revert: owner prefers Main's 600. |
| 3b | Library chips off Albums/Import/Trash | DECIDED + OWNER Q2 | Keep chips on every tab where they are today, and keep the read-only lock mark; restyle only (left-aligned x16, h36, r20, no check glyph). Reason: removing them takes away library switching and the read-only indication from those tabs, which the never-drop rule forbids without the owner's OK; the Foundation changelog suggests the chip row was simply not drawn on those boards. This corrects the audit's C2 scope ("only on Photos+Settings"). Revert: Q2 answer. |
| 4 | Boards for web placeholder / web-disabled states | DECIDED | No boards. Web is the upload-confirmation and playback-check build; style these states with the shared tokens and keep the current copy. Revert: owner asks for web boards. |
| 5 | Boards for screens that have none | OWNER Q3 | Defines the scope of 「全部」. Not blocking: every chunk below covers a boarded screen. |

## Design-internal slips (section 2)

| Slip | Verdict | Choice / reason / revert |
|---|---|---|
| Viewer 「ゴミ箱へ」 white on the board | DECIDED | Keep danger red #E0605E. The Foundation names "danger: ゴミ箱へ・切断・失敗" explicitly; the board is the slip. Note in the C8 PR that the board should be corrected. Revert: owner says white. |
| Viewer header title = library name on the board | DECIDED | Keep the date (file name when no date) with "N件目 · ファイル名" below. The 現行 board is the only outlier (the 10/11 viewer board also shows the date), and replacing it removes on-screen information; the library name is in the 情報 sheet. Revert: owner wants the library name in the header. |

## Owner questions (none blocks the first chunks)

**Q1** デザインの「レビュー提案（11/11）」は「承認待ち」と書いてあります。設定・ロック・接続先の変更・フォルダ・見た目の土台は、この提案の絵で作ってよいですか？
- A. 提案の絵で作る（おすすめ。#66 #69 #73 #76 #92 が既にこの絵を指しています）
- B. 承認するまでは「現行画面」の絵のまま
- C. 画面ごとに決める

**Q2** デザインでは、ライブラリ切り替えのチップが写真と設定（現行）にしか描かれていません。アルバム・取り込み・ゴミ箱のチップはどうしますか？
- A. 今のまま全部のタブに残し、見た目だけデザインに合わせる（おすすめ）
- B. デザインの通り、写真タブだけにする
- C. 写真と設定だけにする

**Q3** デザインに絵が無い画面（選択モード、アルバム詳細、ゴミ箱、アップロード確認、情報シート、転送、各ダイアログなど）はどう合わせますか？
- A. 色・文字・角丸だけ土台に合わせる（おすすめ）
- B. 先に絵を描き足して、承認してから作る
- C. 10/11 の KMP 版の絵を配置の手本にする

## Build order (C1 split into a/b/c)

| Order | Chunk | Waits on | Can start now |
|---|---|---|---|
| 1 | **C1a** `theme.dart` only: NavigationBarTheme (unselected #9C9AA8, selected 700, 1px top line, pill 56x30), `success` / `onAccent` tokens, #FFAE00 to accent, title letterSpacing | nothing | **yes: start here** |
| 2 | **C4** albums tab (title below cover, segmented look, dashed create tile, その他, trash row) | nothing (no overlap) | yes, in parallel with C1a |
| 3 | **C1b** contested tokens: radius 8/14/16, r14 h52 buttons, outline #6E6C7C, TextTheme, chip/segmented/snackbar themes | C1a merged; provisional on Q1 | yes after C1a |
| 4 | **C1c** design icon set (decision 2) | C1a | yes after C1a |
| 5 | **C7** connect + lock (labels above fields, spacing, PIN field/button, copy) | C1b; lock half provisional on Q1; coordinate #69/#70 | after C1b |
| 6 | **C6** settings: verify #129-#131 against ReviewSettings, fix the rest; 切断 move last | #129-#131 merged; Q1 for the move | no |
| 7 | **C2** app shell: chips restyle (kept on all tabs), titles, nav labels | #131 merged (`home_shell.dart`); Q2 only if removing | no |
| 8 | **C3** photos tab | #127 and #137 merged | no |
| 9 | **C5** folder screen: diff what #137 leaves against ReviewFolder | #137, #127 merged | no |
| 10 | **C8** viewer + video (trash stays red, title stays date) | #118 merged; C1b | no |
| 11 | **C10** import tab restyle (Android, by code) | C1b | after C1b, low priority |
| 12 | **C11** web identity | #138 merged; launcher icon waits on #96 | no |
| 13 | **C9** PiP + background playback (new Android feature, largest) | #118 merged; its own issue scope | no |

Start first: **C1a**. It touches one file that no open PR edits, fixes the top-ranked difference (bottom nav on every screen), and every later chunk builds on its tokens. C4 is the only screen chunk with no dependency and can run alongside it.
