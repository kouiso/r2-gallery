# キャラ別アルバム仕分け（#31）

`tools/character-albums.mjs` は、R2 に追加されたキャラ画像を見た目で既存アルバムへ仕分ける運用ツール。
ファイル名・タイトル・パス・作成者メタデータは使わず、画像の画素だけで判定する。

既定の判定は **CCIP**（deepghs の Contrastive Anime Character Image Pre-Training）と、アニメ人物検出の組合せ。
以前の HSV 色分布＋dHash の判定は `--engine color` で残している（モデルが使えない時の控え）。

## 守っていること

- 画像はローカルの sharp と onnxruntime-node で扱う。外部 AI・画像処理サービスには送らない
- 通信は Worker の読み書きと、モデルが手元に無い時の Hugging Face からのモデル取得だけ
- `plan` と `eval` は読み取りだけ。書き込むのは `apply` で、`approved: true` にしたグループだけ
- 原画像の移動・削除・上書きはしない。既存アルバムへの関連付け追加と、新規アルバム作成だけ
- 既にどこかのアルバムに入っている画像は手動仕分けとして触らない（`skipped`）
- `apply` を再実行しても二重登録・二重作成しない（Worker が `${lib}:${key}` で重複を弾き、作ったアルバムの id を plan に書き戻す）
- 読み取り専用アルバム（パイプライン生成・「その他」）には書かない
- Worker が一覧の途中で 503 / 429 を返したら待って取り直す。トークンと署名 URL はログに出さない

## 使うモデル

置き場所は `--model-dir`、無ければ環境変数 `R2G_MODEL_DIR`、無ければ `~/.cache/r2g-models`。
無いファイルは初回に Hugging Face の `resolve/main` から取り、大きさと sha256 を照合してから置く。
取りに行かせたくない時は `--offline`。

| 用途     | Hugging Face                                             | ファイル                      | 大きさ   | ライセンス |
| -------- | -------------------------------------------------------- | ----------------------------- | -------- | ---------- |
| 特徴量   | `deepghs/ccip_onnx` `ccip-caformer-24-randaug-pruned/`   | `model_feat.onnx`             | 150.2 MB | openrail   |
| 差の計算 | 同上                                                     | `model_metrics.onnx`          | 1.6 KB   | openrail   |
| 閾値     | 同上                                                     | `metrics.json` `cluster.json` | 数百 B   | openrail   |
| 人物検出 | `deepghs/anime_person_detection` `person_detect_v1.1_m/` | `model.onnx`（YOLOv8m）       | 103.5 MB | MIT        |

人物検出は imgutils の `detect_person` の既定（level m・v1.1、F1 0.87）。sha256 は `tools/character-albums-ccip.mjs` の `MODEL_FILES` にある。
onnxruntime-node はルートの devDependency。インストール時に CUDA 版を NuGet から取りに行くスクリプトが動かないよう、
`package.json` の `pnpm.neverBuiltDependencies` に入れている（CPU 版は npm パッケージに同梱されている）。

## 判定のしかた（CCIP）

1. 画像を RGB にする。透過は白で塗り、ICC と EXIF の回転は無視する（imgutils の `load_image` と同じ）
2. 人物検出: 640×640 へ BICUBIC で引き伸ばし（letterbox なし）、YOLOv8 の出力を conf 0.3・IoU 0.5 で NMS して元の座標へ戻す
3. 画像の 1% 未満の枠は捨て、信頼度順に最大 6 人。枠を 5% 広げて切り出す
4. 切り出しを 384×384 BILINEAR → CHW → /255 → CLIP の mean/std で正規化し、CCIP で 768 次元の特徴量にする
5. 参照アルバム（`--ref-albums`）ごとに、人物が 1 人だけ写った画像の切り出しを sha1(key) 順に最大 `--ref-per-album` 枚集める。
   複数人の画像はどの人物がアルバムのキャラか分からないので参照に使わない。代表は `ccip_merge` と同じ式で作る
6. 切り出し 1 人ごとに、各アルバムの参照との差（metric モデル。小さいほど同じキャラ）を出す。
   アルバムの点数は近い 3 枚の差の平均。代表との差も見る
7. 判定（1 人分）
   - 最小の点数が閾値 `threshold` を超える → 未マッチ
   - 1 位と 2 位のアルバムの差が `margin` 未満 → 要確認（似た別キャラ）
   - 点数が `high` 以下で、代表との差も閾値以下 → 一致（high）
   - それ以外で閾値以下 → 一致（medium）
