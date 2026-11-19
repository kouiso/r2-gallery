LOCAL-CHECK | head 5ea35d5b1d7aa52596ed1b97db82709705f904b9 | flutter analyze; flutter test --concurrency=1; pnpm install --frozen-lockfile; node .github/ci/run.mjs fast; node tools/sync-ai-rules.mjs --check; flutter build web --release + Chromium 390px | pass 486 fail 0 | 2026-11-14 13:43Z-13:58Z

env: 4 CPU box, Flutter SDK /home/user/flutter-sdk, worktree of origin/feat/connect-edit + 1 commit.
- analyze: info 7 件（base と同数・同内容）、新規なし
- flutter test --concurrency=1: 486 件すべて通過（13:53-13:56Z）。--concurrency=2 / 既定では負荷依存の時間テスト 1 件が落ちる（pin_test「照合のハッシュ計算中も…」。base 3b748eb でも --concurrency=2 で同じく落ちる。既定では transfer_queue_test が 1 件。単体実行は通過）
- pnpm install --frozen-lockfile OK / ci fast exit 0 / sync-ai-rules --check 同期済み
- fail-before: test/connect_switch_test.dart を 3b748eb の別 worktree で実行 → 2 件失敗（folder が a/photos のまま）。修正後は通過
- 画像: notes/evidence/131-5ea35d5-{app,design}-{default,success,failure}*.png
