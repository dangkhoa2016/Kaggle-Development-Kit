#!/usr/bin/env bash
set -euo pipefail

# Install one or more exact Redis releases side-by-side from official source tarballs.
# Runtime:   .system/redis/versions/<version>/bin
# Instance:  .system/redis/instances/<version>/{data,logs,run,redis.conf}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEM_DIR="${KAGGLE_SYSTEM_DIR:-$PROJECT_ROOT/.system}"
BASE_DIR="$SYSTEM_DIR/redis"
VERSIONS_DIR="$BASE_DIR/versions"
INSTANCES_DIR="$BASE_DIR/instances"
COMMON="$SCRIPT_DIR/lib/common.sh"

# shellcheck source=lib/common.sh
source "$COMMON"
# shellcheck source=lib/load-config.sh
source "$SCRIPT_DIR/lib/load-config.sh"
load_project_config "$PROJECT_ROOT"

REDIS_VERSIONS="${REDIS_VERSIONS:-8.10.0}"
REDIS_DEFAULT_VERSION="${REDIS_DEFAULT_VERSION:-${REDIS_VERSIONS%% *}}"
REDIS_AUTO_START_VERSIONS="${REDIS_AUTO_START_VERSIONS:-$REDIS_DEFAULT_VERSION}"
REDIS_SERVICE_USER="${REDIS_SERVICE_USER:-redis}"
REDIS_SERVICE_GROUP="$REDIS_SERVICE_USER"
REDIS_FORCE_RUNTIME_REFRESH="${REDIS_FORCE_RUNTIME_REFRESH:-0}"
REDIS_BUILD_JOBS="${REDIS_BUILD_JOBS:-2}"
REDIS_DOWNLOAD_BASE_URL="${REDIS_DOWNLOAD_BASE_URL:-https://download.redis.io/releases}"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL="${LC_ALL:-C.UTF-8}"

log() { printf '[install-redis] %s\n' "$*"; }
die() { common_die "$*"; }

init_privilege
require_command curl
require_command tar
require_command sha256sum

case "$REDIS_FORCE_RUNTIME_REFRESH" in 0|1) ;; *) die "REDIS_FORCE_RUNTIME_REFRESH must be either 0 or 1." ;; esac
case "$REDIS_BUILD_JOBS" in ''|*[!0-9]*) die "REDIS_BUILD_JOBS must be a positive integer." ;; esac
[ "$REDIS_BUILD_JOBS" -ge 1 ] || die "REDIS_BUILD_JOBS must be >= 1."

REQUESTED_VERSIONS=()
for version in $REDIS_VERSIONS; do
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Redis version '$version' is invalid; use an exact X.Y.Z release."
    if [[ " ${REQUESTED_VERSIONS[*]} " != *" $version "* ]]; then
        REQUESTED_VERSIONS+=("$version")
    fi
done
[ "${#REQUESTED_VERSIONS[@]}" -gt 0 ] || die "REDIS_VERSIONS must not be empty."
list_contains "$REDIS_DEFAULT_VERSION" "${REQUESTED_VERSIONS[*]}" \
    || die "REDIS_DEFAULT_VERSION=$REDIS_DEFAULT_VERSION must be included in REDIS_VERSIONS."
for version in $REDIS_AUTO_START_VERSIONS; do
    list_contains "$version" "${REQUESTED_VERSIONS[*]}" \
        || die "REDIS_AUTO_START_VERSIONS contains '$version', which is not present in REDIS_VERSIONS."
done

port_for() {
    local version="$1" fallback value index=0 item
    # Deterministic fallback by position. The notebook normally writes explicit
    # per-version ports, so this mainly helps direct CLI/manual configuration.
    for item in "${REQUESTED_VERSIONS[@]}"; do
        [ "$item" = "$version" ] && break
        index=$((index + 1))
    done
    fallback="$((6379 + index))"
    if [ "$version" = "$REDIS_DEFAULT_VERSION" ] && [ -n "${REDIS_PORT:-}" ]; then
        fallback="$REDIS_PORT"
    fi
    value="$(value_for_version REDIS_PORT "$version" "$fallback")"
    validate_port "REDIS_PORT_$(version_env_key "$version")" "$value"
    printf '%s\n' "$value"
}