8. 画像 1 枚の判定
   - 人物 0 人 → **キャラなし**。照合しない（下の「限界」参照）
   - 1 人 → その人の判定
   - 複数人 → 全員が同じアルバムに一致した時だけ一致。揃わなければ要確認。全員未マッチなら未分類
9. 1 人だけ写った未マッチ同士を DBSCAN（eps 0.1292・min_samples 2、差は metric モデル）で束ね、
   2 枚以上の塊は「キャラクターA（仮・実行 id）」の新規アルバム候補（low）。残りは未分類
10. `preview.html` に判定に使った人物の切り出し・判定・CCIP の差（1 位・2 位・代表）・根拠と、キャラなしの枠を出す
    （画像は data URI でローカルに閉じる）

### 閾値と理由

| 名前                 | 既定      | 理由                                                                                      |
| -------------------- | --------- | ----------------------------------------------------------------------------------------- |
| `threshold`          | 0.1785    | `metrics.json` の値。deepghs の評価で同キャラ判定の F1 が最大（0.917、precision 0.933）   |
| `high`               | 0.1292    | `cluster.json` の dbscan_2 の eps。同キャラ同士が密に集まる距離                           |
| `margin`             | 0.03      | 似た 2 キャラを勝手に寄せないための安全側の幅。`eval` の sweep で実データに合わせて変える |
| `topK`               | 3         | 1 枚だけ似た参照に引っ張られないため                                                      |
| `clusterEps`         | 0.1292    | `cluster.json` の dbscan_2（deepghs が束ねの成績で選んだ値）                              |
| `detConf` / `detIou` | 0.3 / 0.5 | imgutils の `detect_person` の既定                                                        |
| `minPersonFrac`      | 0.01      | 512px のサムネで約 51px 角未満は顔が判別できず、背景の小さな人影で複数人扱いになるため    |
| `cropMargin`         | 0.05      | 検出枠が髪の先や頭頂を切りがちなため                                                      |

`--threshold` と `--margin` で上書きできる。他の値は `tools/character-albums-ccip-core.mjs` の `ccipParams`。

### imgutils との一致

前処理は dghs-imgutils 0.19.0 と同じ結果になるよう、Pillow の縮小（22bit 固定小数点の係数と、
縦の縮み幅が横の 2 倍を超える時に縦から先にかける順序）と、透過の白塗り（整数の DIV255）を JS で書いた。
合成画像 6 枚（RGB PNG・RGBA PNG・1600×2240 JPEG・拡大になる 300×200・グレースケール・WebP サムネ）を
Python（onnxruntime 1.32・numpy 2.5・Pillow 13）と Node で比べた結果（2026-11-27）:

- デコード後の画素・CCIP の入力・YOLO の入力・YOLO の生出力・特徴量・差の表: すべて最大差 0（ビット一致、cos 1.0000000）
- 縮小だけを任意の大きさ 40 通り（bilinear / bicubic、20〜2500px）で比べても全一致
- metric モデルは組ごとに独立（2 枚だけ流しても全部まとめても同じ値）

Pillow 10 以前は常に横から先にかけるので、古い Pillow の imgutils とは画素が ±1 ずれることがある（特徴量の cos は 0.99998 程度）。

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

# 精度を測る（書き込まない）。参照アルバム同士で 1 枚抜きの照合をする
node tools/character-albums.mjs eval --lib personal --ref-albums さくら,ダウナーお姉さん,ひなた \
  --ref-per-album 24 --max-per-album 100 --out .work/character-albums

