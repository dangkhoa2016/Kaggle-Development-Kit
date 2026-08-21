#!/usr/bin/env bash
set -euo pipefail

# Install/configure one or more exact Qdrant versions through a pinned
# Qdrant Native Portable (QNP) source checkout.
# Source cache: .system/qdrant/qnp/<qnp-release>-<commit12>/
# Instances:    .system/qdrant/instances/<qdrant-version>/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEM_DIR="${KAGGLE_SYSTEM_DIR:-$PROJECT_ROOT/.system}"
QDRANT_BASE="$SYSTEM_DIR/qdrant"
QNP_ROOT="$QDRANT_BASE/qnp"
INSTANCES_DIR="$QDRANT_BASE/instances"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/load-config.sh
source "$SCRIPT_DIR/lib/load-config.sh"
load_project_config "$PROJECT_ROOT"

QDRANT_VERSIONS="${QDRANT_VERSIONS:-1.18.3}"
QDRANT_DEFAULT_VERSION="${QDRANT_DEFAULT_VERSION:-${QDRANT_VERSIONS%% *}}"
QDRANT_AUTO_START_VERSIONS="${QDRANT_AUTO_START_VERSIONS-$QDRANT_DEFAULT_VERSION}"
QDRANT_ENABLE_GRPC="${QDRANT_ENABLE_GRPC:-0}"
QDRANT_PROFILE="${QDRANT_PROFILE:-auto}"
QDRANT_SERVICE_USER="${QDRANT_SERVICE_USER:-qdrantuser}"
QNP_RELEASE="${QNP_RELEASE:-1.0.0}"
QNP_SOURCE_COMMIT="${QNP_SOURCE_COMMIT:-464cb5dbc1117a8a8a6472d76a10c5e329021156}"
QNP_GIT_URL="${QNP_GIT_URL:-https://github.com/dangkhoa2016/Qdrant-Native-Portable.git}"
QNP_FORCE_SOURCE_REFRESH="${QNP_FORCE_SOURCE_REFRESH:-0}"

log() { printf '[install-qdrant] %s\n' "$*"; }
die() { common_die "$*"; }

init_privilege
require_command git
require_command python3