PORT_PAIRS=""
for version in "${REQUESTED_VERSIONS[@]}"; do
    PORT_PAIRS+=" $version=$(port_for "$version")"
done
validate_unique_ports "Redis" "$PORT_PAIRS"

ensure_build_dependencies() {
    log "Ensuring Redis source build dependencies are available..."
    run_root apt-get update -y
    run_root apt-get install -y --no-install-recommends build-essential ca-certificates curl tar
}

runtime_dir_for() { printf '%s/%s\n' "$VERSIONS_DIR" "$1"; }
instance_dir_for() { printf '%s/%s\n' "$INSTANCES_DIR" "$1"; }

installed_version() {
    local version="$1" runtime
    runtime="$(runtime_dir_for "$version")"
    [ -x "$runtime/bin/redis-server" ] || return 1
    "$runtime/bin/redis-server" --version 2>/dev/null | sed -n 's/.* v=\([^ ]*\).*/\1/p' | head -1
}

runtime_requires_build() {
    local version="$1" current

    [ "$REDIS_FORCE_RUNTIME_REFRESH" = "1" ] && return 0
    current="$(installed_version "$version" 2>/dev/null || true)"
    [ "$current" != "$version" ]
}

expected_sha256() {
    local version="$1" key variable
    key="$(version_env_key "$version")"
    variable="REDIS_SHA256_${key}"
    printf '%s\n' "${!variable:-}"
}

install_version() {
    local version="$1" runtime stage archive src extracted checksum expected url
    runtime="$(runtime_dir_for "$version")"
    if ! runtime_requires_build "$version"; then
        log "Redis $version already exists at $runtime; skipping build."
        return
    fi

    stage="$(make_project_staging_dir "$SYSTEM_DIR" "redis-$version")"
    archive="$stage/redis-$version.tar.gz"
    src="$stage/src"
    mkdir -p "$src"
    url="$REDIS_DOWNLOAD_BASE_URL/redis-$version.tar.gz"
    trap 'run_root rm -rf "$stage"' RETURN

    log "Downloading Redis $version from $url"
    curl -fL --retry 3 --connect-timeout 20 "$url" -o "$archive"
    checksum="$(sha256sum "$archive" | awk '{print $1}')"
    expected="$(expected_sha256 "$version")"
    if [ -n "$expected" ] && [ "$checksum" != "$expected" ]; then
        die "Redis $version SHA256 mismatch: expected=$expected actual=$checksum"
    fi

    tar -xzf "$archive" -C "$src" --strip-components=1
    log "Build Redis core $version (MALLOC=libc, jobs=$REDIS_BUILD_JOBS)..."
    # Redis 8.10+ release sources can include bundled modules; plain `make` may
    # therefore require Rust/LLVM/CMake. For this lightweight dev bootstrap we
    # intentionally build Redis core only on 8.10+, following upstream's
    # documented `make build redis` target. Older releases use their classic
    # core build path.
    major="${version%%.*}"
    rest="${version#*.}"; minor="${rest%%.*}"
    if [ "$major" -gt 8 ] || { [ "$major" -eq 8 ] && [ "$minor" -ge 10 ]; }; then
        make -C "$src" -j"$REDIS_BUILD_JOBS" MALLOC=libc BUILD_TLS=no build redis
    else
        make -C "$src" -j"$REDIS_BUILD_JOBS" MALLOC=libc BUILD_TLS=no
    fi
    # redis-cli is required by the generated service helper. Build it explicitly
    # as a compatibility fallback if an upstream target did not produce it.
    if [ ! -x "$src/src/redis-cli" ]; then
        make -C "$src/src" -j"$REDIS_BUILD_JOBS" MALLOC=libc BUILD_TLS=no redis-cli
    fi

    extracted="$stage/runtime"
    mkdir -p "$extracted/bin"
    for bin in redis-server redis-cli; do
        [ -x "$src/src/$bin" ] || die "Redis $version build is missing $bin."
        install -m 755 "$src/src/$bin" "$extracted/bin/$bin"
    done
    # Optional diagnostics are copied when upstream produced them.
    for bin in redis-benchmark redis-check-aof redis-check-rdb; do
        [ ! -e "$src/src/$bin" ] || install -m 755 "$src/src/$bin" "$extracted/bin/$bin"
    done
    cat > "$extracted/BUILD-INFO.txt" <<INFO
version=$version
source_url=$url
source_sha256=$checksum
build_malloc=libc
build_tls=no
build_scope=core
INFO
    chmod 644 "$extracted/BUILD-INFO.txt"

    current="$($extracted/bin/redis-server --version | sed -n 's/.* v=\([^ ]*\).*/\1/p' | head -1)"
    [ "$current" = "$version" ] || die "Redis build returned version '$current', expected '$version'."

    mkdir -p "$VERSIONS_DIR"
    atomic_replace_directory "$extracted" "$runtime"
    run_root chown -R root:root "$runtime"
    run_root chmod -R a+rX "$runtime"
    run_root rm -rf "$stage"
    trap - RETURN
    log "Installed Redis $version at $runtime"
}

