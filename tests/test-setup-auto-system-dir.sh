#!/usr/bin/env bash
set -euo pipefail

# Regression P1.2: `setup.sh --full` auto toolchain mode must honor the
# project-wide KAGGLE_SYSTEM_DIR runtime-root contract when detecting a
# restored development environment.
#
# The auto branch historically inspected only "$PROJECT_ROOT/.system", so with
# KAGGLE_SYSTEM_DIR pointing at a persisted custom root, an existing runtime
# was treated as absent and a needless full install ran instead of a
# cold-restore bootstrap. Auto detection must resolve the same DEV_SYSTEM_DIR
# root the installers use: "${KAGGLE_SYSTEM_DIR:-$PROJECT_ROOT/.system}".

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

PROJ="$TMP/project"
FAKE_INSTALLER="$TMP/fake-install-all.sh"
mkdir -p "$PROJ"
cp "$ROOT/setup.sh" "$PROJ/setup.sh"

cat > "$FAKE_INSTALLER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${KDEV_SETUP_CALLS_LOG:?}"
EOF

run_toolchain_mode() {
    # $1 = expected mode passed to the fake installer; $2 = setup.sh mode.
    local expected="$1" mode="$2" calls="$TMP/calls.log" out
    out="$TMP/setup.out.log"
    rm -f "$calls"
    (
        export KDEV_SETUP_CALLS_LOG="$calls"
        export KAGGLE_SETUP_INSTALL_ALL_SCRIPT="$FAKE_INSTALLER"
        export KAGGLE_SETUP_AUTO_REPAIR=0
        export HOME="$TMP/home"
        # shellcheck disable=SC1091
        source "$PROJ/setup.sh"
        prepare_development_environment "$mode" >"$out" 2>&1
    )
    grep -qx "$expected" "$calls" ||
      fail "mode '$mode' dispatched '$(cat "$calls" 2>/dev/null || echo nothing)' instead of '$expected'"
}

# --- Scenario 1: custom KAGGLE_SYSTEM_DIR present => bootstrap restored state -
CUSTOM="$TMP/custom-system"
mkdir -p "$CUSTOM"
rm -rf "$PROJ/.system"

calls="$TMP/calls.log"; rm -f "$calls"
out="$TMP/setup-custom.out.log"
rc=0
(
    export KDEV_SETUP_CALLS_LOG="$calls"
    export KAGGLE_SETUP_INSTALL_ALL_SCRIPT="$FAKE_INSTALLER"
    export KAGGLE_SETUP_AUTO_REPAIR=0
    export HOME="$TMP/home"
    export KAGGLE_SYSTEM_DIR="$CUSTOM"
    # shellcheck disable=SC1091
    source "$PROJ/setup.sh"
    prepare_development_environment auto >"$out" 2>&1
) || rc=$?
[ "$rc" -eq 0 ] || fail "auto mode crashed with custom system dir (log: $out)"
grep -qx 'bootstrap' "$calls" ||
  fail "auto mode ignored KAGGLE_SYSTEM_DIR and chose '$(cat "$calls" 2>/dev/null || echo nothing)' instead of bootstrap"

# --- Scenario 2: no system root anywhere => first full install ---------------
rm -rf "$PROJ/.system" "$CUSTOM"
run_toolchain_mode install auto

# --- Scenario 3: explicit modes pass through unchanged ------------------------
mkdir -p "$PROJ/.system"
run_toolchain_mode bootstrap bootstrap
run_toolchain_mode install install

echo 'PASS: setup.sh auto mode honors KAGGLE_SYSTEM_DIR for restore detection'
