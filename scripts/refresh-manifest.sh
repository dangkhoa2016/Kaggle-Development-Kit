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
LIST_TMP="$(mktemp)"; INSTALL_LIST_TMP="$(mktemp)"
trap 'rm -f "$TMP" "$INSTALL_TMP" "$LIST_TMP" "$INSTALL_LIST_TMP"' EXIT

# Release integrity must cover exactly what git tracks. Ignored or untracked
# files (local scratch such as temp/, runtime state, editor droppings) never
# exist in a clean checkout, so hashing the raw filesystem would make every
# downstream `sha256sum -c` fail with open-or-read errors there. The name-based
# filters below stay as defense-in-depth even for files someone force-added.
TRACKED_EXCLUDE_RE='^\.git(/|$)|^\.system(/|$)|^\.kaggle-ssh(/|$)|(^|/)\.kaggle-dev\.env$|(^|/)\.env($|\.)|\.zip($|\.sha256$)|\.(log|pid|sock|pem|key|p12|pfx)$|(^|/)secrets\.env$|(^|/)runtime\.env$|(^|/)\.qdrant-base$|(^|/)MANIFEST\.sha256$'

git ls-files -z \
  | grep -zEv "$TRACKED_EXCLUDE_RE" >"$LIST_TMP"
if [ -n "$EXCLUDE_DIR" ]; then
  grep -zv "^${EXCLUDE_DIR}(/|$)" "$LIST_TMP" >"${LIST_TMP}.filtered"
  mv "${LIST_TMP}.filtered" "$LIST_TMP"
fi
sed -z 's|^|./|' "$LIST_TMP" | LC_ALL=C sort -z | xargs -0 sha256sum > "$TMP"
mv "$TMP" MANIFEST.sha256
chmod 644 MANIFEST.sha256

(
  cd install
  git ls-files -z . \
    | grep -zEv "$TRACKED_EXCLUDE_RE" >"$INSTALL_LIST_TMP"
  if [[ "$EXCLUDE_DIR" == install/* ]]; then
    INSTALL_EXCLUDE_DIR="${EXCLUDE_DIR#install/}"
    grep -zv "^${INSTALL_EXCLUDE_DIR}(/|$)" "$INSTALL_LIST_TMP" >"${INSTALL_LIST_TMP}.filtered"
    mv "${INSTALL_LIST_TMP}.filtered" "$INSTALL_LIST_TMP"
  fi
  sed -z 's|^|./|' "$INSTALL_LIST_TMP" | LC_ALL=C sort -z | xargs -0 sha256sum > "$INSTALL_TMP"
)
mv "$INSTALL_TMP" install/MANIFEST.sha256
chmod 644 install/MANIFEST.sha256
printf 'Updated %s and %s\n' "$ROOT/MANIFEST.sha256" "$ROOT/install/MANIFEST.sha256"