redis_config_quote() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

repair_instance_ownership() {
    local instance="$1" area

    for area in data logs run; do
        [ -d "$instance/$area" ] || continue
        run_root chown -R             "$REDIS_SERVICE_USER:$REDIS_SERVICE_GROUP"             "$instance/$area"
    done
}

write_instance_config() {
    local version="$1" port="$2" instance data logs run config user_config tmp
    local user_q pid_q log_q data_q
    instance="$(instance_dir_for "$version")"
    data="$instance/data"; logs="$instance/logs"; run="$instance/run"
    config="$instance/redis.conf"; user_config="$instance/redis-user.conf"

    run_root install -d -o "$REDIS_SERVICE_USER" -g "$REDIS_SERVICE_GROUP" -m 750 "$data"
    run_root install -d -o "$REDIS_SERVICE_USER" -g "$REDIS_SERVICE_GROUP" -m 755 "$logs" "$run"
    # A persisted instance can outlive the VM account/UID that previously owned
    # nested log/AOF/PID state. Repair only writable service state; managed
    # config/metadata at the instance root intentionally stays root-owned.
    repair_instance_ownership "$instance"
    if [ ! -f "$user_config" ]; then
        cat > "$user_config" <<'USERCONF'
# Optional user settings for this exact Redis version.
# Managed safety/path/port settings below are applied after this include.
USERCONF
        chmod 644 "$user_config"
    fi

    user_q="$(redis_config_quote "$user_config")"
    pid_q="$(redis_config_quote "$run/redis.pid")"
    log_q="$(redis_config_quote "$logs/redis.log")"
    data_q="$(redis_config_quote "$data")"
    tmp="$(mktemp)"
    cat > "$tmp" <<CFG
# Generated by install-redis.sh for Redis $version.
include "$user_q"
bind 127.0.0.1
protected-mode yes
port $port
supervised no
daemonize yes
pidfile "$pid_q"
logfile "$log_q"
dir "$data_q"
dbfilename dump.rdb
appendonly yes
appendfsync everysec
save 900 1
save 300 10
save 60 10000
CFG
    run_root install -o root -g root -m 644 "$tmp" "$config"
    rm -f "$tmp"
    printf '%s\n' "$port" > "$instance/port"
    chmod 644 "$instance/port"
}

