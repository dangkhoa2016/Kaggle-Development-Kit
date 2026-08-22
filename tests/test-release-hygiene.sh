#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
COPY="$TMP/kaggle-dev-environment"
SOURCE_COPY_ERR="$TMP/source-copy.err"
mkdir -p "$COPY"
# Preserve source files/symlinks while excluding local runtime/private state.
# The release-hygiene fixture must not inspect live sockets under .system/.
tar -C "$ROOT" \
  --exclude='./.git' \
  --exclude='./.system' \
  --exclude='./.kaggle-ssh' \
  --exclude='./.kaggle-dev.env' \
  --exclude='./.env' \
  --exclude='./.env.*' \
  --exclude='*.zip' \
  -cf - . 2>"$SOURCE_COPY_ERR" | tar -C "$COPY" -xf -
if [ -s "$SOURCE_COPY_ERR" ]; then
  echo 'unexpected warning/error while copying release-hygiene source fixture:' >&2
  cat "$SOURCE_COPY_ERR" >&2
  exit 1
fi

mkdir -p "$COPY/debug" "$COPY/.system/qdrant/instances/1.18.3/run" "$COPY/.kaggle-ssh"
printf 'secret\n' > "$COPY/debug/private.key"
printf 'secret\n' > "$COPY/debug/secrets.env"
printf 'runtime\n' > "$COPY/debug/runtime.env"
printf 'log\n' > "$COPY/debug/qdrant.log"
printf '123\n' > "$COPY/debug/qdrant.pid"
printf 'runtime\n' > "$COPY/.system/qdrant/instances/1.18.3/run/runtime.txt"
printf 'secret\n' > "$COPY/.kaggle-ssh/authorized_keys"
printf 'local\n' > "$COPY/.kaggle-dev.env"

bash "$COPY/scripts/build-release-zips.sh" "$TMP/out" >/dev/null
ZIP="$TMP/out/kaggle-development-kit-v1.0.0.zip"
SIDECAR="$ZIP.sha256"
[ -f "$ZIP" ]
[ -f "$SIDECAR" ]
(
  cd "$TMP/out"
  sha256sum -c "$(basename "$SIDECAR")" >/dev/null
)
unzip -Z1 "$ZIP" > "$TMP/names"

grep -q 'README.md$' "$TMP/names"
grep -q '\.kaggle-dev.env.example$' "$TMP/names"
for forbidden in \
  '/.system/' '/.kaggle-ssh/' '/.kaggle-dev.env$' \
  '\.log$' '\.pid$' '\.sock$' '\.pem$' '\.key$' '\.p12$' '\.pfx$' \
  '/secrets.env$' '/runtime.env$' '/.qdrant-base$'; do
  if grep -E "$forbidden" "$TMP/names" >/dev/null; then
    echo "forbidden public artifact matched: $forbidden" >&2
    grep -E "$forbidden" "$TMP/names" >&2 || true
    exit 1
  fi
done

echo 'PASS: public release builder excludes runtime/private artifacts and writes a valid checksum sidecar'
