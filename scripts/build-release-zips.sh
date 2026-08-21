#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT="$(dirname "$ROOT")"
NAME="$(basename "$ROOT")"
OUT_DIR="${1:-$PARENT}"
PUBLIC_ZIP="$OUT_DIR/kaggle-dev-environment-github-public.zip"

command -v zip >/dev/null 2>&1 || { echo 'zip command is required.' >&2; exit 1; }
mkdir -p "$OUT_DIR"
bash "$ROOT/scripts/refresh-manifest.sh"
rm -f "$PUBLIC_ZIP"
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
printf 'Public source release: %s\n' "$PUBLIC_ZIP"
printf 'Runtime/private state is intentionally excluded.\n'
