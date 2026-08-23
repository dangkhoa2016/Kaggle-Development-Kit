#!/usr/bin/env bash
set -euo pipefail

# Regression: a standalone Redis reinstall must repair nested persisted writable
# state after a Kaggle cold restore without transferring managed metadata/config
# ownership away from root.

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || {
        echo 'FAIL: this ownership regression requires root or passwordless sudo' >&2
        exit 1
    }
    sudo -n true >/dev/null 2>&1 || {
        echo 'FAIL: this ownership regression requires passwordless sudo' >&2
        exit 1
    }
    exec sudo -n env "PATH=$PATH" bash "$SCRIPT_PATH"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
owner_of() { stat -c '%U:%G' "$1"; }

id nobody >/dev/null 2>&1 || fail "required fixture account 'nobody' is missing"

export KAGGLE_SYSTEM_DIR="$TMP/system"
export KAGGLE_DEV_DEFAULTS_FILE=/dev/null
export KAGGLE_DEV_CONFIG_FILE=/dev/null
export REDIS_VERSIONS=8.10.0
export REDIS_DEFAULT_VERSION=8.10.0
export REDIS_AUTO_START_VERSIONS=8.10.0
export REDIS_BUILD_JOBS=1
export REDIS_SERVICE_USER=nobody

# Source the real production installer. main() is guarded by BASH_SOURCE so no
# network/build/start work runs in this deterministic regression.
# shellcheck disable=SC1090
source "$ROOT/install/install-redis.sh"
REDIS_SERVICE_GROUP="$(id -gn "$REDIS_SERVICE_USER")"

INSTANCE="$KAGGLE_SYSTEM_DIR/redis/instances/8.10.0"
mkdir -p "$INSTANCE/data/appendonlydir" "$INSTANCE/logs" "$INSTANCE/run"
printf 'persisted log\n' > "$INSTANCE/logs/redis.log"
printf 'persisted aof\n' > "$INSTANCE/data/appendonlydir/appendonly.aof.1.incr.aof"
printf '# persisted user config\n' > "$INSTANCE/redis-user.conf"

# Model the exact cold-restore defect: the instance survived, but nested
# writable state is now root/stale-owned on the new VM.
chown -R root:root "$INSTANCE"
chmod 0644 \
    "$INSTANCE/logs/redis.log" \
    "$INSTANCE/data/appendonlydir/appendonly.aof.1.incr.aof" \
    "$INSTANCE/redis-user.conf"
chmod 0755 "$INSTANCE/data/appendonlydir"

write_instance_config 8.10.0 6379

EXPECTED="$REDIS_SERVICE_USER:$REDIS_SERVICE_GROUP"
for path in \
    "$INSTANCE/data" \
    "$INSTANCE/data/appendonlydir" \
    "$INSTANCE/data/appendonlydir/appendonly.aof.1.incr.aof" \
    "$INSTANCE/logs" \
    "$INSTANCE/logs/redis.log" \
    "$INSTANCE/run"; do
    actual="$(owner_of "$path")"
    [ "$actual" = "$EXPECTED" ] ||
        fail "$path owner=$actual, expected=$EXPECTED"
done

[ "$(owner_of "$INSTANCE")" = 'root:root' ] ||
    fail "instance root must remain root-owned"
for path in "$INSTANCE/redis.conf" "$INSTANCE/redis-user.conf" "$INSTANCE/port"; do
    actual="$(owner_of "$path")"
    [ "$actual" = 'root:root' ] ||
        fail "$path must remain root-owned; owner=$actual"
done

if find "$INSTANCE/data" "$INSTANCE/logs" "$INSTANCE/run" \
        -perm -0002 -print -quit | grep -q .; then
    fail 'Redis writable state became world-writable'
fi

printf '%s\n' \
  'PASS: Redis cold-restore writable state ownership is recursively repaired without transferring managed metadata'
