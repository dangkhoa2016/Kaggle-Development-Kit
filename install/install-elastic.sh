#!/usr/bin/env bash
set -euo pipefail

# Install multiple exact Elastic Stack versions side-by-side.
# Each version has an isolated runtime/config/data/log/run tree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEM_DIR="$PROJECT_ROOT/.system"
BASE_DIR="$SYSTEM_DIR/elastic"
VERSIONS_DIR="$BASE_DIR/versions"
COMMON="$SCRIPT_DIR/lib/common.sh"

source "$COMMON"
# shellcheck source=lib/load-config.sh
source "$SCRIPT_DIR/lib/load-config.sh"
load_project_config "$PROJECT_ROOT"

ELASTIC_VERSIONS="${ELASTIC_VERSIONS:-9.5.0}"
ELASTIC_DEFAULT_VERSION="${ELASTIC_DEFAULT_VERSION:-${ELASTIC_VERSIONS%% *}}"
ELASTIC_COMPONENTS="${ELASTIC_COMPONENTS:-elasticsearch kibana logstash}"
ELASTIC_AUTO_START_VERSIONS="${ELASTIC_AUTO_START_VERSIONS:-}"
ELASTIC_HEAP_SIZE="${ELASTIC_HEAP_SIZE:-512m}"
ELASTIC_SERVICE_USER="${ELASTIC_SERVICE_USER:-elastic}"
ELASTIC_SERVICE_GROUP="$ELASTIC_SERVICE_USER"
ELASTIC_FORCE_RUNTIME_REFRESH="${ELASTIC_FORCE_RUNTIME_REFRESH:-0}"
ELASTIC_ARTIFACT_BASE_URL="${ELASTIC_ARTIFACT_BASE_URL:-https://artifacts.elastic.co/downloads}"

log() { printf '[install-elastic] %s\n' "$*"; }
die() { common_die "$*"; }

init_privilege
require_command curl
require_command tar
require_command sha512sum
case "$ELASTIC_FORCE_RUNTIME_REFRESH" in 0|1) ;; *) die "ELASTIC_FORCE_RUNTIME_REFRESH chỉ nhận 0 hoặc 1." ;; esac
[[ "$ELASTIC_HEAP_SIZE" =~ ^[0-9]+[mMgG]$ ]] || die "ELASTIC_HEAP_SIZE phải dạng 512m, 1g..."

REQUESTED_VERSIONS=()
for version in $ELASTIC_VERSIONS; do
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Elastic version '$version' không hợp lệ; dùng exact X.Y.Z."
    [[ " ${REQUESTED_VERSIONS[*]} " == *" $version "* ]] || REQUESTED_VERSIONS+=("$version")
done
[ "${#REQUESTED_VERSIONS[@]}" -gt 0 ] || die "ELASTIC_VERSIONS không được để trống."
list_contains "$ELASTIC_DEFAULT_VERSION" "${REQUESTED_VERSIONS[*]}" || die "ELASTIC_DEFAULT_VERSION phải nằm trong ELASTIC_VERSIONS."
for version in $ELASTIC_AUTO_START_VERSIONS; do
    list_contains "$version" "${REQUESTED_VERSIONS[*]}" || die "ELASTIC_AUTO_START_VERSIONS chứa '$version' không có trong ELASTIC_VERSIONS."
done

COMPONENTS=()
for component in $ELASTIC_COMPONENTS; do
    case "$component" in elasticsearch|kibana|logstash) ;; *) die "Elastic component không hỗ trợ: $component" ;; esac
    [[ " ${COMPONENTS[*]} " == *" $component "* ]] || COMPONENTS+=("$component")
done
[ "${#COMPONENTS[@]}" -gt 0 ] || die "ELASTIC_COMPONENTS không được để trống."

elastic_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64\n' ;;
        aarch64|arm64) printf 'aarch64\n' ;;
        *) die "CPU architecture không hỗ trợ: $(uname -m)" ;;
    esac
}

port_for() {
    local version="$1" component="$2" key variable fallback value
    key="$(version_env_key "$version")"
    case "$component" in
        elasticsearch) variable="ELASTIC_PORT_${key}_ELASTICSEARCH"; fallback=9200 ;;
        kibana) variable="ELASTIC_PORT_${key}_KIBANA"; fallback=5601 ;;
        logstash-api) variable="ELASTIC_PORT_${key}_LOGSTASH_API"; fallback=9600 ;;
        logstash-input) variable="ELASTIC_PORT_${key}_LOGSTASH_INPUT"; fallback=5044 ;;
        *) die "Unknown Elastic port component: $component" ;;
    esac
    value="${!variable:-$fallback}"
    validate_port "$variable" "$value"
    printf '%s\n' "$value"
}

