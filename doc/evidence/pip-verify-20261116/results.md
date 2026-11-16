# PiP / 動画 UX 検証（エミュレータ実施） 2026-11-16

- 端末: Android emulator `r2g-pip-35`（API 35, sdk_gphone64_arm64）
- ビルド: `fix/video-ux-reapply-208` @ 9519d6f の debug APK（arm64）。
  検証時のみ debug manifest に `usesCleartextTraffic=true` を一時追加
  （ローカル wrangler がトンネル経由で http:// の署名URLを返すため。コミット対象外・検証後に revert 済み）。
- バックエンド: ローカル wrangler dev（:8787）+ trycloudflare トンネル、ライブラリ Test A。

## 結果

| # | 場面 | 方法 | 結果 |
|---|------|------|------|
| 1 | 動画ビューアの操作群 | 画面確認 | PASS — 再生/一時停止、±10秒、速度、明るさ（左・画面内ボタン）、音量（右）、ロック、シークバーの208 UI が全て描画（01-viewer-controls.png） |
| 2 | 再生中にホームへ → 自動PiP | dumpsys + スクショ | PASS — `mode=pinned`、ホーム上に再生中のPiPウィンドウ（02-home-auto-pip.png） |
| 3 | PiP の再生/一時停止 RemoteAction | `am broadcast -a app.r2gallery.pip.PAUSE/PLAY` + フレーム差分 | PASS — PAUSE でフレーム凍結（2連続スクショが画素一致）、PLAY で再開（フレーム進行）。メニュー生成も logcat の PipMenuView 生成で確認。`hasSetActions=true` |
| 4 | PiP → 全画面復帰 | PiP メニューで拡大 → dumpsys | PASS — `mode=fullscreen` 復帰・ビューア継続（04-restore-fullscreen.png） |
| 5 | 小窓の中で自然終了 | 25秒動画をPiP内で終了まで再生 | PASS — PiP内で再生終了後もアプリごと落ちず、終了画面表示。`exitPip` は pipSession 一致で受け付けられる（acceptsExit） |

## 未検証（実機が要る項目）

- 明るさ・音量スライダーの実ドラッグ操作（UI描画のみ確認）
- ロック中にPiPごと閉じる系の実機挙動（`exitPip`→`finish()` は単体テスト済み）
- サブ画面（active:false）での自動PiP抑止はユニットテストで担保
