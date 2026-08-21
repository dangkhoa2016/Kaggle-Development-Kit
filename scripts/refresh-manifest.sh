#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp)"; INSTALL_TMP="$(mktemp)"
trap 'rm -f "$TMP" "$INSTALL_TMP"' EXIT
find . -type f \
  ! -path './.git/*' \
  ! -path './.system/*' \
  ! -path './.kaggle-ssh/*' \
  ! -name '.kaggle-dev.env' \
  ! -name 'MANIFEST.sha256' \
  ! -name '*.zip' \
  -print0 | sort -z | xargs -0 sha256sum > "$TMP"
mv "$TMP" MANIFEST.sha256
chmod 644 MANIFEST.sha256

(
  cd install
  find . -type f ! -name 'MANIFEST.sha256' -print0 | sort -z | xargs -0 sha256sum > "$INSTALL_TMP"
)
mv "$INSTALL_TMP" install/MANIFEST.sha256
chmod 644 install/MANIFEST.sha256
printf 'Updated %s and %s\n' "$ROOT/MANIFEST.sha256" "$ROOT/install/MANIFEST.sha256"
