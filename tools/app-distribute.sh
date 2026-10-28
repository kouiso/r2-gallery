#!/usr/bin/env bash
# Build the Flutter release APK and upload it to Firebase App Distribution.
#
# Required environment (never committed; keep in 1Password / CI secrets):
#   FIREBASE_APP_ID         Firebase Android app id (from the operator console)
#
# Authentication (one of):
#   FIREBASE_TOKEN          `firebase login:ci` token, or
#   GOOGLE_APPLICATION_CREDENTIALS  path to a service-account json
#
# Optional:
#   QN_TESTERS              comma-separated tester emails (must be in ALLOWED_TESTERS)
#   QN_RELEASE_NOTES        short neutral notes (default below)
#
# Usage:
#   tools/app-distribute.sh            # build + upload
#   tools/app-distribute.sh <apk>      # upload an existing APK only
set -euo pipefail
cd "$(dirname "$0")/.."

# なぜ: この APK は持ち主本人にしか配らん（2026-10-07 に別の人へ届いた事故がある）。
# 宛先は呼び出し側の環境変数ではなくここで固定し、tools/app-distribute.test.mjs が中身を固定する。
# グループはメンバーを後から誰でも足せて宛先を確かめようがないので受け付けん。
ALLOWED_TESTERS=("kouiso@ritmo.co.jp")

if [ -n "${QN_GROUPS:-}" ]; then
  echo "refused: QN_GROUPS is not supported; list testers in QN_TESTERS" >&2
  exit 1
fi

testers=()
if [ -n "${QN_TESTERS:-}" ]; then
  IFS=',' read -r -a requested <<<"$QN_TESTERS"
  for raw in "${requested[@]}"; do
    t="$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ -z "$t" ] && continue
    ok=0
    for a in "${ALLOWED_TESTERS[@]}"; do [ "$t" = "$a" ] && ok=1; done
    if [ "$ok" -ne 1 ]; then
      echo "refused: tester not in allow list: $t" >&2
      exit 1
    fi
    testers+=("$t")
  done
fi

: "${QN_RELEASE_NOTES:=Maintenance update.}"

if [ -z "${FIREBASE_APP_ID:-}" ]; then
  echo "missing env: FIREBASE_APP_ID" >&2
  exit 1
fi

APK="${1:-flutter/build/app/outputs/flutter-apk/app-release.apk}"

if [ ! -f "$APK" ]; then
  echo "building Flutter release APK..."
  (cd flutter && flutter pub get && flutter build apk --release)
fi

echo "APK sha256: $(sha256sum "$APK" | cut -d' ' -f1)"

args=(appdistribution:distribute "$APK" --app "$FIREBASE_APP_ID" --release-notes "$QN_RELEASE_NOTES")
if [ "${#testers[@]}" -gt 0 ]; then
  args+=(--testers "$(IFS=,; printf '%s' "${testers[*]}")")
fi

echo "uploading to App Distribution..."
pnpm dlx firebase-tools "${args[@]}"
