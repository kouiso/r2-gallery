#!/usr/bin/env bash
# #181 作業4: issue の「確かめ方」の6手順をエミュレータで回す。
# 録画は手順ごとに /sdcard へ置き、終わったら $WORK/rec に引く。結果は results.md に表で書く。
# 使い方: verify.sh <リポジトリ(app 側 checkout)> <作業ディレクトリ>
set -uo pipefail

APP=${1:?}
# ランナーの script 渡しで第2引数が落ちることがあるので job env の WORK に退避する
WORK=${2:-${WORK:?}}
REC=$WORK/rec
RES=$WORK/results.md
WLOG=$WORK/wrangler.log
PKG=app.r2gallery
TOKEN=live-token
mkdir -p "$REC"
: > "$RES"

# ---- helpers ----

# 手元 Worker が受けた一覧の要求数（1ページ = 1行）
# grep -c は不一致でも 0 を印字して終了1を返すので、|| echo 0 を付けると「0\n0」になる
pages() { local n; n=$(grep -c "GET /v1/a/folders" "$WLOG" 2>/dev/null || true); echo "${n:-0}"; }

# 帯（再試行）が画面に居るか: 1 以上なら居る
band_count() {
  adb shell uiautomator dump /sdcard/u.xml >/dev/null 2>&1 || true
  local n
  n=$(adb shell cat /sdcard/u.xml 2>/dev/null | grep -o 'text="[^"]*"' | { grep -c '再試行' || true; })
  echo "${n:-0}"
}

shot() { adb exec-out screencap -p > "$REC/$1.png" 2>/dev/null || true; }

# 録画の回し始め・止め（screenrecord は1本170秒上限。長い手順は回し直す）
rec_on() {
  adb shell "screenrecord --time-limit 170 /sdcard/$1.mp4 >/dev/null 2>&1 &" 2>/dev/null || true
  sleep 1
}
rec_off() {
  adb shell "pkill -INT -f screenrecord" >/dev/null 2>&1 || true
  sleep 3
  adb pull "/sdcard/$1.mp4" "$REC/" >/dev/null 2>&1 || true
}

fling()     { adb shell input swipe 540 1900 540 150 110 >/dev/null 2>&1; sleep 0.2; }
fling_up()  { adb shell input swipe 540 300 540 2100 110 >/dev/null 2>&1; sleep 0.15; }
pullrefresh(){ adb shell input swipe 540 450 540 1600 700 >/dev/null 2>&1; sleep 1.5; }

worker_start() {
  (cd "$APP/worker" && nohup npx wrangler dev --local --port 8787 \
    -c wrangler.maestro.toml --persist-to "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/w181-state" >>"$WLOG" 2>&1 &)
  for _ in $(seq 1 60); do
    curl -sf http://127.0.0.1:8787/health >/dev/null && return 0; sleep 1
  done
  return 1
}
worker_stop() { pkill -f "wrangler dev" 2>/dev/null || true; sleep 2; }

# target ページ取れるか、帯が出るか、30回変化なし、まで下へ送り続ける
scroll_until() {
  local target=$1 max=$2 stall=0 last=0 i p
  for i in $(seq 1 "$max"); do
    fling
    p=$(pages)
    if [ "$p" -gt "$last" ]; then last=$p; stall=0; else stall=$((stall+1)); fi
    [ "$p" -ge "$target" ] && break
    [ "$stall" -ge 30 ] && break
    [ "$(band_count)" -ge 1 ] && break
  done
  echo "$last"
}

tap_text() {
  local t=$1 b x1 y1 x2 y2
  adb shell uiautomator dump /sdcard/u.xml >/dev/null 2>&1 || true
  b=$(adb shell cat /sdcard/u.xml 2>/dev/null | tr '<' '\n' | grep "text=\"$t\"" | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1)
  [ -z "$b" ] && return 1
  x1=$(echo "$b" | sed -E 's/.*\[([0-9]+),[0-9]+\].*/\1/')
  y1=$(echo "$b" | sed -E 's/.*\[[0-9]+,([0-9]+)\].*/\1/')
  x2=$(echo "$b" | sed -E 's/.*\]\[([0-9]+),.*/\1/')
  y2=$(echo "$b" | sed -E 's/.*,[0-9]+\]\[[0-9]+,([0-9]+)\].*/\1/')
  adb shell input tap $(( (x1+x2)/2 )) $(( (y1+y2)/2 )) >/dev/null 2>&1
}

