#!/usr/bin/env bash
set -euo pipefail

# Regression: doctor must validate the exact project-managed Node/Ruby/npm/Yarn
# toolchain. A runnable mise binary alone is not a healthy toolchain.
#
# The check must be observational: MISE_AUTO_INSTALL=0 prevents doctor from
# silently auto-installing a missing tool while diagnosing it.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SYS="$TMP/system"
MISE_ROOT="$SYS/mise"
DEFAULTS="$TMP/defaults.env"
STATE="$TMP/state.env"

mkdir -p "$MISE_ROOT/bin" "$MISE_ROOT/data/installs"
cat > "$DEFAULTS" <<'EOF_DEFAULTS'
MISE_VERSION=2026.8.1
TOOL_NODE_VERSION=26.6.0
TOOL_RUBY_VERSION=3.4.9
TOOL_NPM_VERSION=12.0.2
TOOL_YARN_VERSION=1.22.22
EOF_DEFAULTS

cat > "$MISE_ROOT/env.sh" <<EOF_ENV
#!/usr/bin/env bash
export MISE_ROOT="$MISE_ROOT"
export MISE_DATA_DIR="$MISE_ROOT/data"
export MISE_CONFIG_DIR="$MISE_ROOT/config"
export MISE_GLOBAL_CONFIG_FILE="$MISE_ROOT/config/config.toml"
export MISE_CACHE_DIR="$MISE_ROOT/cache"
export MISE_STATE_DIR="$MISE_ROOT/state"
export MISE_TMP_DIR="$MISE_ROOT/tmp"
export PATH="$MISE_ROOT/bin:\$PATH"
EOF_ENV
chmod 0755 "$MISE_ROOT/env.sh"

cat > "$STATE" <<'EOF_STATE'
NODE_VERSION=20.19.0
RUBY_VERSION=3.4.9
NPM_VERSION=10.8.2
YARN_VERSION=1.22.22
EOF_STATE

cat > "$MISE_ROOT/bin/mise" <<'EOF_MISE'
#!/usr/bin/env bash
set -euo pipefail

root="${KDEV_TEST_MISE_ROOT:?}"
# shellcheck source=/dev/null
source "${KDEV_TEST_STATE:?}"

require_project_context_if_requested() {
    [ "${KDEV_TEST_REQUIRE_PROJECT_CWD:-0}" = "1" ] || return 0
    [ -n "${KDEV_TEST_PROJECT_ROOT:-}" ] || exit 90
    [ "$PWD" = "$KDEV_TEST_PROJECT_ROOT" ] || exit 91
    [ -f "$PWD/mise.toml" ] || exit 92
}

case "${1:-}" in
    --version|version)
        printf '2026.8.1 linux-x64 (fixture)\n'
        ;;
    which)
        require_project_context_if_requested
        tool="${2:?missing tool}"
        case "$tool" in
            node) ver="$NODE_VERSION"; expected=26.6.0 ;;
            ruby) ver="$RUBY_VERSION"; expected=3.4.9 ;;
            npm) ver="$NPM_VERSION"; expected=12.0.2 ;;
            yarn) ver="$YARN_VERSION"; expected=1.22.22 ;;
            *) exit 1 ;;
        esac
        # Expose a managed path regardless of version so doctor must validate
        # both provenance and exact version, not merely path existence.
        path="$root/data/installs/$tool/$expected/bin/$tool"
        if [ "$tool" = npm ]; then
            path="$root/data/installs/npm/12.0.2/package/bin/npm"
        fi
        mkdir -p "$(dirname "$path")"
        : > "$path"
        chmod 0755 "$path"
        printf '%s\n' "$path"
        ;;
    exec)
        require_project_context_if_requested
        shift
        [ "${1:-}" = "--" ] && shift
        tool="${1:?missing tool}"
        shift
        [ "${1:-}" = "--version" ] || exit 2
        case "$tool" in
            node) printf 'v%s\n' "$NODE_VERSION" ;;
            ruby) printf 'ruby %s (fixture)\n' "$RUBY_VERSION" ;;
            npm) printf '%s\n' "$NPM_VERSION" ;;
            yarn) printf '%s\n' "$YARN_VERSION" ;;
            *) exit 1 ;;
        esac
        ;;
    *)
        exit 2
        ;;
esac
EOF_MISE
chmod 0755 "$MISE_ROOT/bin/mise"

export KDEV_TEST_MISE_ROOT="$MISE_ROOT"
export KDEV_TEST_STATE="$STATE"

run_doctor() {
    local label="$1"
    DOCTOR_OUT="$TMP/doctor-$label.log"
    rc=0
    (
        export KAGGLE_SYSTEM_DIR="$SYS"
        export KAGGLE_DEV_DEFAULTS_FILE="$DEFAULTS"
        export KDEV_TEST_MISE_ROOT="$MISE_ROOT"
        export KDEV_TEST_STATE="$STATE"
        cd /
        bash "$ROOT/scripts/doctor.sh"
    ) > "$DOCTOR_OUT" 2>&1 || rc=$?
}

# Scenario 1: mise itself runs, but Node/npm are wrong. Doctor must fail.
run_doctor mismatch
[ "$rc" -ne 0 ] || \
    fail "doctor returned success although managed Node/npm versions were wrong (log: $DOCTOR_OUT)"
grep -q '❌[[:space:]]*mise node' "$DOCTOR_OUT" || \
    fail "doctor did not report the Node pin failure explicitly (log: $DOCTOR_OUT)"
grep -q '❌[[:space:]]*mise npm' "$DOCTOR_OUT" || \
    fail "doctor did not report the npm pin failure explicitly (log: $DOCTOR_OUT)"

# Scenario 2: all four managed exact pins are healthy. Doctor remains OK.
cat > "$STATE" <<'EOF_STATE_GOOD'
NODE_VERSION=26.6.0
RUBY_VERSION=3.4.9
NPM_VERSION=12.0.2
YARN_VERSION=1.22.22
EOF_STATE_GOOD

run_doctor healthy
[ "$rc" -eq 0 ] || \
    fail "doctor rejected a healthy exact mise toolchain (log: $DOCTOR_OUT)"
for label in 'mise node' 'mise ruby' 'mise npm' 'mise yarn'; do
    grep -q "✅[[:space:]]*$label" "$DOCTOR_OUT" || \
        fail "doctor did not report healthy $label (log: $DOCTOR_OUT)"
done

# Scenario 3:
# KAGGLE_SYSTEM_DIR is external to the project and doctor is invoked from "/".
# The managed toolchain itself is healthy, but mise requires project context
# to discover ROOT/mise.toml.
#
# This regression fails if doctor lets mise which / mise exec inherit the
# caller's CWD instead of resolving the toolchain from PROJECT_ROOT.
export KDEV_TEST_REQUIRE_PROJECT_CWD=1
export KDEV_TEST_PROJECT_ROOT="$ROOT"

run_doctor external-system-outside-root

if [ "$rc" -ne 0 ]; then
    cat "$DOCTOR_OUT" >&2
    fail "doctor remained CWD-dependent with external KAGGLE_SYSTEM_DIR"
fi

for label in 'mise node' 'mise ruby' 'mise npm' 'mise yarn'; do
    grep -q "✅[[:space:]]*$label" "$DOCTOR_OUT" || \
        fail "outside-root doctor did not report healthy $label"
done

unset KDEV_TEST_REQUIRE_PROJECT_CWD
unset KDEV_TEST_PROJECT_ROOT

echo 'PASS: doctor validates exact managed pins and is CWD-independent with external KAGGLE_SYSTEM_DIR'