ALL_PORT_PAIRS=""
for version in "${REQUESTED_VERSIONS[@]}"; do
    for component in "${COMPONENTS[@]}"; do
        case "$component" in
            elasticsearch) ALL_PORT_PAIRS+=" es-$version=$(port_for "$version" elasticsearch)" ;;
            kibana) ALL_PORT_PAIRS+=" kibana-$version=$(port_for "$version" kibana)" ;;
            logstash)
                ALL_PORT_PAIRS+=" logstash-api-$version=$(port_for "$version" logstash-api)"
                ALL_PORT_PAIRS+=" logstash-input-$version=$(port_for "$version" logstash-input)"
                ;;
        esac
    done
done
validate_unique_ports "Elastic Stack" "$ALL_PORT_PAIRS"

artifact_url() {
    local component="$1" version="$2" arch="$3"
    case "$component" in
        elasticsearch) printf '%s/elasticsearch/elasticsearch-%s-linux-%s.tar.gz\n' "$ELASTIC_ARTIFACT_BASE_URL" "$version" "$arch" ;;
        kibana) printf '%s/kibana/kibana-%s-linux-%s.tar.gz\n' "$ELASTIC_ARTIFACT_BASE_URL" "$version" "$arch" ;;
        logstash) printf '%s/logstash/logstash-%s-linux-%s.tar.gz\n' "$ELASTIC_ARTIFACT_BASE_URL" "$version" "$arch" ;;
    esac
}

component_home() { printf '%s/%s/runtime/%s\n' "$VERSIONS_DIR" "$1" "$2"; }

install_component() {
    local version="$1" component="$2" arch url stage archive checksum_file extracted target expected actual
    target="$(component_home "$version" "$component")"
    if [ "$ELASTIC_FORCE_RUNTIME_REFRESH" != "1" ] && [ -x "$target/bin/$component" ]; then
        log "$component $version đã tồn tại; bỏ qua download."
        return
    fi
    arch="$(elastic_arch)"
    url="$(artifact_url "$component" "$version" "$arch")"
    stage="$(make_project_staging_dir "$SYSTEM_DIR" "elastic-$component-$version")"
    archive="$stage/archive.tar.gz"
    checksum_file="$stage/archive.tar.gz.sha512"
    extracted="$stage/extracted"
    mkdir -p "$extracted"
    trap 'run_root rm -rf "$stage"' RETURN

    log "Tải $component $version..."
    curl -fL --retry 3 --connect-timeout 20 "$url" -o "$archive"
    curl -fL --retry 3 --connect-timeout 20 "$url.sha512" -o "$checksum_file"
    expected="$(awk '{print $1; exit}' "$checksum_file")"
    actual="$(sha512sum "$archive" | awk '{print $1}')"
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "SHA512 $component $version không khớp."

    tar -xzf "$archive" -C "$extracted" --strip-components=1
    [ -x "$extracted/bin/$component" ] || die "Archive $component $version thiếu bin/$component."
    mkdir -p "$(dirname "$target")"
    atomic_replace_directory "$extracted" "$target"
    run_root chown -R root:root "$target"
    run_root chmod -R a+rX "$target"
    run_root rm -rf "$stage"
    trap - RETURN
}

