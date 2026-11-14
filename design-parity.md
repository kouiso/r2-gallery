# Design parity audit: r2-gallery product vs design artifact

- Design: artifact `6NsgHfP9kH9whED6j4ec26`, version `1794408011-d892` (copy in `doc/design/project/`, byte-for-byte)
- Product: `origin/main` **0b43385** (detached worktree `/home/user/wt-design`). `origin/main` is now `feda953`; the 3 merges since (#120/#123/#126) touch no `flutter/lib/src/ui` or theme file, so every screenshot is also valid for `feda953`.
- Method: **(a) rendered the design for real.** `artifact-type/dc-runtime.js` from the artifact is the missing `support.js` (copy it next to each `.dc.html`, including `review/` and `redesign/`, and serve over http, not `file://`, otherwise `dc-import` and `sc-for` boards render blank/unbound). Playwright chromium, each board at its `canvas.json` size. For numbers I also read the HTML/CSS directly (`getBoundingClientRect` for Settings/Albums/Connect/Lock/ReviewSettings/ReviewLock).
- Product: Flutter web release build (`--dart-define=R2_BAKED_ENDPOINT=http://127.0.0.1:8797 R2_BAKED_TOKEN=test-access-token`), local worker (`wrangler dev --local --port 8797 --config worker/wrangler.test.toml`), seeded with 24+ photos, 3 videos, 3 albums, 6 folders (one nested: 旅行/京都), 3 trashed items, library B (read-only, empty). Playwright 390x844, **Android user-agent** (isMobile). Without the Android UA Flutter web picks `VisualDensity.compact` and buttons/tiles are 8 px shorter, so the first capture pass was discarded and redone.
- Caveat on pixel numbers for the product: Flutter web is a canvas, so sizes are measured from screenshots (rows/cols of non-background pixels, corner rounding makes card edges ~+-4 px) and cross-checked against the Dart source. Treat "~" values as +-4 px; sizes quoted from Dart are exact.
- Web-only differences (not defects, but affect comparison): web has no device auth (the "画面ロックで保護" switch renders disabled/off, only PIN unlock exists), no offline save (the 「オフライン保存」 settings card and the viewer's 「オフライン」「端末に保存」 actions are absent), and the 取り込み tab shows a placeholder. These are listed under Android-only below and were compared by reading code.
- Fonts: design uses Noto Sans JP 400/500/700 (Google Fonts). Product sets no font family (Android system font = Roboto + Noto Sans CJK JP). In headless web both fall back to whatever CJK font is installed, so glyph shapes are not compared.

Evidence: `/home/user/notes/evidence/design/<board>-side.png` (design left, product right, caption = board name + sha). Raw shots: `evidence/design/design/*.png` (design renders), `evidence/design/product/*.png` (product). `<board>` = file path with `/` replaced by `_` and without `.dc.html`.

## 1. Boards (31) to product screens

Status: **D** = matched, differences listed in section 3; **M** = missing in product; **A** = Android-only (compared by code); **R** = KMP-era record (README: not authority; no diff list required).

### Page 「現行画面・新規機能」 (12)

| File | Title | Product screen/state | Status | Side-by-side |
|---|---|---|---|---|
| Main.dc.html | 現行 · 写真タブ | photos tab (`gallery_tab.dart`, `media_grid.dart`, `home_shell.dart`) | D | Main-side.png |
| Albums.dc.html | 現行 · アルバムタブ | albums tab segment アルバム (`albums_tab.dart`) | D | Albums-side.png |
| Import.dc.html | 現行 · 取り込みタブ | `import_browser_tab.dart` (web shows only a placeholder) | A (+D on web copy) | Import-side.png |
| Settings.dc.html | 現行 · 設定タブ | `settings_tab.dart` | D | Settings-side.png |
| Lock.dc.html | 現行 · ロック画面 | `lock_gate.dart` (PIN-only variant shot; device-auth variant by code) | D | Lock-side.png |
| Connect.dc.html | 現行 · 接続画面 | `connect_screen.dart` (after 切断) | D | Connect-side.png |
| Viewer.dc.html | 現行 · 動画ビューア | `viewer_screen.dart` + `video_view.dart` (controls visible) | D | Viewer-side.png |
| Logo.dc.html | #103 ロゴ案 (A/B) | launcher icon + web icons: product = 案A (navy) | D / owner decision #96 | Logo-side.png |
| PipPlayer.dc.html | #197 小窓ボタン付きプレイヤー | viewer, **no PiP button** | M | PipPlayer-side.png |
| PipWindow.dc.html | #197 他アプリ上の小窓 | none (no PiP code anywhere on main) | M, A | PipWindow-side.png |
| PipBlocked.dc.html | #197 小窓が使えない時の案内 | none | M, A | PipBlocked-side.png |
| Background.dc.html | #196 バックグラウンド再生 | none (no audio_service / MediaSession) | M, A | Background-side.png |

### Page 「レビュー提案（11/11）」 (5)

| File | Title | Product screen/state | Status | Side-by-side |
|---|---|---|---|---|
| review/ReviewSettings | 提案 · 設定 | settings tab | D (large) | review_ReviewSettings-side.png |
| review/ReviewConnectEdit | 提案 · 接続先を変更 | **none** on main; PR #131 adds `connect_edit_screen.dart` | M | review_ReviewConnectEdit-side.png |
| review/ReviewFolder | 提案 · フォルダ | `folder_browse_screen.dart` (旅行, has subfolder 京都) | D (large) | review_ReviewFolder-side.png |
| review/ReviewLock | 提案 · ロック画面 | `lock_gate.dart` | D | review_ReviewLock-side.png |
| review/ReviewFoundation | 見た目の土台 | `theme.dart` + web manifest (token/spec board, no screen) | D (token table in 3.17) | review_ReviewFoundation-side.png (right panel = text summary) |

### Page 「リデザイン（10/11）」 (14, R: KMP-era, reference only)

| File | Title | Nearest product screen | Side-by-side |
|---|---|---|---|
| redesign/Main | 01 写真タブ | photos | redesign_Main-side.png |
| redesign/Select | 02 選択モード | photos, 2 selected | redesign_Select-side.png |
| redesign/Viewer | 03 ビューア | viewer (image, chrome shown) | redesign_Viewer-side.png |
| redesign/ViewerInfo | 04 情報シート | viewer info sheet | redesign_ViewerInfo-side.png |
| redesign/Albums | 05 アルバム | albums | redesign_Albums-side.png |
| redesign/AlbumDetail | 05b アルバム詳細 | album detail (no selection shot) | redesign_AlbumDetail-side.png |
| redesign/Upload | 06 アップロード確認 | upload confirm sheet | redesign_Upload-side.png |
| redesign/Transfers | 07 転送シート | `transfers_strip.dart` exists; not captured (local upload completes instantly) | redesign_Transfers-side.png (text panel) |
| redesign/Trash | 08 ゴミ箱 | trash | redesign_Trash-side.png |
| redesign/Import | 09 取り込み(Web) | web placeholder | redesign_Import-side.png |
| redesign/Settings | 10 設定 | settings | redesign_Settings-side.png |
| redesign/Lock | 11 ロック | lock | redesign_Lock-side.png |
| redesign/States | 12 状態 | empty library (Test B) only | redesign_States-side.png |
| redesign/Spec | 13 実装仕様 | document, no screen | redesign_Spec-side.png (text panel) |

Totals: **31 boards** = 12 current + 5 review + 14 KMP-era. Of the 17 authoritative boards: **12 matched to a product screen** (Main, Albums, Import, Settings, Lock, Connect, Viewer, Logo, ReviewSettings, ReviewFolder, ReviewLock, ReviewFoundation; Logo only needs the owner decision), **5 missing** (PipPlayer's button, PipWindow, PipBlocked, Background, ReviewConnectEdit). Android-only/not shootable on web: Import, Lock (device-auth variant), PipWindow, PipBlocked, Background, Settings offline card, Viewer offline/save actions.

Product screens that exist but have **no board in an authoritative page** (only KMP-era records or nothing): upload-confirm sheet, selection mode (top/bottom bars), sort popup menu, album detail, trash, offline list, viewer info sheet, transfers strip/sheet, PIN dialog, grace picker, disconnect dialog, snackbars, empty/error `StateView`s, `NoLibraryView`, 接続先に到達できません (connect probe-failed variant), detection bar/sheet/history (Android). Their look can only be judged against the shared tokens; if the owner wants them audited, they need boards first.

## 2. Contradictions inside the design (need an owner/lead decision before fixing)

README says both 「現行画面」 and 「レビュー提案」 are authority, and 見た目の土台 calls the review page "承認待ちの案" (pending). They conflict:

| Topic | 現行 board | Review board | Product today |
|---|---|---|---|
| Settings structure | one card per item, chips row, 切断 card, "R2 Gallery (Flutter) 0.1.0" | 4 headed groups, no chips row, 接続中 row with 「変更」 chevron, no 切断 card (moved into 接続先を変更), "バージョン 0.4.0（400）" | = 現行 board |
| Settings title | "R2 Gallery" | "設定" | "R2 Gallery" |
| Lock title size | 22/700 | 20/28 700 | 18/700 |
| Lock subtitle copy | 写真・アルバム・設定を開くには、ロックを解除してください。 | アプリを使うには、ロックを解除してください。 | = 現行 board |
| Lock buttons | pill r26, h52 and h48, gold both | r14 h52, gold + outlined (#6E6C7C) | r14 (theme), both gold |
| Lock PIN field | underline only, placeholder "PIN" | filled #1E1E2B, border #6E6C7C r14, label "PIN" above | filled #1E1E2B, border #2A2A3A r14, hint "PIN" |
| Input/outline-button border | #2A2A3A | #6E6C7C | #2A2A3A |
| Screen title weight | Main h1 600 | all review h1 700 (Foundation "title 20/28 Bold") | 700 + letterSpacing 0.2 |
| Library chips | shown on Photos and Settings only, not Albums/Import | not shown on ReviewSettings | shown on every tab when >=2 libraries |

Also two design-internal slips worth knowing: Viewer's 「ゴミ箱へ」 is white in the board (product uses danger red, which matches the Foundation "danger: ゴミ箱へ"); Viewer's header title is the library name while product shows the date.

## 3. Differences per pair

Legend: D = design value, P = product value. Dart references are exact; screenshot numbers are "~".

### Cross-cutting (affect every screen; do once as shared work)

| # | Item | D | P |
|---|---|---|---|
| X1 | Bottom nav, unselected colour | icons+labels #9C9AA8 (textDim), label 500 | icons+labels #F2F0EA (white, M3 default), indistinguishable from selected except pill (measured RGB 242,240,234) |
| X2 | Bottom nav, selected | label 700 #F2F0EA, pill 56x30 r15 rgba(228,185,91,.2), outline icon | pill M3 64x32 accentSoft (same colour), filled icon variants (`Icons.photo` etc.) |
| X3 | Bottom nav top edge | 1px #2A2A3A line, bar #14141D, h80 | no line (bar #14141D, h80 matches) |
| X4 | Icons | custom 24px line icons, stroke 1.8-2, round caps (lock without keyhole dot, 3-dot PIN rectangle, line download/trash, plain +/-10 arrows) | Material Icons (lock_outline with dot, pin_outlined "123", replay_10 with "10" glyph, filled nav icons) |
| X5 | Library chips | left-aligned x16, y56-92, h36, r20; label only ("[ライブラリ1]", 14 w700 gold / w500 dim); only Photos and Settings | centered horizontally (x94-287), ~6px higher (y50-86), h36; selected chip has a check glyph, read-only library has a lock glyph (`LibraryLabel`); present on Albums, Import, Trash too |
| X6 | App bar title | "R2 Gallery" 20/600 on Main/Albums/Import/Settings(current), "設定" 20/28 700 on ReviewSettings | 20/700, letterSpacing 0.2 (theme `titleTextStyle`) |
| X7 | Primary button | current boards: pill r26 h52 (16/600); review boards: r14 h52 (15/700) | r14 (`filledButtonTheme`), min height from padding 14 = ~48, 14/700 default size |
| X8 | Input fields | current: bg #14141D r12 border #2A2A3A h52 (Connect) / h48 (Import); review: bg #1E1E2B r14 border #6E6C7C | bg #1E1E2B r14 border #2A2A3A, Material floating label inside the field |
| X9 | Text | Noto Sans JP; sizes 11-28 hard values | no TextTheme; 10 sizes hard-coded (matches Foundation "71 places") |
| X10 | Toast/notice | Viewer notice: left/right 12, bottom 236, min-h52, r8, #1E1E2B + 1px #2A2A3A border, 14px, gold 14/600 action | `SnackBar` floating r12, #1E1E2B, no border (theme) |

### 3.1 Main (写真タブ)

| Item | D | P |
|---|---|---|
| Header | h56 title + sort + lock; chips row below (see X5) | same buttons (48x48 filter_list + lock_outline 20); chips differ (X5) |
| Day header | h40, "今日"/"昨日" 14/600, padding 0 12 0 16 | h~52 (8 top + 12 + 20 line + 12), 14/600 (`media_grid.dart` `_header`); grid starts y152 vs D y140 |
| Grid | 4 cols, gap 2, tiles square | 4 cols, gap 2 (matches) |
| Tile placeholder | plain tone fill | #1E1E2B fill + `image_outlined` 28 #9C9AA8 while no thumb |
| Video badge | white play 28x28 **centered** | white `play_arrow` 24 at **bottom-right** (right 4, bottom 4) |
| Saved badge | 18px circle rgba(0,0,0,.6), gold check 12, **bottom-right** (4,4) | rounded square r8, black 55%, padding 3, `download_done` 16, **top-left** (6,6) |
| FAB | right16 bottom16 over nav, h56 r16 gold, 「追加」 15/600, plus 22/2.4 | right16 bottom16, M3 extended FAB h56 r16, label 14/500 (theme default), `Icons.add` |
| Folder cards | not drawn | below photos, 97x97 r8 #1E1E2B, centered icon+12px label (the review board moves them up, see 3.14) |
| Copy | all matches (今日, 昨日, 追加, 並び替え, 今すぐロック) | same strings |

### 3.2 Albums

| Item | D | P |
|---|---|---|
| Chips row | none | present (X5) |
| Segmented control | container 1px #2A2A3A r20 h40; selected segment rgba(228,185,91,.2) fill, gold 14/600 text + check 16; unselected transparent #F2F0EA 14 | M3 `SegmentedButton`; selected = solid gold fill with dark text (screenshot), outline #2A2A3A; header padding 16/8/8/8 |
| + button | 48x48, plus 24 | `IconButton(Icons.add)` (matches) |
| Create tile | dashed 1px #2A2A3A, r12, bg #14141D, icon 28 #9C9AA8, label 14 #9C9AA8 | solid #1E1E2B, no border, icon 24 dim, label **12 #F2F0EA** (`_NewCard`) |
| Album card | square cover r12; title **below** 14/600; count below 12 #9C9AA8 "128 件" | title+count **overlaid** on cover bottom over `black87→transparent` gradient: title 13/700, count 11 dim (`_AlbumCard`); copy "N 件" same |
| Grid | 2 cols, gap 12, padding 0 16 | 2 cols (floor(width/160)), gap 12, padding 16/4/16 (matches) |
| 「その他」 | 13/600 dim, padding 20 16 4 | 14/700 dim, left 4+16, top 12 |
| Trash row | borderless row, min-h56, 16 title / 12 sub, chevron 24 stroke dim, icon 24 | card #1E1E2B r16, `minTileHeight` 64, `delete_outline`, `chevron_right` (white); copy ゴミ箱 / 移した項目の確認と復元 same |
| Folder segment | not drawn | cards use `FolderCard`; create tile label "フォルダ作成" (no board) |

### 3.3 Import (Android-only; web placeholder shot)

| Item | D | P (by code) |
|---|---|---|
| Header 「ネットから取り込む」 | 16/700 + history icon button 48 | 16/700, left padding 4 (matches), `Icons.history` |
| URL field | h48, bg #14141D, r12, border #2A2A3A, 15px, padding 0 14, placeholder "https://…" | dense M3 field bg #1E1E2B r14, hint "https://…" (copy same), suffix clear button when text |
| Go button | 48x48 r12 gold, globe icon | `FilledButton` (padding 24x14 from theme, r14), `Icons.public`, semantic label 移動 |
| Empty hint | 14 dim centered "動画ページのURLを入力して移動" | same text/colour |
| Chips row | none | present (X5) |
| Web build | not drawn | placeholder "ネットからの取り込みは Android アプリで使えます（Web 版では利用できません）" 14 dim: **copy not in any design board** |

### 3.4 Settings (current board)

| Item | D | P |
|---|---|---|
| Layout | chips row (y56) then cards from y100, side padding 16, gap 8 | cards from ~y116 (ListView padding 16 on top of the 44px chips area): ~+16 px |
| Card shape | r16, bg #14141D, 1px #2A2A3A | M3 `Card` r16 #14141D border #2A2A3A (matches) |
| Rows | title 16, sub 12 dim, gap 16, padding 12/16 | `ListTile` defaults: same sizes; heights match within ~4px (connection card 69 vs ~69) |
| 画面ロックで保護 | switch ON: 52x32 gold track, dark #1A1408 knob right | M3 `Switch` (outlined track, round knob); web shows disabled/off |
| 再ロックまでの時間 value | "毎回ロック" 14 dim | trailing `Text` ~11-12 dim (ListTile trailing default), value from state ("1時間") |
| PIN row | icon rounded rectangle with 3 dots | `Icons.pin_outlined` ("123" box) |
| オフライン保存 (Android) | one card, two rows: icon line download + "オフライン保存/[件数]件" + chevron 20, red row "オフライン保存をすべて削除" (trash icon) | same two rows and copy; icons `download_done` and `delete_sweep_outlined` |
| 切断 card | link-off icon, red title, sub 保存した接続情報を消去します | same |
| Version | "R2 Gallery (Flutter) 0.1.0" 12 dim, margin-top 8 | same text, margin 24 above (SizedBox 24) |

### 3.5 Lock (current board)

| Item | D (current) | P |
|---|---|---|
| Content width / padding | padding 0 32, content 326 | padding 32, max width 320 (centered, 3px narrower) |
| Icon | lock 48, stroke 1.8 gold, no keyhole dot | `lock_outline` 48 gold (has dot) |
| Title | 22/700, margin-top 4 (gap 12) | **18/700**, gap 20 icon->title |
| Subtitle | 13 dim, margin-bottom 16 | 13 dim, gap 8 above, 28 below |
| Unlock button | pill r26 h52, 16/600, fingerprint 22 | `FilledButton.icon` r14 minH52 (Android), fingerprint icon |
| "または PIN で解除" | 12 dim, margin-top 16 | 12 dim, gap 24 above / 12 below |
| PIN field | underline only, transparent, 24px letter-spacing 8, h56 | filled #1E1E2B, border #2A2A3A r14 (gold 1.6 when focused), 24/ls8, hint "PIN" |
| PIN button | pill r24 h48 gold, 15/600 | r14 h~48 gold 14/700 |
| Error | not drawn | "PINが違います" 13 danger, 試行回数超過… (no board) |

### 3.6 Connect

| Item | D | P |
|---|---|---|
| Padding | 24 (content 342) | 28 (content 334, max 420) |
| Icon | 56 stack-of-photos line icon (stroke 1.6) | `photo_library_outlined` 56 |
| Title "R2 Gallery" | 28/700, no extra gap (12) | 28/**800**, letterSpacing .5, gap 16 above |
| Sub-title | 16/600 | 16/700 |
| Body | 13 dim, margin-bottom 12 | 13 dim, 36 gap below |
| Field label | static 12px dim label **above** the field; visible placeholders "https://…workers.dev" / "r2g_…" | label *inside* the field ("エンドポイント"/"アクセストークン", floating on focus); hint text only visible when focused |
| Field box | h52 r12 #14141D border #2A2A3A | ~55 tall (M3), r14, #1E1E2B, border #2A2A3A; gap between fields 14 (D: 12) |
| r2g hint | 12 dim | 12 dim, copy identical |
| 接続する | enabled gold pill r26 h52 16/600 | **disabled grey** until both fields filled (state not in design), r14 h~48 |
| 接続せずに取り込みだけ使う | text button h48, 14 gold | `TextButton` h40, 14 gold (copy identical) |
| Error variants | not drawn | "接続先に到達できません" + body (probe failed), red 13 error text: no board |

### 3.7 Viewer (video, current board)

| Item | D | P |
|---|---|---|
| Top bar | h64, rgba(0,0,0,.55); **title = library name 16/600**; sub "3件目 · name" 12 rgba(255,255,255,.8) | h~56, same 55% black; **title = date "11月14日 土曜日 13:35" 14/600**; sub "3件目 · clipB.webm" 12 .8 (sub copy matches) |
| Edge hints | none | 明るさ / 音量 vertical pills at left/right (8px) while controls shown |
| Control bar | flat rgba(0,0,0,.75); time | track | time in one row (12px labels, thumb 16, track 4) | gradient `0xBF000000 -> transparent`; slider full width then times (12px) on a row **below**, thumb 14, h56+20 |
| Buttons | lock-open, -10, pause (64 box/40 icon), +10, [PiP], tune; all 48 | same set minus PiP; `replay_10`/`forward_10` glyphs with "10"; pause iconSize 40 |
| tune active colour | accent (Foundation proposes) | **#FFAE00** (video_view.dart:767, video_levels.dart:48,212) |
| Action bar | h72, 5 items, 11px labels, all white | h76 (`viewerActionBarHeight`), 12px labels; Android has the same 5 (情報/オフライン/端末に保存/アルバムへ/ゴミ箱へ), web 3; **ゴミ箱へ is danger red #E0605E** |
| Notice | see X10 | `_flash` SnackBar |
| End/failed overlay | not drawn | "再生が終了しました" + replay icon 48, "再生できませんでした" |

### 3.8 Logo (#103, owner decision #96 pending)

Product = 案A: navy #0F2A43 tile with white photo + orange sun (`doc/brand/icon.svg`, Android `mipmap-*`, web `Icon-192/512.png` pixel (5,5)=#0F2A43). 案B (black #0A0A0F with gold #E4B95B line art) is not present anywhere. Nothing to fix until #96 is decided; the web manifest still says `r2_gallery` / `#0175C2` (3.17).

### 3.9 PipPlayer / 3.10 PipWindow / 3.11 PipBlocked / 3.12 Background (all missing)

| Board | Spec | Product |
|---|---|---|
| PipPlayer | PiP button 48x48 r24 between +10 and tune, icon 22 (rect with filled corner), highlight ring rgba(228,185,91,.35), aria "小窓で再生" | absent from `_controlBar` (video_view.dart) |
| PipWindow | 240x135 r12 floating window, shadow 0 6 20 rgba(0,0,0,.35); controls overlay rgba(0,0,0,.45): 元に戻す (top-left 44), 閉じる (top-right 44), 一時停止 centered 48 | none (no Android PiP code in `android/`) |
| PipBlocked | notice copies (exact): 端末の設定で、このアプリの小窓表示が許可されていません [設定を開く]; この端末は小窓での再生に対応していません; 画面ロックの猶予が「毎回ロック」のため、小窓では再生できません; ロック中は小窓で再生できません; いまは小窓にできませんでした。もう一度お試しください | none |
| Background | notification "R2 Gallery" + state text + 一時停止/再生 + 停止; lock-screen variant; no filename/thumbnail | none (`video_view.dart` only pauses when `_background`) |
PR #118 ("再生中にホームへ戻ったら自動で小窓にする") is the only open PR in this area; it does not add the button, window controls, blocked notices or the notification.

### 3.13 Review Settings / 3.14 Review Folder / 3.15 Review Lock / 3.16 Review ConnectEdit

**ReviewSettings** vs product: (all of the "current" differences in 3.4 plus) title "設定" vs "R2 Gallery"; no chips row vs chips; section headings 接続 / ロック / オフライン保存 / このアプリについて (13/20 700 #9C9AA8, margin 12 4 6) vs none; grouped cards (r16, rows divided by 1px #2A2A3A, min-h60, title 15/22, sub 12/16) vs one card per row; 接続中 row = "接続中 / [host] · ライブラリ 2 / 変更 ›" (dot 10 + 7 margin) vs non-tappable card; sub copies shortened: 開くとき指紋・顔・PINを求めます (P: 写真・アルバム・設定を開くとき、指紋・顔・PINを求めます); 再ロックまでの時間 value "1時間 ›" 14 with chevron 20 (P: no chevron); PIN row chevron; offline group title 端末に暗号化して保存中 / [件数]件 / 一覧 › (P: "オフライン保存" / N件 / ›); delete row min-h52 red (matches text); version row バージョン / 0.4.0（400） in its own group (P: centered "R2 Gallery (Flutter) 0.1.0"; pubspec is already 0.4.0+400); 切断 card removed (P keeps it). Open PRs #129 (version), #130 (headings), #131 (connect-edit) implement these, rebased onto settings_tab.dart.

**ReviewFolder** vs product: header h64: back 48, title 20/28 700 + breadcrumb "[ライブラリ名] › [親フォルダ] › [フォルダ名]" 12/16 dim, sort 48 vs AppBar title only (title x=72 vs D 56), no breadcrumb; subfolder strip above photos: header 「フォルダ N」 14/20 700 + count dim + 「すべて見る」 14/700 gold (h48), horizontal cards 112x88 r12 #1E1E2B, folder icon 24 gold top-left, name 13/18 bottom-left, gap 8, padding 0 16 8 vs product folder card 97x97 r8, centered icon + 12px 2-line label, placed **below** the photo rows, no header/count/すべて見る; day header 14/20 700 padding 16/16/8 vs 52px/600. #73/#74 (branch `feat/folders-above-photos-74`) and #127 (`folder_browse_screen.dart`, `gallery_tab.dart`) overlap.

**ReviewLock** vs product: title 20/28 vs 18; subtitle アプリを使うには、ロックを解除してください。 (P: 写真・アルバム・設定を開くには…, #69/#70); unlock button r14 h52 15/700; "または PIN で解除" 12/16; PIN label "PIN" above field 12/16 dim, field h56 r14 #1E1E2B border #6E6C7C (P: no label, hint "PIN", border #2A2A3A, gold when focused); PIN button outlined (border #6E6C7C, transparent, 15/700, h52) vs P gold filled; spacing: icon 48 → title (margin-top 4 + gap 12) vs P 20.

**ReviewConnectEdit**: whole screen missing. Spec: h56 header (back 48 + "接続先を変更" 20/28 700); card 今の接続先 (dot 10 #7FD1A8, label 13/20 dim, host 15/22); エンドポイント (prefilled "https://[接続先ホスト]") and アクセストークン (placeholder 変えない時は空のまま) fields h52 r14 #1E1E2B border #6E6C7C, 13/20 labels above; hint r2g://setup… のペアリング文字列を、どちらの欄に貼り付けても入ります。; result card 接続できました / ライブラリ 2 件が見つかりました。保存すると切り替わります。 (check icon #7FD1A8); buttons 接続を試す (outlined h52 r14) and 保存して切り替える (gold h52 r14); note つながらなかった時は保存されず、今の接続のまま使えます。失敗した時は理由（接続先に届かない／トークンが違う）をここに出します。; bottom red text button 切断して接続情報を消す (15/500). PR #131 (`connect_edit_screen.dart`) covers it; compare against the board when it merges.

### 3.17 Review Foundation (token table vs `theme.dart`, `web/`)

| Token / item | D proposal | P today |
|---|---|---|
| bg/surface/surfaceHigh/border/accent/textPrimary/textDim/danger | #0A0A0F/#14141D/#1E1E2B/#2A2A3A/#E4B95B/#F2F0EA/#9C9AA8/#E0605E | identical (`AppColors`) |
| success #7FD1A8 | theme token | hard-coded `_connectedGreen` in settings_tab.dart |
| onAccent #1A1408 | theme token | hard-coded in theme.dart (x2 incl. `onPrimary`), gallery_tab.dart FAB, selection_widgets.dart (4 places) |
| #FFAE00 panel colour | -> accent | still #FFAE00 (3 places) |
| black overlays | 55% bars, 80% panels | 0x8C (55%), 0xBF (75%), 0xCC (80%), 0x33 (20%), black87, white .9/.38, black 55% badge |
| Outline of pressable things | #6E6C7C (3:1) | #2A2A3A everywhere (inputs, SegmentedButton, chips) |
| Text styles | title 20/28 B, heading 16/24 B, body 15/22, label 14/20 B, caption 12/16 | none; sizes 11-28 hard-coded |
| Radius | 8 / 14 / 16 | 4, 8, 12, 14, 16, 20 in use (chip 20, album card 12, folder card 8, dialog 20, snackbar 12) |
| Targets | >=48dp, primary button 52 | primary buttons ~48 (theme padding), 52 only on Lock/Connect-specific `minimumSize` |
| Web title / home-screen name | R2 Gallery | `r2_gallery` (index.html title + apple-mobile-web-app-title, manifest name/short_name) |
| Web start colour | #0A0A0F | #0175C2 (manifest background_color, theme_color) |
| Settings version | build value "0.4.0（400）" | fixed "R2 Gallery (Flutter) 0.1.0" |
| App language | Japanese | no `locale`/`supportedLocales` in `main.dart` |
| Lock copy | アプリを使うには… | 写真・アルバム・設定を開くには… |

## 4. Top 10 differences (ranked by how many screens a user sees them on)

1. Bottom nav: unselected tabs are white instead of #9C9AA8, selected icon is the filled Material variant, no 1px top line, pill 64x32 not 56x30 (X1-X3). Every screen.
2. Library chips: centered, 6px high, with check/lock glyphs, and shown on Albums/Import/Trash; design has them left-aligned, label only, on Photos+Settings only (X5).
3. Icons: Material Icons instead of the design's line icons (lock, PIN, ±10, nav, actions) (X4).
4. Albums tab: titles overlaid on covers (design: below), segmented selected fill solid gold (design: 20% gold + gold text), dashed create tile, trash row is a card (3.2).
5. Photos tab: day header 52 vs 40 px, video badge corner vs centered, saved badge top-left square vs bottom-right circle (3.1).
6. Settings: no headings, no 変更 row / 接続先を変更, "Flutter 0.1.0" label; current-vs-review board conflict must be settled (sections 2, 3.4, 3.13).
7. Lock: title 18 vs 20/22, wrong subtitle copy for the review, PIN field/button styling matches neither board (3.5, 3.15).
8. Connect: label inside field instead of above with visible placeholder, title 800 vs 700, spacing 28 vs 24, disabled-grey primary (3.6).
9. Viewer/video: title is date not library name, control bar gradient + time labels below slider, #FFAE00, red trash, action bar 76 vs 72, no PiP button (3.7, 3.9).
10. Folder screen: no breadcrumb header, subfolders below photos instead of an above-strip with count and すべて見る (3.14); plus missing PiP window/blocked/background notification (#197/#196) and 接続先を変更 (#66/#67).

## 5. Android-only (cannot be shot on web) - compare by reading code

| Board | Code read | Finding |
|---|---|---|
| Import | `import_browser_tab.dart` | structure and copy match; styling per 3.3 |
| Lock (device auth) | `lock_gate.dart` | 「ロックを解除」 `FilledButton.icon` r14 minH52 + fingerprint; "端末の画面ロックを確認できませんでした…" / "認証できませんでした…" / "画面ロックがありません" states not on any board |
| Settings offline card | `offline_screen.dart` `OfflineSettingsCard` | rows/copy match; icons differ; delete dialog "オフライン保存をすべて削除しますか？" no board |
| Viewer offline/save | `viewer_screen.dart` `_actionBar` | 5 actions in the board's order; red trash; h76 |
| PipPlayer/PipWindow/PipBlocked/Background | grep `pip|PictureInPicture|MediaSession|audio_service` in `flutter/` and `android/` | no hits: not implemented |

## 6. Prioritized fix list: PR-sized chunks

Order matters: C1 first (tokens), then screens. "Overlap" = open work to coordinate with.

| Chunk | Scope | Boards | Overlap |
|---|---|---|---|
| C1 shared tokens + shell theme (one PR) | `theme.dart`: `success`, `onAccent`, accent for the #FFAE00 panel, 2-step overlays, radius set 8/14/16, `TextTheme` (title/heading/body/label/caption), outline #6E6C7C for pressable controls, `NavigationBarTheme` (unselected #9C9AA8, selected w700, top 1px line, indicator 56x30), `ChipTheme`, `SegmentedButtonTheme`, `FilledButton` sizes, snackbar | Foundation, X1-X3, X7-X10 | #76, #77 (settings/lock/connect swap), #78, #79: this is the token half of them; each screen swap stays in its own chunk |
| C2 app shell | library chips (left-aligned, 36px, label only, only on Photos+Settings per board), app bar titles per tab, nav labels | Main, Albums, Settings, Import | `home_shell.dart` is also edited by #131; do after #131 or rebase |
| C3 photos tab | day header 40, video badge centered 28, saved badge BR circle 18, tile placeholder, FAB label | Main | #127 (sort, `gallery_tab.dart`), `feat/folders-above-photos-74` (`media_grid.dart`): rebase after both |
| C4 albums tab | card layout (title below), segmented look, dashed create tile, 「その他」, trash row | Albums | none known |
| C5 folder screen | header + breadcrumb, subfolder strip (112x88), 「すべて見る」, day header | ReviewFolder | `feat/folders-above-photos-74` (#73/#74) is exactly this; #127 touches `folder_browse_screen.dart`. Land those first, then diff |
| C6 settings | headings, grouped cards, 接続中 row with 変更 (needs ConnectEdit), version row, copy | ReviewSettings (and Settings) | #129/#130/#131 (#92/#93/#66/#67) are the same files; verify against the board after they merge, do not start in parallel |
| C7 connect + lock | field labels above, spacing, button radii/sizes, PIN field, copy (アプリを使うには…) | Connect, ReviewLock, Lock | #69/#70 (copy), #77 |
| C8 viewer + video | top bar title, control bar flat 75% + time row, thumb 16, #FFAE00->accent, action bar 72/11px, trash colour (decision), notice style | Viewer | #118 (video), #71/#72 (lock wording), #79 |
| C9 PiP + background (new feature) | PiP button, floating-window controls, blocked notices, media notification | PipPlayer, PipWindow, PipBlocked, Background | #118 first (auto-PiP); #196/#197 are the real scope. Android-native work, not shot-checkable on web |
| C10 import tab restyle | URL field/go button sizes, radii | Import | #79 |
| C11 web identity | manifest name/colour, `index.html` title, favicon, launcher icon after owner picks | Foundation, Logo | `fix/web-manifest-60` (#60), #96 (owner decision pending) |

## 7. Decisions needed from the lead/owner (not decided here)

1. Settings and Lock: follow the 11/11 review boards (pending approval) or the 現行 boards? PRs #129-#131 already follow review.
2. Icon set: the design's line icons are custom; use Material Symbols Outlined/rounded, bundle SVGs, or accept Material Icons?
3. Screen title weight (Main 600 vs Foundation/review 700) and whether library chips really disappear from Albums/Import.
4. Whether the web 取り込み placeholder and web-disabled states need boards.
5. Boards for the screens that have none (section 1 list), if they must also match "exactly".

## 8. How to reproduce

- Design render: `cd /home/user/design-artifact/render` (copy of `doc/design/project/` + `support.js` in root, `review/`, `redesign/`), `python3 -m http.server 8099`, `node shot.js [name]` -> `/home/user/design-artifact/shots/`.
- Product: worker `cd /home/user/wt-design && pnpm exec wrangler dev --local --port 8797 --config worker/wrangler.test.toml --persist-to /home/user/design-seed/state`; seed `bash /home/user/design-seed/seed.sh`; app served from `/home/user/wt-design/flutter/build/web` on :8098; shots via `/home/user/design-prod/*.js`; side-by-sides via `python3 /home/user/design-prod/side.py`.
- Nothing in the repository was changed or committed. `/home/user/notes` is the existing `notes/r2-gallery` worktree; `design-parity.md` and `evidence/design/` are uncommitted files there.