case "$QDRANT_ENABLE_GRPC" in 0|1) ;; *) die "QDRANT_ENABLE_GRPC chỉ nhận 0 hoặc 1." ;; esac
case "$QNP_FORCE_SOURCE_REFRESH" in 0|1) ;; *) die "QNP_FORCE_SOURCE_REFRESH chỉ nhận 0 hoặc 1." ;; esac
[[ "$QNP_RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "QNP_RELEASE phải là exact version X.Y.Z."
[[ "$QNP_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "QNP_SOURCE_COMMIT phải là full lowercase Git SHA 40 ký tự."

REQUESTED_VERSIONS=()
for version in $QDRANT_VERSIONS; do
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Qdrant version '$version' không hợp lệ; dùng exact release dạng X.Y.Z."
    if [[ " ${REQUESTED_VERSIONS[*]} " != *" $version "* ]]; then
        REQUESTED_VERSIONS+=("$version")
    fi
done
[ "${#REQUESTED_VERSIONS[@]}" -gt 0 ] || die "QDRANT_VERSIONS không được để trống."
list_contains "$QDRANT_DEFAULT_VERSION" "${REQUESTED_VERSIONS[*]}" \
    || die "QDRANT_DEFAULT_VERSION=$QDRANT_DEFAULT_VERSION phải nằm trong QDRANT_VERSIONS."
for version in $QDRANT_AUTO_START_VERSIONS; do
    list_contains "$version" "${REQUESTED_VERSIONS[*]}" \
        || die "QDRANT_AUTO_START_VERSIONS chứa '$version' nhưng version đó không có trong QDRANT_VERSIONS."
done

version_index() {
    local needle="$1" index=0 item
    for item in "${REQUESTED_VERSIONS[@]}"; do
        [ "$item" = "$needle" ] && { printf '%s\n' "$index"; return; }
        index=$((index + 1))
    done
    return 1
}

rest_port_for() {
    local version="$1" index fallback value
    index="$(version_index "$version")"
    fallback=$((6333 + index * 2))
    value="$(value_for_version QDRANT_PORT "$version" "$fallback")"
    validate_port "QDRANT_PORT_$(version_env_key "$version")" "$value"
    printf '%s\n' "$value"
}

grpc_port_for() {
    local version="$1" index fallback value
    index="$(version_index "$version")"
    fallback=$((6334 + index * 2))
    value="$(value_for_version QDRANT_GRPC_PORT "$version" "$fallback")"
    validate_port "QDRANT_GRPC_PORT_$(version_env_key "$version")" "$value"
    printf '%s\n' "$value"
}

# Fail closed on duplicate ports, including other explicitly configured local
# services loaded from defaults/.kaggle-dev.env.
declare -A PORT_OWNER=()
register_port() {
    local label="$1" port="$2"
    [ -n "$port" ] || return 0
    validate_port "$label" "$port"
    if [ -n "${PORT_OWNER[$port]:-}" ]; then
        die "Port $port bị trùng giữa ${PORT_OWNER[$port]} và $label. Hãy cấu hình port khác nhau."
    fi
    PORT_OWNER[$port]="$label"
}

register_other_service_ports() {
    local v key var value component
    for v in ${POSTGRES_VERSIONS:-}; do
        value="$(value_for_version POSTGRES_PORT "$v" "")"
        [ -z "$value" ] || register_port "PostgreSQL $v" "$value"
    done
    for v in ${REDIS_VERSIONS:-}; do
        value="$(value_for_version REDIS_PORT "$v" "")"
        [ -z "$value" ] || register_port "Redis $v" "$value"
    done
    for v in ${ELASTIC_VERSIONS:-}; do
        key="$(version_env_key "$v")"
        for component in ELASTICSEARCH KIBANA LOGSTASH_API LOGSTASH_INPUT; do
            var="ELASTIC_PORT_${key}_${component}"
            value="${!var:-}"
            [ -z "$value" ] || register_port "Elastic $v $component" "$value"
        done
    done
}

register_other_service_ports
for version in "${REQUESTED_VERSIONS[@]}"; do
    register_port "Qdrant $version REST" "$(rest_port_for "$version")"
    # Reserve the configured gRPC port even when gRPC is disabled so enabling it
    # later cannot silently collide with an already configured local service.
    register_port "Qdrant $version gRPC" "$(grpc_port_for "$version")"
done

QNP_SOURCE_NAME="${QNP_RELEASE}-${QNP_SOURCE_COMMIT:0:12}"
QNP_SOURCE="$QNP_ROOT/$QNP_SOURCE_NAME"

source_checkout_valid() {
    [ -d "$QNP_SOURCE/.git" ] || return 1
    [ -f "$QNP_SOURCE/VERSION" ] || return 1
    [ "$(tr -d '[:space:]' < "$QNP_SOURCE/VERSION")" = "$QNP_RELEASE" ] || return 1
    [ "$(git -C "$QNP_SOURCE" rev-parse HEAD 2>/dev/null || true)" = "$QNP_SOURCE_COMMIT" ] || return 1
    git -C "$QNP_SOURCE" diff --quiet -- 2>/dev/null || return 1
    git -C "$QNP_SOURCE" diff --cached --quiet -- 2>/dev/null || return 1
    [ -f "$QNP_SOURCE/.qnp-source-meta" ] || return 1
    grep -qx "release=$QNP_RELEASE" "$QNP_SOURCE/.qnp-source-meta" || return 1
    grep -qx "commit=$QNP_SOURCE_COMMIT" "$QNP_SOURCE/.qnp-source-meta" || return 1
}

ensure_qnp_source() {
    local stage actual_release actual_commit
    mkdir -p "$SYSTEM_DIR" "$QDRANT_BASE" "$QNP_ROOT" "$INSTANCES_DIR"
    chmod 755 "$SYSTEM_DIR" "$QDRANT_BASE" "$QNP_ROOT" "$INSTANCES_DIR"

    if [ "$QNP_FORCE_SOURCE_REFRESH" != "1" ] && source_checkout_valid; then
        log "QNP $QNP_RELEASE ($QNP_SOURCE_COMMIT) đã được cache; tái sử dụng."
        return 0
    fi

    stage="$(make_project_staging_dir "$SYSTEM_DIR" "qnp-$QNP_RELEASE")"
    trap 'rm -rf "${stage:-}"' RETURN
    log "Fetch QNP $QNP_RELEASE pinned commit $QNP_SOURCE_COMMIT"
    git init -q "$stage"
    git -C "$stage" remote add origin "$QNP_GIT_URL"
    git -C "$stage" fetch -q --depth 1 origin "$QNP_SOURCE_COMMIT"
    git -C "$stage" checkout -q --detach FETCH_HEAD

    actual_commit="$(git -C "$stage" rev-parse HEAD)"
    [ "$actual_commit" = "$QNP_SOURCE_COMMIT" ] \
        || die "QNP source commit không khớp: expected=$QNP_SOURCE_COMMIT actual=$actual_commit"
    [ -f "$stage/VERSION" ] || die "QNP source thiếu VERSION."
    actual_release="$(tr -d '[:space:]' < "$stage/VERSION")"
    [ "$actual_release" = "$QNP_RELEASE" ] \
        || die "QNP VERSION/release không khớp: expected=$QNP_RELEASE actual=$actual_release"
    [ -x "$stage/qdrant.sh" ] || die "QNP source thiếu executable qdrant.sh."
    for script in 01_credentials.sh 02_setup_env.sh 03_download_qdrant.sh 04_configure_qdrant.sh; do
        [ -x "$stage/scripts/$script" ] || die "QNP source thiếu scripts/$script"
    done

    if [ -f "$stage/SOURCE-MANIFEST.json" ] && [ -x "$stage/scripts/source-integrity.py" ]; then
        log "Xác minh source integrity của QNP trước khi activate..."
        python3 "$stage/scripts/source-integrity.py" check \
            --root "$stage" --manifest "$stage/SOURCE-MANIFEST.json" --require-clean
    fi

    cat > "$stage/.qnp-source-meta" <<META
release=$QNP_RELEASE
commit=$QNP_SOURCE_COMMIT
origin=$QNP_GIT_URL
META
    chmod 444 "$stage/.qnp-source-meta"
    # QNP writes .qdrant-base only when its source root is writable. Keep the
    # pinned shared source immutable so multiple instances cannot overwrite it.
    chmod -R a-w "$stage"

    # Restore parent write bits on .git directories is not necessary for runtime;
    # the cache is deliberately immutable until a forced atomic refresh.
    if [ -e "$QNP_SOURCE" ]; then
        chmod -R u+w "$QNP_SOURCE" 2>/dev/null || true
    fi
    atomic_replace_directory "$stage" "$QNP_SOURCE"
    trap - RETURN
    log "QNP source activated: $QNP_SOURCE"
}

instance_dir_for() { printf '%s/%s\n' "$INSTANCES_DIR" "$1"; }

qnp_env_run() {
    local version="$1" script="$2" base rest grpc
    base="$(instance_dir_for "$version")"
    rest="$(rest_port_for "$version")"
    grpc="$(grpc_port_for "$version")"
    env \
        BASE_DIR="$base" \
        QNP_ENV=development \
        QNP_RUNTIME=native \
        QNP_TOPOLOGY=single \
        QNP_CREATE_DEMO_DATA=0 \
        QNP_SECRET_POLICY=generate \
        QNP_KAGGLE_PERSISTENCE=variables-and-files \
        PROCESS_MODE=service-user \
        DEPLOYMENT_MODE=minimal \
        PUBLIC_MODE=none \
        START_TUNNEL=0 \
        QDRANT_BIND_HOST=127.0.0.1 \
        QDRANT_VERSION="$version" \
        QDRANT_PROFILE="$QDRANT_PROFILE" \
        QDRANT_HTTP_PORT="$rest" \
        QDRANT_GRPC_PORT="$grpc" \
        QDRANT_ENABLE_GRPC="$QDRANT_ENABLE_GRPC" \
        QDRANT_USER="$QDRANT_SERVICE_USER" \
        bash "$QNP_SOURCE/scripts/$script"
}

write_instance_metadata() {
    local version="$1" base
    base="$(instance_dir_for "$version")"
    mkdir -p "$base"
    printf '%s\n' "$version" > "$base/kdev-version"
    printf '%s\n' "$(rest_port_for "$version")" > "$base/kdev-rest-port"
    printf '%s\n' "$(grpc_port_for "$version")" > "$base/kdev-grpc-port"
    printf '%s\n' "$QDRANT_ENABLE_GRPC" > "$base/kdev-grpc-enabled"
    printf '%s\n' "$QDRANT_PROFILE" > "$base/kdev-profile-requested"
    chmod 644 "$base"/kdev-*
}

configure_instance() {
    local version="$1"
    write_instance_metadata "$version"
    log "Chuẩn bị Qdrant $version (REST $(rest_port_for "$version"), gRPC $(grpc_port_for "$version"), enabled=$QDRANT_ENABLE_GRPC)..."
    qnp_env_run "$version" 01_credentials.sh
    qnp_env_run "$version" 02_setup_env.sh
    qnp_env_run "$version" 03_download_qdrant.sh
    qnp_env_run "$version" 04_configure_qdrant.sh
}

write_service_helper() {
    printf '%s\n' "$QDRANT_DEFAULT_VERSION" > "$QDRANT_BASE/default-version"
    printf '%s\n' "$QNP_SOURCE_NAME" > "$QDRANT_BASE/qnp-source-name"
    printf '%s\n' "$QDRANT_SERVICE_USER" > "$QDRANT_BASE/service-user"
    chmod 644 "$QDRANT_BASE/default-version" "$QDRANT_BASE/qnp-source-name" "$QDRANT_BASE/service-user"

    cat > "$SYSTEM_DIR/qdrant-service.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
SYSTEM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QDRANT_BASE="$SYSTEM_DIR/qdrant"
DEFAULT_VERSION="$(cat "$QDRANT_BASE/default-version" 2>/dev/null || true)"
SOURCE_NAME="$(cat "$QDRANT_BASE/qnp-source-name" 2>/dev/null || true)"
SERVICE_USER="$(cat "$QDRANT_BASE/service-user" 2>/dev/null || echo qdrantuser)"
SOURCE="$QDRANT_BASE/qnp/$SOURCE_NAME"
usage() {
  echo "Usage: $0 [version] {start|stop|restart|status|health|url|logs [tail args...]|version}" >&2
}
first="${1:-}"
case "$first" in start|stop|restart|status|health|url|logs|version|'') VERSION="$DEFAULT_VERSION" ;; *) VERSION="$first"; shift ;; esac
[ -n "$VERSION" ] || { echo "No Qdrant default version configured." >&2; exit 2; }
ACTION="${1:-status}"; [ "$#" -eq 0 ] || shift
INSTANCE="$QDRANT_BASE/instances/$VERSION"
REST_PORT="$(cat "$INSTANCE/kdev-rest-port" 2>/dev/null || true)"
GRPC_PORT="$(cat "$INSTANCE/kdev-grpc-port" 2>/dev/null || true)"
GRPC_ENABLED="$(cat "$INSTANCE/kdev-grpc-enabled" 2>/dev/null || echo 0)"
PROFILE="$(cat "$INSTANCE/kdev-profile-requested" 2>/dev/null || echo auto)"
BIN="$INSTANCE/qdrant-$VERSION/qdrant"
[ -d "$SOURCE" ] && [ -x "$SOURCE/qdrant.sh" ] || { echo "Pinned QNP source is missing: $SOURCE" >&2; exit 1; }
[ -d "$INSTANCE" ] && [ -n "$REST_PORT" ] || { echo "Qdrant $VERSION is not installed/configured." >&2; exit 1; }
qnp() {
  env \
    BASE_DIR="$INSTANCE" \
    QNP_ENV=development \
    QNP_RUNTIME=native \
    QNP_TOPOLOGY=single \
    QNP_CREATE_DEMO_DATA=0 \
    QNP_SECRET_POLICY=generate \
    QNP_KAGGLE_PERSISTENCE=variables-and-files \
    PROCESS_MODE=service-user \
    DEPLOYMENT_MODE=minimal \
    PUBLIC_MODE=none \
    START_TUNNEL=0 \
    QDRANT_BIND_HOST=127.0.0.1 \
    QDRANT_VERSION="$VERSION" \
    QDRANT_PROFILE="$PROFILE" \
    QDRANT_HTTP_PORT="$REST_PORT" \
    QDRANT_GRPC_PORT="$GRPC_PORT" \
    QDRANT_ENABLE_GRPC="$GRPC_ENABLED" \
    QDRANT_USER="$SERVICE_USER" \
    bash "$SOURCE/qdrant.sh" "$@"
}
case "$ACTION" in
  start|stop|restart|status|health) qnp "$ACTION" "$@" ;;
  url) printf 'http://127.0.0.1:%s\n' "$REST_PORT" ;;
  logs)
    LOG="$INSTANCE/logs/qdrant.log"
    [ -f "$LOG" ] || { echo "Qdrant log not found: $LOG" >&2; exit 1; }
    if [ "$#" -eq 0 ]; then exec tail -n 100 "$LOG"; else exec tail "$@" "$LOG"; fi
    ;;
  version)
    [ -x "$BIN" ] || { echo "Qdrant binary not found: $BIN" >&2; exit 1; }
    exec "$BIN" --version
    ;;
  *) usage; exit 2 ;;