write_version_config() {
    local version="$1" root config data logs run home es_port kibana_port ls_api ls_input
    root="$VERSIONS_DIR/$version"
    config="$root/config"; data="$root/data"; logs="$root/logs"; run="$root/run"; home="$root/home"
    es_port="$(port_for "$version" elasticsearch)"
    kibana_port="$(port_for "$version" kibana)"
    ls_api="$(port_for "$version" logstash-api)"
    ls_input="$(port_for "$version" logstash-input)"

    run_root install -d -o "$ELASTIC_SERVICE_USER" -g "$ELASTIC_SERVICE_GROUP" -m 755 "$root" "$config" "$data" "$logs" "$run" "$home"

    if list_contains elasticsearch "${COMPONENTS[*]}"; then
        mkdir -p "$config/elasticsearch/jvm.options.d"
        cat > "$config/elasticsearch/elasticsearch.yml" <<CFG
cluster.name: kaggle-dev-$version
node.name: kaggle-dev-$version-1
path.data: $data/elasticsearch
path.logs: $logs/elasticsearch
network.host: 127.0.0.1
http.port: $es_port
discovery.type: single-node
xpack.security.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.enrollment.enabled: false
CFG
        cat > "$config/elasticsearch/jvm.options.d/kaggle.options" <<CFG
-Xms$ELASTIC_HEAP_SIZE
-Xmx$ELASTIC_HEAP_SIZE
CFG
        run_root install -d -o "$ELASTIC_SERVICE_USER" -g "$ELASTIC_SERVICE_GROUP" -m 755 "$data/elasticsearch" "$logs/elasticsearch"
        run_root chown -R "$ELASTIC_SERVICE_USER:$ELASTIC_SERVICE_GROUP" "$config/elasticsearch"
    fi

    if list_contains kibana "${COMPONENTS[*]}"; then
        mkdir -p "$config/kibana"
        cat > "$config/kibana/kibana.yml" <<CFG
server.host: "127.0.0.1"
server.port: $kibana_port
elasticsearch.hosts: ["http://127.0.0.1:$es_port"]
pid.file: "$run/kibana.pid"
path.data: "$data/kibana"
telemetry.enabled: false
telemetry.optIn: false
CFG
        run_root install -d -o "$ELASTIC_SERVICE_USER" -g "$ELASTIC_SERVICE_GROUP" -m 755 "$data/kibana"
        run_root chown -R "$ELASTIC_SERVICE_USER:$ELASTIC_SERVICE_GROUP" "$config/kibana"
    fi

    if list_contains logstash "${COMPONENTS[*]}"; then
        mkdir -p "$config/logstash/pipeline"
        cat > "$config/logstash/logstash.yml" <<CFG
api.http.host: "127.0.0.1"
api.http.port: $ls_api
path.data: "$data/logstash"
path.logs: "$logs/logstash"
CFG
        cat > "$config/logstash/pipelines.yml" <<CFG
- pipeline.id: kaggle-dev
  path.config: "$config/logstash/pipeline/*.conf"
CFG
        cat > "$config/logstash/pipeline/dev.conf" <<CFG
input {
  tcp { host => "127.0.0.1" port => $ls_input codec => json_lines }
}
output { stdout { codec => rubydebug } }
CFG
        run_root install -d -o "$ELASTIC_SERVICE_USER" -g "$ELASTIC_SERVICE_GROUP" -m 755 "$data/logstash" "$logs/logstash"
        run_root chown -R "$ELASTIC_SERVICE_USER:$ELASTIC_SERVICE_GROUP" "$config/logstash"
    fi

    printf '%s\n' "${COMPONENTS[*]}" > "$root/components"
    printf '%s\n' "$ELASTIC_HEAP_SIZE" > "$root/heap-size"
    printf '%s\n' "$es_port" > "$root/elasticsearch.port"
    printf '%s\n' "$kibana_port" > "$root/kibana.port"
    printf '%s\n' "$ls_api" > "$root/logstash-api.port"
    printf '%s\n' "$ls_input" > "$root/logstash-input.port"
    chmod 644 "$root"/{components,heap-size,elasticsearch.port,kibana.port,logstash-api.port,logstash-input.port}
}

write_service_helpers() {
    cat > "$SYSTEM_DIR/elastic-service.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
SYSTEM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SYSTEM_DIR/elastic"
SERVICE_USER="elastic"
DEFAULT_VERSION="$(cat "$BASE_DIR/default-version" 2>/dev/null || true)"
usage(){ echo "Usage: $0 <version> <elasticsearch|kibana|logstash> <start|stop|restart|status>" >&2; }
VERSION="${1:-$DEFAULT_VERSION}"; [ "$#" -eq 0 ] || shift
COMPONENT="${1:-elasticsearch}"; [ "$#" -eq 0 ] || shift
ACTION="${1:-status}"
ROOT="$BASE_DIR/versions/$VERSION"
HOME_DIR="$ROOT/runtime/$COMPONENT"
CONFIG="$ROOT/config/$COMPONENT"
DATA="$ROOT/data"; LOGS="$ROOT/logs"; RUN="$ROOT/run"
HEAP="$(cat "$ROOT/heap-size" 2>/dev/null || echo 512m)"
case "$COMPONENT" in
  elasticsearch) BIN="$HOME_DIR/bin/elasticsearch"; PORT="$(cat "$ROOT/elasticsearch.port")"; PIDFILE="$RUN/elasticsearch.pid"; LOGFILE="$LOGS/elasticsearch-service.log"; HEALTH="http://127.0.0.1:$PORT/" ;;
  kibana) BIN="$HOME_DIR/bin/kibana"; PORT="$(cat "$ROOT/kibana.port")"; PIDFILE="$RUN/kibana.pid"; LOGFILE="$LOGS/kibana.log"; HEALTH="http://127.0.0.1:$PORT/api/status" ;;
  logstash) BIN="$HOME_DIR/bin/logstash"; PORT="$(cat "$ROOT/logstash-api.port")"; PIDFILE="$RUN/logstash.pid"; LOGFILE="$LOGS/logstash-service.log"; HEALTH="http://127.0.0.1:$PORT/" ;;
  *) usage; exit 2 ;;