# Worker に繋がず、手元の画像で人物検出と CCIP の差を見る
node tools/character-albums.mjs analyze a.png b.webp
```

共通オプション: `--engine ccip|color`（既定 ccip）、`--model-dir`、`--threads N`（既定は論理コアの半分）、
`--offline`、`--image-source thumb|original`（既定 thumb。原寸は細部が残るが 1 枚数 MB を落とす）、`--threshold`、`--margin`。

`--ignore-assigned` は精度評価用。配属済みの画像も照合し（自分自身は参照から外す）、その plan は `apply` できない。

### eval の中身

- 各参照アルバムから sha1(key) 順の先頭 `--max-per-album` 枚を評価する。千枚を超えるアルバムと数十枚のアルバムを同じ規則で間引け、
  画像が増えても既存の標本は入れ替わらない
- 参照は同じ順で人物が 1 人だけの画像を最大 `--ref-per-album` 枚。評価する画像自身は参照からも代表からも外す（leave-one-out）
- アルバムごとの precision・recall・保留率（要確認・未マッチ・キャラなし）・誤り率、全体（枚数平均）とアルバム平均、取り違え表
- 閾値 0.10〜0.25 × margin 0〜0.08 の sweep。推論はやり直さず、保存した差から判定し直す
- 2 つの参照アルバムに入っている画像は、どちらに入れても正解として数える
- 結果は `<out>/eval.json`（1 枚ごとの判定と差も入る）と、画面の要約

## CPU 時間（2026-11-27、Ryzen 9 9900X・WSL2、12 スレッド）

人物 1 人の 512px 前後の画像で、1 枚あたり:

| 段階                               | ms     |
| ---------------------------------- | ------ |
| デコード（sharp）                  | 13     |
| 人物検出（640 への縮小 11 を含む） | 86     |
| 切り出しと CCIP の前処理           | 5      |
| CCIP の特徴量                      | 77     |
| 合計                               | 約 180 |

人物のいない画像は CCIP を回さないので約 100ms。人物が増えると 1 人あたり約 75ms 増える。
onnxruntime の既定（論理コア数 24 スレッド）だと CCIP が倍以上遅かったので、既定は論理コアの半分にしている。
GPU は要らない。200 枚の plan は参照の推論込みで 1 分前後の見込み（上の値からの計算で、実データでは未計測）。

## 動作確認（2026-11-27）

手元の miniflare Worker（`worker/wrangler.test.toml`、本番ではない）に、SVG で描いた 3 キャラ（髪色・髪型・服違い、各 8 枚）と
2 人並び 1 枚・風景 3 枚を入れて plan → eval → apply → 再 plan を通した。

- 人物検出に掛かった画像はすべて正しいアルバムへ high で一致（同キャラの差 0.002〜0.007、別キャラ同士 0.25〜0.32）
- 2 人並び（別キャラ）は要確認、風景と検出漏れの絵はキャラなし
- 参照から外したキャラは DBSCAN で新規アルバム候補（2 枚）にまとまった
- apply は承認した 2 グループだけ追加し、再実行は追加 0 枚。apply 後の plan は配属済みとして触らない
- 描いた絵は人物検出の取りこぼしが多かった（24 枚中 14 枚）。実際のアニメ絵での検出率は `eval` の「キャラなし」で確かめる

実データ（personal の さくら / ひなた / ダウナーお姉さん）での CCIP の精度はまだ測っていない。
`eval` を回して、sweep を見て `--threshold` / `--margin` を決める。

## 限界

- CCIP はキャラのいない絵同士をほぼ同一とみなす（合成画像同士の差 0.02〜0.12、閾値より小さい）。
  人物検出で 0 人の画像はキャラなしに回して照合しないが、検出の誤検出（背景を人物と見る）が起きるとその枠は照合される。
  その場合も未マッチか、低い確信度の候補止まりになることを preview で確かめる
- CCIP は 1 枚に 1 キャラの画像を前提にしている。複数人の画像は人物ごとに切り出し、揃わなければ要確認に回す
- 人物検出（F1 0.87）は顔のアップ・体の一部・崩した絵柄を取りこぼす。取りこぼしはキャラなしに入るので、
  キャラなしの枠も目で確認する
- 参照は人物が 1 人だけの画像からしか作らない。集合絵ばかりのアルバムは参照が足りず警告が出る
- サムネ（長辺 512px）では小さく写った人物の細部が潰れる。精度が足りない時は `--image-source original`
- 誤りが出ても書き込み前のプレビューと承認で止まるが、approve の前に目視確認は必須

## 色の判定（`--engine color`）

1. 参照アルバムから最大 `--ref-per-album` 枚を均等に取り、HSV 色分布（全体＋上半分を 2 倍で重み付け）と dHash を作る
2. 各アルバムの上位 3 枚との類似度の平均で判定（dHash 6bit 以内は同一画像の別版、1 位と 2 位の差 0.04 未満は要確認、
   0.90 以上 high、0.82 以上 medium）。未マッチは完全連結で束ねる

2026-11-10 に personal の「ひなた」15 枚と未分類 1 枚を、参照「ひなた・さくら・ダウナーお姉さん」で評価した結果:

| 結果                                        | 枚数                          |
| ------------------------------------------- | ----------------------------- |
| ひなたに正しく候補入り（high 6 / medium 1） | 7                             |
| さくらに誤って候補入り（high）              | 1                             |
| 要確認・未分類で保留                        | 8（ひなた 7、未分類だった 1） |

ひなたとさくらは髪色・花飾りが近く、色の特徴量だけでは見分けきれなかった。これが CCIP へ切り替えた理由。