esac
HELPER
    chmod 755 "$SYSTEM_DIR/qdrant-service.sh"
}

ensure_service_mode_dependency() {
    if command -v setpriv >/dev/null 2>&1; then return 0; fi
    log "QNP service-user mode cần setpriv; cài util-linux..."
    run_root apt-get update -qq
    run_root apt-get install -y -qq --no-install-recommends util-linux
    require_command setpriv
}

main() {
    local version
    ensure_qnp_source
    ensure_service_mode_dependency

    for version in "${REQUESTED_VERSIONS[@]}"; do
        configure_instance "$version"
    done
    write_service_helper

    for version in "${REQUESTED_VERSIONS[@]}"; do
        if list_contains "$version" "$QDRANT_AUTO_START_VERSIONS"; then
            log "Auto-start Qdrant $version..."
            bash "$SYSTEM_DIR/qdrant-service.sh" "$version" start
            bash "$SYSTEM_DIR/qdrant-service.sh" "$version" health
        elif [ -f "$(instance_dir_for "$version")/run/qdrant.pid" ]; then
            log "Qdrant $version không nằm trong auto-start; dừng instance đang chạy."
            bash "$SYSTEM_DIR/qdrant-service.sh" "$version" stop || true
        fi
    done

    ensure_system_scripts_executable "$SYSTEM_DIR"
    echo
    echo "================================================================="
    echo "✅ CÀI ĐẶT QDRANT THÀNH CÔNG"
    echo "================================================================="
    echo "  QNP release: $QNP_RELEASE"
    echo "  QNP commit : $QNP_SOURCE_COMMIT"
    for version in "${REQUESTED_VERSIONS[@]}"; do
        echo "  Qdrant $version: http://127.0.0.1:$(rest_port_for "$version")"
        echo "    Status : bash $SYSTEM_DIR/qdrant-service.sh $version status"
        echo "    Health : bash $SYSTEM_DIR/qdrant-service.sh $version health"
    done
    echo "  Default: $QDRANT_DEFAULT_VERSION"
    echo "================================================================="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