esac
[ -x "$BIN" ] || { echo "$COMPONENT $VERSION is not installed." >&2; exit 1; }
run_as_service(){
  if [ "$(id -un)" = "$SERVICE_USER" ]; then "$@"
  elif [ "$(id -u)" -eq 0 ]; then
    if command -v runuser >/dev/null 2>&1; then runuser -u "$SERVICE_USER" -- "$@"
    else q=""; printf -v q '%q ' "$@"; su -s /bin/bash "$SERVICE_USER" -c "$q"; fi
  elif command -v sudo >/dev/null 2>&1; then sudo -u "$SERVICE_USER" -- "$@"
  else echo "Need root/sudo." >&2; exit 1; fi
}
is_alive(){ curl -fsS --max-time 2 "$HEALTH" >/dev/null 2>&1; }
pid_from_file(){ run_as_service sh -c 'test -f "$1" && cat "$1" || true' _ "$PIDFILE" 2>/dev/null || true; }
start_server(){
  is_alive && return 0
  run_as_service mkdir -p "$DATA/$COMPONENT" "$LOGS" "$RUN" "$ROOT/home"
  run_as_service rm -f "$PIDFILE"
  case "$COMPONENT" in
    elasticsearch)
      run_as_service bash -c 'cd "$1" && exec env HOME="$2" ES_PATH_CONF="$3" ES_JAVA_OPTS="-Xms$4 -Xmx$4" "$5" -d -p "$6" >> "$7" 2>&1' _ "$ROOT" "$ROOT/home" "$CONFIG" "$HEAP" "$BIN" "$PIDFILE" "$LOGFILE" ;;
    kibana)
      run_as_service bash -c 'cd "$1"; nohup env HOME="$2" "$3" --config "$4/kibana.yml" >> "$5" 2>&1 & echo $! > "$6"' _ "$ROOT" "$ROOT/home" "$BIN" "$CONFIG" "$LOGFILE" "$PIDFILE" ;;
    logstash)
      run_as_service bash -c 'cd "$1"; nohup env HOME="$2" LS_JAVA_OPTS="-Xms$3 -Xmx$3" "$4" --path.settings "$5" >> "$6" 2>&1 & echo $! > "$7"' _ "$ROOT" "$ROOT/home" "$HEAP" "$BIN" "$CONFIG" "$LOGFILE" "$PIDFILE" ;;
  esac
  limit=120; [ "$COMPONENT" = elasticsearch ] && limit=90
  for ((i=1;i<=limit;i++)); do is_alive && return 0; sleep 1; done
  echo "$COMPONENT $VERSION failed to start. See $LOGFILE" >&2; exit 1
}
stop_server(){
  local pid; pid="$(pid_from_file)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && run_as_service kill -0 "$pid" 2>/dev/null; then
    run_as_service kill -TERM "$pid" || true
    for _ in {1..30}; do run_as_service kill -0 "$pid" 2>/dev/null || { run_as_service rm -f "$PIDFILE" || true; return 0; }; sleep 1; done
    run_as_service kill -KILL "$pid" || true
  else echo "$COMPONENT $VERSION is not running."; fi
}
case "$ACTION" in
  start) start_server ;;
  stop) stop_server ;;
  restart) stop_server; start_server ;;
  status) if is_alive; then echo "$COMPONENT $VERSION running on port $PORT."; else echo "$COMPONENT $VERSION not running."; exit 1; fi ;;
  *) usage; exit 2 ;;
esac
HELPER
    sed -i "s/^SERVICE_USER=\"elastic\"$/SERVICE_USER=\"$ELASTIC_SERVICE_USER\"/" "$SYSTEM_DIR/elastic-service.sh"
    chmod 755 "$SYSTEM_DIR/elastic-service.sh"

    cat > "$SYSTEM_DIR/elastic-ctl.sh" <<'CTL'
