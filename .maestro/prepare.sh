#!/usr/bin/env bash
# 手元の Worker（miniflare の R2）を立て、試験用の写真と動画を置く。
# 本番の Worker には向けない。ゴミ箱へ送って戻すので、本物の写真を動かしてしまう。
# 使い方: prepare.sh <リポジトリのルート> <作業ディレクトリ>
set -euo pipefail

R2G=$(cd "$1" && pwd)
WORK=$2
WORKER=http://127.0.0.1:8787
TOKEN=live-token
mkdir -p "$WORK"

# 確認用の設定（固定のトークンと署名鍵。本番の値ではない）。PR の分かれ元に左右されんよう .maestro 側で持つ
HERE=$(cd "$(dirname "$0")" && pwd)
cp "$HERE/wrangler.maestro.toml" "$R2G/worker/wrangler.maestro.toml"
(cd "$R2G/worker" && nohup npx wrangler dev --local --port 8787 \
  -c wrangler.maestro.toml --persist-to "$WORK/state" >"$WORK/wrangler.log" 2>&1 &)
for _ in $(seq 1 90); do
  if curl -sf "$WORKER/health" >/dev/null; then break; fi
  sleep 1
done
curl -sf "$WORKER/health" >/dev/null || { cat "$WORK/wrangler.log"; exit 1; }

# 動画は再生中の判定に数秒要るので 12 秒にする。端末側で選ぶ写真は一覧の写真と別の絵にする
ffmpeg -loglevel error -y -f lavfi -i testsrc=size=320x240:rate=15 -t 12 \
  -c:v libx264 -pix_fmt yuv420p -profile:v baseline -movflags +faststart "$WORK/seed-clip.mp4"
ffmpeg -loglevel error -y -f lavfi -i testsrc=size=480x360 -frames:v 1 "$WORK/seed-photo.jpg"
ffmpeg -loglevel error -y -f lavfi -i smptebars=size=480x360 -frames:v 1 "$WORK/maestro-upload.jpg"

put() {
  curl -sf -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: $2" \
    --data-binary "@$WORK/$1" "$WORKER/v1/a/objects?key=$1"
  echo
}
put seed-photo.jpg image/jpeg
put seed-clip.mp4 video/mp4
