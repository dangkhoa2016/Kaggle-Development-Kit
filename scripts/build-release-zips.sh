#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$(dirname "$ROOT")}"
RELEASE_VERSION="${KDEV_RELEASE_VERSION:-1.0.0}"
RELEASE_ROOT_NAME="Kaggle-Development-Kit-v${RELEASE_VERSION}"

command -v tar >/dev/null 2>&1 || { echo 'tar command is required.' >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo 'zip command is required.' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo 'sha256sum command is required.' >&2; exit 1; }

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
PUBLIC_ZIP="$OUT_DIR/kaggle-development-kit-v${RELEASE_VERSION}.zip"
PUBLIC_SHA256="$PUBLIC_ZIP.sha256"

OUT_REL=''
if [ "$OUT_DIR" != "$ROOT" ]; then
  case "$OUT_DIR/" in
    "$ROOT/"*) OUT_REL="${OUT_DIR#"$ROOT"/}" ;;
  esac
fi

KDEV_MANIFEST_EXCLUDE_DIR="$OUT_REL" bash "$ROOT/scripts/refresh-manifest.sh"
rm -f "$PUBLIC_ZIP" "$PUBLIC_SHA256"

STAGE_DIR="$(mktemp -d)"
STAGE_ROOT="$STAGE_DIR/$RELEASE_ROOT_NAME"
SOURCE_COPY_ERR="$STAGE_DIR/source-copy.err"
trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$STAGE_ROOT"

TAR_EXCLUDES=(
  --exclude='./.git'
  --exclude='./.system'
  --exclude='./.kaggle-ssh'
  --exclude='./.kaggle-dev.env'
  --exclude='./.env'
  --exclude='./.env.*'
  --exclude='*.zip'
  --exclude='*.zip.sha256'
  --exclude='*.log'
  --exclude='*.pid'
  --exclude='*.sock'
  --exclude='*.pem'
  --exclude='*.key'
  --exclude='*.p12'
  --exclude='*.pfx'
  --exclude='secrets.env'
  --exclude='runtime.env'
  --exclude='.qdrant-base'
)

# If the requested output directory lives inside the checkout (for example
# "$PWD/release"), exclude it from staging so old artifacts/sidecars cannot be
# recursively embedded in the new public ZIP.
if [ -n "$OUT_REL" ]; then
  TAR_EXCLUDES+=(--exclude="./$OUT_REL" --exclude="./$OUT_REL/*")
fi

tar -C "$ROOT" "${TAR_EXCLUDES[@]}" -cf - . 2>"$SOURCE_COPY_ERR" \
  | tar -C "$STAGE_ROOT" -xf -
if [ -s "$SOURCE_COPY_ERR" ]; then
  echo 'unexpected warning/error while staging public release source:' >&2
  cat "$SOURCE_COPY_ERR" >&2
  exit 1
fi

(
  cd "$STAGE_DIR"
  zip -q -r -y "$PUBLIC_ZIP" "$RELEASE_ROOT_NAME"
)
(
  cd "$OUT_DIR"
  sha256sum "$(basename "$PUBLIC_ZIP")" > "$(basename "$PUBLIC_SHA256")"
)

printf 'Public source release: %s\n' "$PUBLIC_ZIP"
printf 'SHA-256 sidecar: %s\n' "$PUBLIC_SHA256"
printf 'Archive root: %s/\n' "$RELEASE_ROOT_NAME"
printf 'Runtime/private state is intentionally excluded.\n'