#!/usr/bin/env bash
set -euo pipefail
SYSTEM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SYSTEM_DIR/elastic"
DEFAULT_VERSION="$(cat "$BASE_DIR/default-version" 2>/dev/null || true)"
usage(){ echo "Usage: $0 [version] <start|stop|restart|status> [elasticsearch|kibana|logstash|all]" >&2; }
first="${1:-}"
case "$first" in start|stop|restart|status) VERSION="$DEFAULT_VERSION" ;; *) VERSION="$first"; shift || true ;; esac
ACTION="${1:-status}"; [ "$#" -eq 0 ] || shift
TARGET="${1:-all}"
case "$ACTION" in start|stop|restart|status) ;; *) usage; exit 2 ;; esac
case "$TARGET" in elasticsearch|kibana|logstash|all) ;; *) usage; exit 2 ;; esac
ROOT="$BASE_DIR/versions/$VERSION"
COMPONENTS="$(cat "$ROOT/components" 2>/dev/null || true)"
[ -n "$COMPONENTS" ] || { echo "Elastic $VERSION not installed." >&2; exit 1; }
has(){ [[ " $COMPONENTS " == *" $1 "* ]]; }
run_one(){ has "$1" || return 0; "$SYSTEM_DIR/elastic-service.sh" "$VERSION" "$1" "$ACTION"; }
if [ "$TARGET" != all ]; then run_one "$TARGET"; exit; fi
case "$ACTION" in
  stop) for c in logstash kibana elasticsearch; do run_one "$c" || true; done ;;
  *) rc=0; for c in elasticsearch kibana logstash; do run_one "$c" || rc=1; done; exit "$rc" ;;
esac
CTL
    chmod 755 "$SYSTEM_DIR/elastic-ctl.sh"

    cat > "$SYSTEM_DIR/start-elastic.sh" <<'START'
#!/usr/bin/env bash
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/elastic-ctl.sh" start all "$@"
START
    cat > "$SYSTEM_DIR/stop-elastic.sh" <<'STOP'
#!/usr/bin/env bash
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/elastic-ctl.sh" stop all "$@"
STOP
    cat > "$SYSTEM_DIR/status-elastic.sh" <<'STATUS'
#!/usr/bin/env bash
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/elastic-ctl.sh" status all "$@"
STATUS
    cat > "$SYSTEM_DIR/restart-elastic.sh" <<'RESTART'
#!/usr/bin/env bash
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/elastic-ctl.sh" restart all "$@"
RESTART
    chmod 755 "$SYSTEM_DIR"/{start,stop,status,restart}-elastic.sh
}

main() {
    local version component
    run_root mkdir -p "$SYSTEM_DIR" "$BASE_DIR" "$VERSIONS_DIR"
    run_root chown "$(id -u):$(id -g)" "$SYSTEM_DIR" "$BASE_DIR" "$VERSIONS_DIR"
    run_root chmod 755 "$SYSTEM_DIR" "$BASE_DIR" "$VERSIONS_DIR"
    ensure_system_user "$ELASTIC_SERVICE_USER" "$BASE_DIR" /bin/bash
    ELASTIC_SERVICE_GROUP="$(id -gn "$ELASTIC_SERVICE_USER")"

    for version in "${REQUESTED_VERSIONS[@]}"; do
        for component in "${COMPONENTS[@]}"; do install_component "$version" "$component"; done
        write_version_config "$version"
    done
    printf '%s\n' "$ELASTIC_DEFAULT_VERSION" > "$BASE_DIR/default-version"
    chmod 644 "$BASE_DIR/default-version"
    write_service_helpers

    for version in $ELASTIC_AUTO_START_VERSIONS; do
        log "Auto-start Elastic Stack $version..."
        bash "$SYSTEM_DIR/elastic-ctl.sh" "$version" start all
    done
    ensure_system_scripts_executable "$SYSTEM_DIR"

    echo
    echo "================================================================="
    echo "✅ CÀI ĐẶT ELASTIC STACK THÀNH CÔNG"
    echo "================================================================="
    for version in "${REQUESTED_VERSIONS[@]}"; do
        echo "  Elastic $version (${COMPONENTS[*]})"
        list_contains elasticsearch "${COMPONENTS[*]}" && echo "    Elasticsearch: http://127.0.0.1:$(port_for "$version" elasticsearch)"
        list_contains kibana "${COMPONENTS[*]}" && echo "    Kibana       : http://127.0.0.1:$(port_for "$version" kibana)"
        list_contains logstash "${COMPONENTS[*]}" && echo "    Logstash API : http://127.0.0.1:$(port_for "$version" logstash-api)"
        echo "    Control      : bash $SYSTEM_DIR/elastic-ctl.sh $version <start|stop|status|restart> [component|all]"
    done
    echo "  Auto-start versions: ${ELASTIC_AUTO_START_VERSIONS:-none}"
    echo "================================================================="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
