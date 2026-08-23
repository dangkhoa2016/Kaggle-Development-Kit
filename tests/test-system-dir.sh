#!/usr/bin/env bash
set -euo pipefail

# Regression: KAGGLE_SYSTEM_DIR is a project-wide runtime-root contract.
#
# install-all.sh, install-qdrant.sh and bin/kdev honor the override, but the
# per-service installers historically hard-coded "$PROJECT_ROOT/.system". A
# caller exporting KAGGLE_SYSTEM_DIR would split runtime state across two
# trees (SQLite/Qdrant in the custom dir; PostgreSQL/Redis/Elastic/mise under
# the source checkout), breaking persistence and doctor/restore flows.
#
# The test sources each installer in a throwaway subshell (they are guarded
# by a BASH_SOURCE==$0 main dispatch) and asserts SYSTEM_DIR resolves to the
# configured override. bin/kdev is checked at its single definition point,
# which fully determines its runtime resolution.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CUSTOM="$TMP/custom-system"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

resolve_system_dir() {
    local script="$1"
    (
        export KAGGLE_SYSTEM_DIR="$CUSTOM"
        # shellcheck disable=SC1090
        source "$ROOT/$script"
        printf '%s' "${SYSTEM_DIR:-<unset>}"
    )
}

for svc in install-postgres install-redis install-elastic install-other install-qdrant; do
    resolved="$(resolve_system_dir "install/$svc.sh")" ||
      fail "sourcing install/$svc.sh crashed"
    [ "$resolved" = "$CUSTOM" ] ||
      fail "install/$svc.sh ignores KAGGLE_SYSTEM_DIR (resolved: '$resolved')"
done

resolved="$(resolve_system_dir "install/install-all.sh")" ||
  fail "sourcing install/install-all.sh crashed"
[ "$resolved" = "$CUSTOM" ] ||
  fail "install/install-all.sh ignores KAGGLE_SYSTEM_DIR (resolved: '$resolved')"

grep -qF 'SYSTEM_DIR="${KAGGLE_SYSTEM_DIR:-$PROJECT_ROOT/.system}"' "$ROOT/bin/kdev" ||
  fail "bin/kdev does not resolve SYSTEM_DIR from KAGGLE_SYSTEM_DIR"

echo 'PASS: every installer and bin/kdev honor KAGGLE_SYSTEM_DIR consistently'
