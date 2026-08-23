#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Every checksummed release file must be tracked by git: ignored or untracked
# scratch never exists in a clean checkout, so listing it in a manifest makes
# downstream verification (CI, release zips) fail open-or-read checks.
if [ -f "$ROOT/MANIFEST.sha256" ] && [ -d "$ROOT/.git" ]; then
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    rel="${entry#./}"
    if ! git -C "$ROOT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
      echo "manifest lists a file git does not track: $entry" >&2
      exit 1
    fi
  done < <(awk '$2 ~ /^\.\// {print $2}' "$ROOT/MANIFEST.sha256")
fi

COPY="$TMP/kaggle-dev-environment"
SOURCE_COPY_ERR="$TMP/source-copy.err"
mkdir -p "$COPY"
# Preserve source files/symlinks while excluding local runtime/private state.
# The release-hygiene fixture must not inspect live sockets under .system/.
# .git stays: manifest/release tooling enumerates git-tracked content.
tar -C "$ROOT" \
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

# Exercise the documented "$PWD/release" layout and seed an old sidecar so the
# builder must keep prior output state out of both the manifest and the ZIP.
OUT="$COPY/release"
mkdir -p "$OUT"
printf 'stale\n' > "$OUT/old-build.zip.sha256"

bash "$COPY/scripts/build-release-zips.sh" "$OUT" >/dev/null
ZIP="$OUT/kaggle-development-kit-v1.0.0.zip"
SIDECAR="$ZIP.sha256"
EXPECTED_ROOT='Kaggle-Development-Kit-v1.0.0/'
[ -f "$ZIP" ]
[ -f "$SIDECAR" ]
(
  cd "$OUT"
  sha256sum -c "$(basename "$SIDECAR")" >/dev/null
)
unzip -Z1 "$ZIP" > "$TMP/names"

grep -Fxq "$EXPECTED_ROOT" "$TMP/names"
while IFS= read -r entry; do
  case "$entry" in
    "$EXPECTED_ROOT"*) ;;
    *)
      echo "public artifact entry escaped stable release root: $entry" >&2
      exit 1
      ;;
  esac
done < "$TMP/names"
# README.md and the manifests are introduced by the later documentation
# commits; only require archive entries for sources present in this tree so
# the check stays self-consistent at every historical commit.
if [ -f "$ROOT/README.md" ]; then
  grep -Fxq "${EXPECTED_ROOT}README.md" "$TMP/names"
fi
grep -Fxq "${EXPECTED_ROOT}.kaggle-dev.env.example" "$TMP/names"
# The public artifact must only ever embed files git tracks: ignored or
# untracked scratch on a maintainer machine must never leak into releases.
while IFS= read -r entry; do
  case "$entry" in "$EXPECTED_ROOT"*) ;; *) continue ;; esac
  rel="${entry#"$EXPECTED_ROOT"}"
  [ -n "$rel" ] || continue
  if ! git -C "$ROOT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    echo "public artifact embeds a file git does not track: $entry" >&2
    exit 1
  fi
done < "$TMP/names"
if grep -Fq "${EXPECTED_ROOT}release/" "$TMP/names"; then
  echo 'public artifact recursively embedded its output directory' >&2
  exit 1
fi
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

EXTRACT="$TMP/extracted"
mkdir -p "$EXTRACT"
unzip -q "$ZIP" -d "$EXTRACT"
(
  cd "$EXTRACT/${EXPECTED_ROOT%/}"
  if [ -f MANIFEST.sha256 ]; then
    sha256sum -c MANIFEST.sha256 >/dev/null
  fi
  cd install
  if [ -f MANIFEST.sha256 ]; then
    sha256sum -c MANIFEST.sha256 >/dev/null
  fi
)

echo 'PASS: public release builder uses a stable versioned root, excludes output/runtime/private artifacts, preserves manifest integrity, and writes a valid checksum sidecar'
