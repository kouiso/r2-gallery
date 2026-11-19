TITLE: [SBI] 再開時の中身の照合を、全部ダウンロードせずに進捗つきで行う
(follow-up of #121 review want3; create when rate limit lifts; template per .github rules)

### なぜ直したいか
#121 で、再開時に同名があるとサーバーの物と手元の中身を sha256 で照合するようにしました。今の実装（`ApiClientTransferApi.storedMatches`）は、サーバー側の物を最後まで読んでからハッシュを取り、手元の物も別に最後まで読みます。
- 照合中は進捗が出ず、大きい動画では長く止まって見えます。
- Web ビルドでは、読み込みのバッファと手元の再読み込みが重なり、メモリが約2倍になりえます。
- サイズが同じ別ファイルを毎回最後まで読みます。

### どうなったら終わりか
- [ ] 照合中の進捗（読んだバイト数）が転送の行に出る
- [ ] ストリームで読み、メモリに全体を載せない（Web でも）
- [ ] 一部のバイトが違えば最後まで読まずに「別物」と判断できる（同じと決める時だけ全体を読む）
- [ ] 照合の読み出しが失敗しても「完了」にならない（#121 のテストを維持）

### その他
- 関連: #41 #42
- 場所: flutter/lib/src/transfer/transfer_api.dart の `storedMatches`、flutter/lib/src/transfer/transfer_queue.dart の `_storedSame`
