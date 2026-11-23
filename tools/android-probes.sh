#!/usr/bin/env bash
# Android framework に依存しない判定ロジック（PipPolicy / ForegroundPromotion）を
# javac + java で検査する。JUnit や Gradle を起こさないので run.mjs fast に載せても軽い。
set -euo pipefail
cd "$(dirname "$0")/.."

PKG=app/r2gallery/r2_gallery
SRC=flutter/android/app/src
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

javac -d "$OUT" \
  "$SRC/main/java/$PKG/PipPolicy.java" \
  "$SRC/main/java/$PKG/ForegroundPromotion.java" \
  "$SRC/main/java/$PKG/PickSpec.java" \
  "$SRC/test/java/$PKG/PipPolicyProbe.java" \
  "$SRC/test/java/$PKG/ForegroundPromotionProbe.java" \
  "$SRC/test/java/$PKG/PickSpecProbe.java"

java -cp "$OUT" app.r2gallery.r2_gallery.PipPolicyProbe
java -cp "$OUT" app.r2gallery.r2_gallery.ForegroundPromotionProbe
java -cp "$OUT" app.r2gallery.r2_gallery.PickSpecProbe
