#!/usr/bin/env bash
set -euo pipefail

# Healthy/repaired Redis runtimes must not pay the APT build-dependency cost.
# The test sources the real installer, replaces only the APT dependency action
# and service-control helper, then executes the real main() orchestration.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"

cleanup_tmp() {
    if [ "$(id -u)" -eq 0 ]; then
        rm -rf "$TMP"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo rm -rf "$TMP"
    else
        rm -rf "$TMP" 2>/dev/null || true
    fi
}
trap cleanup_tmp EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export KAGGLE_SYSTEM_DIR="$TMP/system"
export KAGGLE_DEV_DEFAULTS_FILE=/dev/null
export KAGGLE_DEV_CONFIG_FILE=/dev/null
export REDIS_VERSIONS=8.10.0
export REDIS_DEFAULT_VERSION=8.10.0
export REDIS_AUTO_START_VERSIONS=""
export REDIS_BUILD_JOBS=1
export REDIS_SERVICE_USER="$(id -un)"
export REDIS_FORCE_RUNTIME_REFRESH=0
export KDEV_TEST_CALLS_LOG="$TMP/calls.log"
: > "$KDEV_TEST_CALLS_LOG"

# shellcheck disable=SC1090
source "$ROOT/install/install-redis.sh"

RUNTIME="$KAGGLE_SYSTEM_DIR/redis/versions/8.10.0"
mkdir -p "$RUNTIME/bin"
cat > "$RUNTIME/bin/redis-server" <<'SERVER'
#!/usr/bin/env bash
printf 'Redis server v=8.10.0 sha=00000000:0 malloc=libc bits=64 build=fixture\n'
SERVER
chmod 0755 "$RUNTIME/bin/redis-server"

# Any call here proves the healthy fast path still performs APT/network work.
ensure_build_dependencies() {
    printf 'APT_BUILD_DEPS\n' >> "$KDEV_TEST_CALLS_LOG"
    return 97
}

# Service startup is orthogonal to this regression. Keep main() validation real
# while replacing only the generated controller with a deterministic fake.
write_service_helper() {
    cat > "$SYSTEM_DIR/redis-service.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:-}"; ACTION="${2:-}"; shift 2 || true
case "$ACTION" in
    start|stop) exit 0 ;;
    cli)
        case "${1:-}" in
            --raw) printf 'redis_version:8.10.0\r\n' ;;
            GET) printf 'ok\n' ;;
            *) exit 0 ;;
        esac
        ;;
    *) exit 2 ;;
esac
HELPER
    chmod 0755 "$SYSTEM_DIR/redis-service.sh"
}

rc=0
main >"$TMP/out.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "healthy Redis main() failed: $(cat "$TMP/out.log")"
! grep -q '^APT_BUILD_DEPS$' "$KDEV_TEST_CALLS_LOG" ||
    fail 'healthy Redis runtime invoked APT build dependencies'
grep -q 'already exists.*skipping build' "$TMP/out.log" ||
    fail 'healthy Redis runtime did not take the build-skip path'

# The shared predicate must still classify an explicit force refresh as a build.
REDIS_FORCE_RUNTIME_REFRESH=1
runtime_requires_build 8.10.0 || fail 'force refresh did not require a Redis rebuild'

echo 'PASS: reusable Redis runtime skips APT build dependencies while force refresh still requires build'