write_service_helper() {
    rm -f "$SYSTEM_DIR/redis-service.sh"
    cat > "$SYSTEM_DIR/redis-service.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
SYSTEM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SYSTEM_DIR/redis"
SERVICE_USER="redis"
DEFAULT_VERSION="$(cat "$BASE_DIR/default-version" 2>/dev/null || true)"
usage() { echo "Usage: $0 [version] {start|stop|status|cli [redis-cli args...]}" >&2; }
first="${1:-}"
case "$first" in start|stop|status|cli|'') VERSION="$DEFAULT_VERSION" ;; *) VERSION="$first"; shift ;; esac
[ -n "$VERSION" ] || { echo "No Redis default version configured." >&2; exit 2; }
ACTION="${1:-cli}"; [ "$#" -eq 0 ] || shift
RUNTIME="$BASE_DIR/versions/$VERSION"
INSTANCE="$BASE_DIR/instances/$VERSION"
SERVER="$RUNTIME/bin/redis-server"; CLI="$RUNTIME/bin/redis-cli"
CONFIG="$INSTANCE/redis.conf"; PIDFILE="$INSTANCE/run/redis.pid"; PORT="$(cat "$INSTANCE/port" 2>/dev/null || true)"
[ -x "$SERVER" ] && [ -x "$CLI" ] && [ -f "$CONFIG" ] && [ -n "$PORT" ] || { echo "Redis $VERSION is not installed/configured." >&2; exit 1; }
run_as_service() {
    if [ "$(id -un)" = "$SERVICE_USER" ]; then "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        if command -v runuser >/dev/null 2>&1; then runuser -u "$SERVICE_USER" -- "$@"
        else quoted=""; printf -v quoted '%q ' "$@"; su -s /bin/bash "$SERVICE_USER" -c "$quoted"; fi
    elif command -v sudo >/dev/null 2>&1; then sudo -u "$SERVICE_USER" -- "$@"
    else echo "Need root/sudo to control Redis." >&2; exit 1; fi
}
pid_from_file() { local p; p="$(run_as_service sh -c 'test -f "$1" && cat "$1" || true' _ "$PIDFILE")"; [[ "$p" =~ ^[0-9]+$ ]] || return 1; printf '%s\n' "$p"; }
pid_from_port() { "$CLI" -h 127.0.0.1 -p "$PORT" --raw INFO server 2>/dev/null | awk -F: '/^process_id:/ {gsub("\r","",$2); print $2; exit}'; }
own_alive() { local fp pp; fp="$(pid_from_file 2>/dev/null || true)"; [ -n "$fp" ] || return 1; run_as_service kill -0 "$fp" 2>/dev/null || return 1; pp="$(pid_from_port || true)"; [ "$fp" = "$pp" ]; }
start_server() {
    own_alive && return 0
    local foreign stale
    foreign="$(pid_from_port || true)"; [ -z "$foreign" ] || { echo "Port $PORT is already used by Redis PID $foreign." >&2; exit 1; }
    stale="$(pid_from_file 2>/dev/null || true)"
    if [ -n "$stale" ] && run_as_service kill -0 "$stale" 2>/dev/null; then echo "Live stale PID $stale; refusing to overwrite." >&2; exit 1; fi
    run_as_service rm -f "$PIDFILE"
    run_as_service "$SERVER" "$CONFIG"
    for _ in 1 2 3 4 5 6 7 8 9 10; do own_alive && return 0; sleep 0.5; done
    echo "Redis $VERSION failed to start; see $INSTANCE/logs/redis.log" >&2; exit 1
}
stop_server() {
    if own_alive; then
        "$CLI" -h 127.0.0.1 -p "$PORT" shutdown save >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do own_alive || return 0; sleep 0.5; done
        local fp; fp="$(pid_from_file 2>/dev/null || true)"; [ -z "$fp" ] || run_as_service kill -TERM "$fp"
    else echo "Redis $VERSION is not running."; fi
}
case "$ACTION" in
    start) start_server ;;
    stop) stop_server ;;
    status) if own_alive; then echo "Redis $VERSION running on port $PORT."; else echo "Redis $VERSION not running."; exit 1; fi ;;
    cli) start_server; exec "$CLI" -h 127.0.0.1 -p "$PORT" "$@" ;;
    *) usage; exit 2 ;;
esac
HELPER
    # Replace the service account in a controlled literal line.
    sed -i "s/^SERVICE_USER=\"redis\"$/SERVICE_USER=\"$REDIS_SERVICE_USER\"/" "$SYSTEM_DIR/redis-service.sh"
    chmod 755 "$SYSTEM_DIR/redis-service.sh"

    rm -f "$SYSTEM_DIR/run-redis.sh"

    cat > "$SYSTEM_DIR/run-redis.sh" <<'EOF_RUN'
