#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXCLUDE_DIR="${KDEV_MANIFEST_EXCLUDE_DIR:-}"
EXCLUDE_DIR="${EXCLUDE_DIR#./}"

case "$EXCLUDE_DIR" in
  '' ) ;;
  /*|..|../*|*/../*|*/..)
    echo "KDEV_MANIFEST_EXCLUDE_DIR must be a safe path relative to the repository root: $EXCLUDE_DIR" >&2
    exit 2
    ;;
esac

cd "$ROOT"
TMP="$(mktemp)"; INSTALL_TMP="$(mktemp)"
trap 'rm -f "$TMP" "$INSTALL_TMP"' EXIT

ROOT_FIND=(
  find . -type f
  ! -path './.git/*'
  ! -path './.system/*'
  ! -path './.kaggle-ssh/*'
  ! -name '.kaggle-dev.env'
  ! -name 'MANIFEST.sha256'
  ! -name '*.zip'
  ! -name '*.zip.sha256'
)
if [ -n "$EXCLUDE_DIR" ]; then
  ROOT_FIND+=( ! -path "./$EXCLUDE_DIR" ! -path "./$EXCLUDE_DIR/*" )
fi
"${ROOT_FIND[@]}" -print0 | sort -z | xargs -0 sha256sum > "$TMP"
mv "$TMP" MANIFEST.sha256
chmod 644 MANIFEST.sha256

(
  cd install
  INSTALL_FIND=(
    find . -type f
    ! -name 'MANIFEST.sha256'
    ! -name '*.zip'
    ! -name '*.zip.sha256'
  )
  if [[ "$EXCLUDE_DIR" == install/* ]]; then
    INSTALL_EXCLUDE_DIR="${EXCLUDE_DIR#install/}"
    INSTALL_FIND+=( ! -path "./$INSTALL_EXCLUDE_DIR" ! -path "./$INSTALL_EXCLUDE_DIR/*" )
  fi
  "${INSTALL_FIND[@]}" -print0 | sort -z | xargs -0 sha256sum > "$INSTALL_TMP"
)
mv "$INSTALL_TMP" install/MANIFEST.sha256
chmod 644 install/MANIFEST.sha256
printf 'Updated %s and %s\n' "$ROOT/MANIFEST.sha256" "$ROOT/install/MANIFEST.sha256"
