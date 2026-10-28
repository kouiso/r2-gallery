#!/usr/bin/env bash
set -euo pipefail
if command -v gitleaks >/dev/null; then
  GITLEAKS=gitleaks
else
  : "${RUNNER_TEMP:?Install gitleaks 8.24.3 or provide an isolated RUNNER_TEMP directory}"
  VER=8.24.3
  DIR="$RUNNER_TEMP/gitleaks-$VER"
  mkdir -p "$DIR"
  curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${VER}/gitleaks_${VER}_$(uname -s | tr '[:upper:]' '[:lower:]')_$(uname -m | sed 's/arm64/arm64/;s/x86_64/x64/').tar.gz" | tar xz -C "$DIR"
  GITLEAKS="$DIR/gitleaks"
fi
BASE="${CI_SCAN_BASE:-}"
if [ -n "$BASE" ] && [ "$BASE" != "0000000000000000000000000000000000000000" ]; then
  "$GITLEAKS" detect --redact -v --exit-code=2 --source . --log-level=warn \
    --log-opts="--no-merges --first-parent ${BASE}^..${CI_SCAN_HEAD:-HEAD}"
else
  "$GITLEAKS" detect --redact -v --exit-code=2 --source . --log-level=warn
fi
