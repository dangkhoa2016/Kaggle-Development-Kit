#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT="$(dirname "$ROOT")"
NAME="$(basename "$ROOT")"
OUT_DIR="${1:-$PARENT}"
RELEASE_VERSION="${KDEV_RELEASE_VERSION:-1.0.0}"
PUBLIC_ZIP="$OUT_DIR/kaggle-development-kit-v${RELEASE_VERSION}.zip"
PUBLIC_SHA256="$PUBLIC_ZIP.sha256"

command -v zip >/dev/null 2>&1 || { echo 'zip command is required.' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo 'sha256sum command is required.' >&2; exit 1; }
mkdir -p "$OUT_DIR"
bash "$ROOT/scripts/refresh-manifest.sh"
rm -f "$PUBLIC_ZIP" "$PUBLIC_SHA256"
(
  cd "$PARENT"
  zip -q -r -y "$PUBLIC_ZIP" "$NAME" \
    -x "$NAME/.git/*" \
       "$NAME/.system/*" \
       "$NAME/.kaggle-ssh/*" \
       "$NAME/.kaggle-dev.env" \
       "$NAME/.env" "$NAME/.env.*" \
       "$NAME/*.zip" \
       '*.log' '*.pid' '*.sock' \
       '*.pem' '*.key' '*.p12' '*.pfx' \
       '*/secrets.env' '*/runtime.env' '*/.qdrant-base'
)
(
  cd "$OUT_DIR"
  sha256sum "$(basename "$PUBLIC_ZIP")" > "$(basename "$PUBLIC_SHA256")"
)
printf 'Public source release: %s\n' "$PUBLIC_ZIP"
printf 'SHA-256 sidecar: %s\n' "$PUBLIC_SHA256"
printf 'Runtime/private state is intentionally excluded.\n'
