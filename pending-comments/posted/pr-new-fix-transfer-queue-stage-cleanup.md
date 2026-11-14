title: 転送キュー: 退避ファイルを消し終えてから完了を報告する
base: main
head: fix/transfer-queue-stage-cleanup
draft: false

## 概要
アップロード完了テスト「選んだファイルは退避してから上がり、終わったら退避ファイルと台帳から消える」が間欠的に落ちる問題の修正です。
hosted CI の失敗: https://github.com/kouiso/r2-gallery/actions/runs/43600783777

## 原因
フレークではなくプロダクト側の順序の不具合です。`TransferQueue._run` が `t.status = done` にしてから `await _dropStaged(t)` で退避ファイルを消していました。完了を見た側（画面・テスト）は、削除が終わる前の退避ファイルを見ることがあります。負荷が高いと delete の完了が遅れるため、間欠的に `Expected: empty / Actual: [.../stage/up-u1.bin]` になります。

## 修正
`_dropStaged` を `status = done` と `_done.add` の前に移し、退避ファイルの削除を終えてから完了を報告します。台帳の書き出しは従来どおり先です。削除に失敗しても従来どおり握りつぶし、次回起動時の掃除に任せます。

## テスト
- 退避ファイルの `delete` だけを 300ms 遅らせる File を `IOOverrides` で差し込む回帰テストを追加しました。sleep もリトライもなく、順序を決定的に再現します。
- 修正前: 追加テストは 5/5 回失敗（CI と同じ `Expected: empty`）。
- 修正後: 追加テストは 5/5 回成功。`transfer_queue_test.dart` を `--concurrency=2` で 30 回実行して pass 30 / fail 0。
- `flutter test --concurrency=2` は 479 件すべて成功。`flutter analyze` の info 7 件は既存のもので、今回のファイルには出ていません。
- `node .github/ci/run.mjs fast` と `node tools/sync-ai-rules.mjs --check` は成功。

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01Cv4a6EYroSzGSReCUes9tm