#!/usr/bin/env bash
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/redis-service.sh" cli "$@"
EOF_RUN
    rm -f "$SYSTEM_DIR/start-redis.sh"
    cat > "$SYSTEM_DIR/start-redis.sh" <<'EOF_START'
#!/usr/bin/env bash
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/redis-service.sh" start "$@"
EOF_START
    rm -f "$SYSTEM_DIR/stop-redis.sh"
    cat > "$SYSTEM_DIR/stop-redis.sh" <<'EOF_STOP'
#!/usr/bin/env bash
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/redis-service.sh" stop "$@"
EOF_STOP
    chmod 755 "$SYSTEM_DIR/run-redis.sh" "$SYSTEM_DIR/start-redis.sh" "$SYSTEM_DIR/stop-redis.sh"
}

main() {
    local version port result detected
    run_root mkdir -p "$SYSTEM_DIR" "$BASE_DIR" "$VERSIONS_DIR" "$INSTANCES_DIR"
    run_root chown "$(id -u):$(id -g)" "$SYSTEM_DIR" "$BASE_DIR" "$VERSIONS_DIR" "$INSTANCES_DIR"
    run_root chmod 755 "$SYSTEM_DIR" "$BASE_DIR" "$VERSIONS_DIR" "$INSTANCES_DIR"
    ensure_system_user "$REDIS_SERVICE_USER" "$BASE_DIR"
    REDIS_SERVICE_GROUP="$(id -gn "$REDIS_SERVICE_USER")"
    for version in "${REQUESTED_VERSIONS[@]}"; do
        if runtime_requires_build "$version"; then
            ensure_build_dependencies
            break
        fi
    done

    for version in "${REQUESTED_VERSIONS[@]}"; do
        install_version "$version"
        port="$(port_for "$version")"
        write_instance_config "$version" "$port"
    done
    printf '%s\n' "$REDIS_DEFAULT_VERSION" > "$BASE_DIR/default-version"
    chmod 644 "$BASE_DIR/default-version"
    write_service_helper

    for version in "${REQUESTED_VERSIONS[@]}"; do
        log "Starting Redis $version temporarily for validation..."
        bash "$SYSTEM_DIR/redis-service.sh" "$version" start
        detected="$(bash "$SYSTEM_DIR/redis-service.sh" "$version" cli --raw INFO server | awk -F: '/^redis_version:/ {gsub("\r","",$2); print $2; exit}')"
        [ "$detected" = "$version" ] || die "Redis instance returned version $detected, expected $version."
        bash "$SYSTEM_DIR/redis-service.sh" "$version" cli SET installer_test ok >/dev/null
        result="$(bash "$SYSTEM_DIR/redis-service.sh" "$version" cli GET installer_test)"
        bash "$SYSTEM_DIR/redis-service.sh" "$version" cli DEL installer_test >/dev/null
        [ "$result" = "ok" ] || die "Redis $version SET/GET test failed."
        printf '    ✅ Redis %s: redis://127.0.0.1:%s\n' "$version" "$(port_for "$version")"
        if ! list_contains "$version" "$REDIS_AUTO_START_VERSIONS"; then
            bash "$SYSTEM_DIR/redis-service.sh" "$version" stop
        fi
    done

    ensure_system_scripts_executable "$SYSTEM_DIR"
    echo
    echo "================================================================="
    echo "✅ REDIS INSTALLATION COMPLETED SUCCESSFULLY"
    echo "================================================================="
    for version in "${REQUESTED_VERSIONS[@]}"; do
        echo "  Redis $version: redis://127.0.0.1:$(port_for "$version")"
        echo "    CLI   : bash $SYSTEM_DIR/redis-service.sh $version cli PING"
        echo "    Start : bash $SYSTEM_DIR/redis-service.sh $version start"
        echo "    Stop  : bash $SYSTEM_DIR/redis-service.sh $version stop"
    done
    echo "  Default: $REDIS_DEFAULT_VERSION"
    echo "================================================================="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
