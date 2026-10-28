#!/usr/bin/env bash
# エミュレータに APK を入れ、端末側に選ぶ写真を置いてから Maestro を流す。
# 画面の画像は成果物に上げない。
# 落ちた時だけ、その時の画面の文字（試験用のファイル名とボタン名だけ）を出して原因を追えるようにする。
# 使い方: run.sh <APK> <作業ディレクトリ>
set -euo pipefail

APK=$1
WORK=$2
HERE=$(cd "$(dirname "$0")" && pwd)

# 落ちた時だけ、その時の画面の文字・手元 Worker が受けた要求・アプリのログを出す
dump_diag() {
  echo "::group::落ちた時の画面の文字"
  maestro hierarchy | python3 "$HERE/hierarchy-text.py" || true
  echo "::endgroup::"
  # 手元 Worker が受けた要求（メソッド・パス・状態だけ。トークンは出ない）とアプリのログ
  echo "::group::手元 Worker が受けた要求"
  grep -E "^\[wrangler:info\] (GET|PUT|POST|DELETE)" "$WORK/wrangler.log" | sed -E 's/\?[^ ]*//' | tail -50 || true
  echo "::endgroup::"
  echo "::group::アプリのログ"
  adb logcat -d -s flutter:V AndroidRuntime:E | tail -80
  echo "::endgroup::"
}

adb wait-for-device
# エミュレータの仮想ネットワークは起動直後に繋がっていないことがある（10.0.2.2 が unreachable）。
# adb の転送でホストの手元 Worker を端末の 127.0.0.1:8787 に見せ、ネットワークの状態に左右されんようにする
adb reverse tcp:8787 tcp:8787
# アプリより先に、端末から手元 Worker に届くかを確かめる（届かん時にアプリの不具合と見分けるため）
echo "端末 → 127.0.0.1:8787/health:"
adb shell 'printf "GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n" | toybox nc -w 5 127.0.0.1 8787' | tail -1
adb install -r "$APK"
# リリース版の manifest に INTERNET が無いと、どの接続先にも繋がらん（debug 版には Flutter の雛形が足すので気づきにくい）
perms=$(adb shell dumpsys package app.r2gallery | sed -n '/requested permissions:/,/install permissions:/p')
echo "$perms"
if ! grep -q 'android.permission.INTERNET' <<<"$perms"; then
  echo "::error::APK が android.permission.INTERNET を要求していません。リリース版はネットに繋がりません"
  exit 1
fi
adb logcat -c
adb push "$WORK/maestro-upload.jpg" /sdcard/Pictures/maestro-upload.jpg
# 端末の選択画面に出すため、置いた写真をメディアの一覧へ載せる
adb shell content call --method scan_volume --uri content://media --arg external_primary
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
  -d file:///sdcard/Pictures/maestro-upload.jpg

set +e
maestro test --format junit --output "$WORK/maestro-results.xml" \
  -e WORKER=http://127.0.0.1:8787 -e TOKEN=live-token "$HERE"
status=$?
set -e

if [ "$status" -ne 0 ]; then
  dump_diag
fi
exit "$status"