row() { echo "| $1 | $2 | $3 |" >> "$RES"; }

{
  echo "# #181 作業4 検証結果"
  echo
  cat "$WORK/meta.txt" 2>/dev/null
  echo "device=$(adb shell getprop ro.product.model | tr -d '\r') android=$(adb shell getprop ro.build.version.release | tr -d '\r') api=34(emu)"
  echo
  echo "| 番号 | 結果 | 補足 |"
  echo "|---|---|---|"
} >> "$RES"

adb wait-for-device
adb reverse tcp:8787 tcp:8787
adb install -r "$APP/flutter/build/app/outputs/flutter-apk/app-release.apk" >/dev/null
adb logcat -c

# 診断(#181): アプリが最初の一覧要求で受け取る応答そのものを控える。
# 「1リクエストで止まる」時に、cursor が無い(これ以上無い)か、空で止まったかを分ける
PROBE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8787/v1/a/folders?prefix=&recursive=1&order=recent&sort=new" | \
  jq -r '"total=\(.total // "?") items=\((.items // []) | length) cursor=\(if .cursor then "yes" else "no" end)"' 2>/dev/null || echo probe-failed)
echo "worker_first_page: $PROBE" >> "$RES"

launch() {
  # マージ後 manifest の activity 名は namespace (app.r2gallery.r2_gallery) で解決される
  # ため "$PKG/.MainActivity" は存在しないクラスを指し起動に失敗する。
  adb shell am start -n "$PKG/app.r2gallery.r2_gallery.MainActivity" >/dev/null 2>&1 || \
    adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  # 手順の前提はアプリが前面に居ること。ドロワー上で fling しても何も動かないので、
  # 前面に出るまで立ち上げ直し、出なければ logcat を残して落とす。
  for _ in $(seq 1 10); do
    adb shell dumpsys window 2>/dev/null | grep -q "mCurrentFocus.*$PKG" && return 0
    adb shell am start -n "$PKG/app.r2gallery.r2_gallery.MainActivity" >/dev/null 2>&1
    sleep 2
  done
  adb logcat -d > "$WORK/logcat-launch.txt" 2>/dev/null || true
  echo "launch failed: app never reached foreground (logcat-launch.txt)" >> "$RES"
  exit 1
}

# ---- 手順 1: 写真タブを開き、fling で末尾まで送り続ける ----
rec_on s1
launch
sleep 12
P1=$(scroll_until 30 1200)
sleep 5
P1F=$(pages); B1=$(band_count); shot s1_end
rec_off s1
row "1" "ページ数=$P1F/30・帯=$B1" "$( [ "$P1F" -ge 30 ] && echo 末尾まで || echo 止まった )"

# ---- 手順 2: 先頭へ戻って引っ張って更新し、また末尾まで送る ----
rec_on s2
for _ in $(seq 1 60); do fling_up; done
pullrefresh
BASE2=$(pages)
P2=$(scroll_until $((BASE2+30)) 1200)
sleep 5
P2F=$(pages); shot s2_end
rec_off s2
row "2" "増分=$((P2F-BASE2))ページ" "$( [ $((P2F-BASE2)) -ge 29 ] && echo 末尾まで || echo 止まった )"

# ---- 手順 3: アプリ完全終了→Worker停止起動→控えが出たら2画面下げる→Worker起動→末尾で待つ ----
rec_on s3
adb shell am force-stop "$PKG"
worker_stop
launch
sleep 8
fling; fling; fling; fling
B3=$(pages)
worker_start || true
# 末尾まで送ってから待つ（控えが出ている前提。末尾近くで止まって続きが足されるか見る）
scroll_until $((B3+30)) 1200 >/dev/null
T0=$(date +%s)
OK3=1
for _ in $(seq 1 60); do
  [ "$(pages)" -ge $((B3+30)) ] && { OK3=0; break; }
  fling; sleep 0.5
done
EL3=$(( $(date +%s) - T0 ))
P3F=$(pages); shot s3_end
rec_off s3
row "3" "経過=${EL3}秒・ページ数=$((P3F-B3))/30" "$( [ $OK3 -eq 0 ] && echo 続きが足された || echo 60秒で足されず )"

# ---- 手順 4: 3000件読み→Worker停止→末尾で帯待ち→Worker起動→末尾で待つ ----
rec_on s4
B4=$(pages)
# まだ先頭側なら3000件(16ページ)まで送る
[ "$B4" -lt 16 ] && scroll_until 16 800 >/dev/null
B4=$(pages)
worker_stop
# 帯が出るまで末尾で待つ（失敗して待ちがかかり帯が出る）
T0=$(date +%s); BAND4=0
for _ in $(seq 1 120); do
  [ "$(band_count)" -ge 1 ] && { BAND4=1; break; }
  fling; sleep 0.5
done
shot s4_band
worker_start || true
T0=$(date +%s)
for _ in $(seq 1 60); do
  [ "$(pages)" -gt "$B4" ] && [ "$(band_count)" -eq 0 ] && break
  fling; sleep 0.5
done
EL4=$(( $(date +%s) - T0 ))
P4F=$(pages); B4F=$(band_count); shot s4_end
rec_off s4
row "4" "帯検出=$BAND4・復帰=${EL4}秒・帯=$B4F・ページ差=$((P4F-B4))" "件数不減の線: ページ数が減っていない"

# ---- 手順 5: 同じく止めた後、Worker起動してすぐ帯の「再試行」を押す ----
rec_on s5
worker_stop
for _ in $(seq 1 60); do
  [ "$(band_count)" -ge 1 ] && break
  fling; sleep 0.5
done
P5B=$(pages)
worker_start || true
sleep 3
tap_text "再試行" || true
sleep 8
P5F=$(pages); shot s5_end
rec_off s5
row "5" "ページ $P5B→$P5F（先頭へ戻ると減る・続きだと増える）" "$( [ "$P5F" -ge "$P5B" ] && echo 先頭へ戻らず || echo 先頭へ戻った )"

# ---- 手順 6: 500件上げながら写真タブを下へ送る ----
rec_on s6
P6B=$(pages)
( seq -w 6001 6500 | xargs -P4 -I{} curl -sf -X PUT \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: image/jpeg" \
    -T "$WORK/seed.jpg" "http://127.0.0.1:8787/v1/a/objects?key=scroll/{}.jpg" -o /dev/null ) &
UPID=$!
# 上げながら下へ送り続ける（6500件→33ページ分。手順5までで ~30 取ってるので +4）
scroll_until $((P6B+4)) 1200 >/dev/null
wait $UPID 2>/dev/null || true
for _ in $(seq 1 80); do fling_up; done
pullrefresh
T0=$(date +%s); OK6=1
for _ in $(seq 1 60); do
  curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8787/v1/a/folders?order=recent" | grep -q 'scroll/6500.jpg' && { OK6=0; break; }
  sleep 1
done
shot s6_top
scroll_until $((P6B+34)) 1200 >/dev/null
P6F=$(pages); shot s6_end
rec_off s6
row "6" "新着が先頭に出た=$([ $OK6 -eq 0 ] && echo yes || echo no)・総ページ=$P6F" "末尾まで=$([ "$P6F" -ge $((P6B+33)) ] && echo yes || echo partial)"

# アプリ側の log も残す（クラッシュ・通信エラーが結果表からは読めないため）
adb logcat -d > "$WORK/logcat.txt" 2>/dev/null || true
cat "$RES"
