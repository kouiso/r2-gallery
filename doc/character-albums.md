# キャラ別アルバム仕分け（#31）

`tools/character-albums.mjs` は、R2 に追加されたキャラ画像を見た目で既存アルバムへ仕分ける運用ツール。
ファイル名・タイトル・パス・作成者メタデータは使わず、サムネイルの画素だけで判定する。

## 守っていること

- 画像はローカルの sharp で扱う。外部 AI・画像処理サービスには送らない
- `plan` は読み取りだけ。書き込むのは `apply` で、`approved: true` にしたグループだけ
- 原画像の移動・削除・上書きはしない。既存アルバムへの関連付け追加と、新規アルバム作成だけ
- 既にどこかのアルバムに入っている画像は手動仕分けとして触らない（`skipped`）
- `apply` を再実行しても二重登録・二重作成しない（Worker が `${lib}:${key}` で重複を弾き、作ったアルバムの id を plan に書き戻す）
- 読み取り専用アルバム（パイプライン生成・「その他」）には書かない
- Worker が一覧の途中で 503 / 429 を返したら待って取り直す。トークンと署名 URL はログに出さない

## 判定のしかた

1. 参照アルバム（`--ref-albums`）から最大 `--ref-per-album` 枚を均等に取り、特徴量を作る
2. 特徴量は HSV 色分布（全体＋上半分＝髪・顔まわりを 2 倍で重み付け）と dHash
3. 対象 1 枚ごとに、各アルバムの上位 3 枚との類似度の平均を出す（対象自身は参照から外す）
4. 判定
   - dHash が 6bit 以内 → ほぼ同一画像の別版（high、目視確認を促す）
   - 1 位と 2 位の差が 0.04 未満 → 要確認（複数人・似た別キャラの可能性）
   - 0.90 以上 → high、0.82 以上 → medium
   - それ未満 → 未マッチ。未マッチ同士を完全連結で束ね、2 枚以上の塊は「キャラクターA（仮）」の新規アルバム候補（low）、1 枚は未分類
5. `preview.html` に代表サムネ・候補グループ・枚数・確信度・根拠を出す（サムネは data URI でローカルに閉じる）

## 使い方

```bash
export R2G_ENDPOINT=https://notes-sync.kouiso.workers.dev
export R2G_TOKEN=...   # 1Password「R2 Gallery worker (notes-sync)」の access_token

# 初回の一括仕分け: 最近追加された 200 枚を対象にする
node tools/character-albums.mjs plan --lib personal --ref-albums さくら,ダウナーお姉さん,ひなた \
  --recent 200 --out .work/character-albums

# 差分: 今回アップロードしたキーだけを対象にする
node tools/character-albums.mjs plan --lib personal --ref-albums さくら,ダウナーお姉さん,ひなた \
  --keys-file new-keys.txt --out .work/character-albums

# preview.html を目で確認し、plan.json の反映したいグループを approved: true にする
node tools/character-albums.mjs apply --plan .work/character-albums/plan.json --dry-run
node tools/character-albums.mjs apply --plan .work/character-albums/plan.json
```

`--ignore-assigned` は精度評価用。配属済みの画像も照合し、その plan は `apply` できない。

## 実データでの精度（2026-11-10）

personal の「ひなた」15 枚と未分類 1 枚を、参照「ひなた・さくら・ダウナーお姉さん」で評価した。

| 結果                                        | 枚数                          |
| ------------------------------------------- | ----------------------------- |
| ひなたに正しく候補入り（high 6 / medium 1） | 7                             |
| さくらに誤って候補入り（high）              | 1                             |
| 要確認・未分類で保留                        | 8（ひなた 7、未分類だった 1） |

ひなたとさくらは髪色・花飾りが近く、色の特徴量だけでは見分けきれない。
誤りが出ても書き込み前のプレビューと承認で止まるが、approve の前に目視確認は必須。
顔の形や目元まで見るには、ローカルで動く画像埋め込みモデル（例: ONNX の顔・キャラ埋め込み）への差し替えが要る。
