#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_TMP="$(mktemp -d)"
ROOTS="$HARNESS_TMP/roots"
FAKE_BIN="$HARNESS_TMP/bin"
mkdir -p "$ROOTS" "$FAKE_BIN"

# The service identity must be able to traverse the test harness parent; the
# acceptance script itself is responsible only for the mktemp RUN_ROOT it owns.
chmod 0755 "$HARNESS_TMP" "$ROOTS"

cleanup() {
  chmod -R u+rwX "$HARNESS_TMP" 2>/dev/null || true
  rm -rf "$HARNESS_TMP"
}
trap cleanup EXIT

cat > "$FAKE_BIN/git" <<'GIT'
#!/usr/bin/env bash
exit 1
GIT
chmod +x "$FAKE_BIN/git"

set +e
PATH="$FAKE_BIN:$PATH" \
TMPDIR="$ROOTS" \
KDEV_QDRANT_ACCEPTANCE_KEEP=1 \
  bash "$ROOT/tests/acceptance-qdrant.sh" >"$HARNESS_TMP/out.log" 2>&1
status=$?
set -e

[ "$status" -eq 75 ] || {
  cat "$HARNESS_TMP/out.log" >&2
  echo "expected blocked preflight exit 75, got $status" >&2
  exit 1
}

mapfile -t created < <(find "$ROOTS" -mindepth 1 -maxdepth 1 -type d -print)
[ "${#created[@]}" -eq 1 ] || {
  printf 'expected exactly one acceptance root, found %s\n' "${#created[@]}" >&2
  exit 1
}
RUN_ROOT="${created[0]}"

mode="$(stat -c '%a' "$RUN_ROOT")"
[ "$mode" = 711 ] || {
  echo "expected acceptance root mode 711, got $mode" >&2
  exit 1
}

[ "$(stat -c '%a' "$RUN_ROOT/qdrant.env")" = 600 ] || {
  echo 'qdrant.env must remain mode 600' >&2
  exit 1
}

# On root-capable environments (including Kaggle), prove a non-owner identity
# can traverse the acceptance root but cannot read its private root-owned config.
if [ "$(id -u)" -eq 0 ] && command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
  runuser -u nobody -- test -x "$RUN_ROOT"
  if runuser -u nobody -- test -r "$RUN_ROOT/qdrant.env"; then
    echo 'service identity must not read root-owned qdrant.env' >&2
    exit 1
  fi
fi

# 0711 gives only execute/traverse to group/other, never write.
[ "$(( 8#$mode & 8#066 ))" -eq 0 ]

echo 'PASS: qdrant acceptance mktemp root permits service-user traversal without exposing config'
