#!/usr/bin/env bash
set -euo pipefail

# Install the PostgreSQL runtime into .system/pg/runtime; data/log state is kept separate.
# Default: PostgreSQL 18 + pgvector. Supports installing multiple major versions side by side from PGDG.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEM_DIR="${KAGGLE_SYSTEM_DIR:-$PROJECT_ROOT/.system}"
BASE_DIR="$SYSTEM_DIR/pg"
RUNTIME_DIR="$BASE_DIR/runtime"
COMMON="$SCRIPT_DIR/lib/common.sh"

# shellcheck source=lib/common.sh
source "$COMMON"
# shellcheck source=lib/load-config.sh
source "$SCRIPT_DIR/lib/load-config.sh"
load_project_config "$PROJECT_ROOT"

VERSIONS="${POSTGRES_VERSIONS:-${VERSIONS:-18}}"
POSTGRES_DEFAULT_VERSION="${POSTGRES_DEFAULT_VERSION:-18}"
POSTGRES_AUTO_START_VERSIONS="${POSTGRES_AUTO_START_VERSIONS:-$POSTGRES_DEFAULT_VERSION}"
# Backward-compatible aliases for the two versions used by older releases.
POSTGRES_PORT_14="${POSTGRES_PORT_14:-${PORT_14:-5432}}"
POSTGRES_PORT_18="${POSTGRES_PORT_18:-${PORT_18:-5433}}"
POSTGRES_INCLUDE_JIT="${POSTGRES_INCLUDE_JIT:-0}"
POSTGRES_INSTALL_PGVECTOR="${POSTGRES_INSTALL_PGVECTOR:-1}"
POSTGRES_AUTO_ENABLE_PGVECTOR="${POSTGRES_AUTO_ENABLE_PGVECTOR:-$POSTGRES_INSTALL_PGVECTOR}"
POSTGRES_SERVICE_USER="${POSTGRES_SERVICE_USER:-postgres}"
POSTGRES_FORCE_RUNTIME_REFRESH="${POSTGRES_FORCE_RUNTIME_REFRESH:-0}"
POSTGRES_SERVICE_GROUP="$POSTGRES_SERVICE_USER"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL="${LC_ALL:-C.UTF-8}"

log() { printf '[install-postgres] %s\n' "$*"; }
die() { common_die "$*"; }

init_privilege
require_command curl
require_command gpg
require_command dpkg-deb
case "$POSTGRES_INCLUDE_JIT" in 0|1) ;; *) die "POSTGRES_INCLUDE_JIT must be either 0 or 1." ;; esac
case "$POSTGRES_INSTALL_PGVECTOR" in 0|1) ;; *) die "POSTGRES_INSTALL_PGVECTOR must be either 0 or 1." ;; esac
case "$POSTGRES_AUTO_ENABLE_PGVECTOR" in 0|1) ;; *) die "POSTGRES_AUTO_ENABLE_PGVECTOR must be either 0 or 1." ;; esac
case "$POSTGRES_FORCE_RUNTIME_REFRESH" in 0|1) ;; *) die "POSTGRES_FORCE_RUNTIME_REFRESH must be either 0 or 1." ;; esac
if [ "$POSTGRES_AUTO_ENABLE_PGVECTOR" = "1" ] && [ "$POSTGRES_INSTALL_PGVECTOR" != "1" ]; then
    die "POSTGRES_AUTO_ENABLE_PGVECTOR=1 requires POSTGRES_INSTALL_PGVECTOR=1."
fi

REQUESTED_VERSIONS=()
for version in $VERSIONS; do
    case "$version" in
        ''|*[!0-9]*) die "Invalid PostgreSQL major version: '$version'." ;;
    esac
    # Do not hard-code the list of major versions supported by PGDG. PGDG changes with the
    # PostgreSQL/Ubuntu lifecycle; the package download below is the source of truth.
    if [ "$version" -lt 10 ] || [ "$version" -gt 99 ]; then
        die "Unreasonable PostgreSQL major version: '$version'."
    fi
    if [[ " ${REQUESTED_VERSIONS[*]} " != *" $version "* ]]; then
        REQUESTED_VERSIONS+=("$version")
    fi
done
[ "${#REQUESTED_VERSIONS[@]}" -gt 0 ] || die "POSTGRES_VERSIONS must not be empty."
list_contains "$POSTGRES_DEFAULT_VERSION" "${REQUESTED_VERSIONS[*]}" \
    || die "POSTGRES_DEFAULT_VERSION=$POSTGRES_DEFAULT_VERSION must be included in POSTGRES_VERSIONS."

port_for() {
    local version="$1" key variable legacy fallback value
    key="$(version_env_key "$version")"
    variable="POSTGRES_PORT_${key}"
    legacy="PORT_${version}"
    case "$version" in
        14) fallback="$POSTGRES_PORT_14" ;;
        18) fallback="$POSTGRES_PORT_18" ;;
        *) fallback="$((5400 + version))" ;;
    esac
    value="${!variable:-${!legacy:-$fallback}}"
    validate_port "$variable" "$value"
    printf '%s\n' "$value"
}

PORT_PAIRS=""
for version in "${REQUESTED_VERSIONS[@]}"; do
    PORT_PAIRS+=" $version=$(port_for "$version")"
done
validate_unique_ports "PostgreSQL" "$PORT_PAIRS"

for version in $POSTGRES_AUTO_START_VERSIONS; do
    list_contains "$version" "${REQUESTED_VERSIONS[*]}" \
        || die "POSTGRES_AUTO_START_VERSIONS contains '$version', which is not present in POSTGRES_VERSIONS."
done

runtime_root_for() {
    local version="$1"
    if [ -x "$RUNTIME_DIR/usr/lib/postgresql/$version/bin/initdb" ]; then
        printf '%s\n' "$RUNTIME_DIR"
    elif [ -x "$BASE_DIR/usr/lib/postgresql/$version/bin/initdb" ]; then
        # Compatibility with the runtime tree used by older installer versions.
        printf '%s\n' "$BASE_DIR"
    else
        printf '%s\n' "$RUNTIME_DIR"
    fi
}

pg_bin() {
    local version="$1" root
    root="$(runtime_root_for "$version")"
    printf '%s\n' "$root/usr/lib/postgresql/$version/bin"
}

pgvector_control_file() {
    local version="$1" root
    root="$(runtime_root_for "$version")"
    printf '%s\n' "$root/usr/share/postgresql/$version/extension/vector.control"
}

pgvector_library_file() {
    local version="$1" root
    root="$(runtime_root_for "$version")"
    printf '%s\n' "$root/usr/lib/postgresql/$version/lib/vector.so"
}

runtime_has_pgvector() {
    local version="$1"
    [ -f "$(pgvector_control_file "$version")" ] \
        && [ -f "$(pgvector_library_file "$version")" ]
}

lib_path_for() {
    local version="$1" root dir
    root="$(runtime_root_for "$version")"
    {
        [ -d "$root/usr/lib/postgresql/$version/lib" ] && printf '%s\n' "$root/usr/lib/postgresql/$version/lib"
        for dir in "$root/lib" "$root/usr/lib"; do
            [ -d "$dir" ] || continue
            find "$dir" -type f -name '*.so*' -printf '%h\n' 2>/dev/null || true
            find "$dir" -type l -name '*.so*' -printf '%h\n' 2>/dev/null || true
        done
    } | awk -v own="/postgresql/$version/" '
        index($0, "/postgresql/") == 0 || index($0, own) > 0 { if (!seen[$0]++) print }
    ' | paste -sd ':' -
}

run_pg() {
    local version="$1"
    shift
    local libs
    libs="$(lib_path_for "$version")"
    run_as_user "$POSTGRES_SERVICE_USER" env \
        "LD_LIBRARY_PATH=$libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$@"
}

setup_pgdg_repo() {
    local codename key_tmp fingerprint expected
    expected="B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    [ -n "$codename" ] || die "Unable to determine VERSION_CODENAME from /etc/os-release."

    log "Installing minimal APT bootstrap tools and configuring PGDG for '$codename'..."
    run_root apt-get update -y
    run_root apt-get install -y --no-install-recommends ca-certificates curl gnupg

    key_tmp="$(mktemp)"
    trap 'rm -f "$key_tmp"' RETURN
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o "$key_tmp"
    fingerprint="$(gpg --show-keys --with-colons "$key_tmp" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    [ "$fingerprint" = "$expected" ] || die "PGDG key fingerprint mismatch: $fingerprint"

    run_root install -d -m 755 /usr/share/postgresql-common/pgdg
    run_root install -o root -g root -m 644 "$key_tmp" /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    printf 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' "$codename" \
        | run_root tee /etc/apt/sources.list.d/pgdg.list >/dev/null
    run_root apt-get update -y
    rm -f "$key_tmp"
    trap - RETURN
}

installed_runtime_versions() {
    local path version
    shopt -s nullglob
    for path in "$RUNTIME_DIR"/usr/lib/postgresql/*/bin/initdb "$BASE_DIR"/usr/lib/postgresql/*/bin/initdb; do
        [ -x "$path" ] || continue
        version="$(basename "$(dirname "$(dirname "$path")")")"
        printf '%s\n' "$version"
    done | sort -nu
    shopt -u nullglob
}

download_runtime() {
    local stage deb_dir new_runtime version
    local -a runtime_versions packages

    runtime_versions=("${REQUESTED_VERSIONS[@]}")
    while IFS= read -r version; do
        [ -n "$version" ] || continue
        if [[ " ${runtime_versions[*]} " != *" $version "* ]]; then
            runtime_versions+=("$version")
        fi
    done < <(installed_runtime_versions)

    packages=()
    for version in "${runtime_versions[@]}"; do
        packages+=("postgresql-$version" "postgresql-client-$version")
        if [ "$POSTGRES_INSTALL_PGVECTOR" = "1" ]; then
            packages+=("postgresql-$version-pgvector")
        fi
        if [ "$POSTGRES_INCLUDE_JIT" = "1" ]; then
            packages+=("postgresql-$version-jit")
        fi
    done

    setup_pgdg_repo
    stage="$(make_project_staging_dir "$SYSTEM_DIR" postgres-runtime)"
    deb_dir="$stage/debs"
    new_runtime="$stage/runtime"
    trap 'run_root rm -rf "$stage"' RETURN

    log "Downloading the required packages only: ${packages[*]}"
    apt_download_packages "$deb_dir" "${packages[@]}"
    extract_deb_directory "$deb_dir" "$new_runtime"
    write_deb_manifest "$deb_dir" "$new_runtime/DEB-MANIFEST.tsv"
    normalize_runtime_permissions "$new_runtime"

    for version in "${runtime_versions[@]}"; do
        [ -x "$new_runtime/usr/lib/postgresql/$version/bin/initdb" ] \
            || die "Runtime staging is missing PostgreSQL $version initdb."
        [ -x "$new_runtime/usr/lib/postgresql/$version/bin/psql" ] \
            || die "Runtime staging is missing PostgreSQL $version psql."
        if [ "$POSTGRES_INSTALL_PGVECTOR" = "1" ]; then
            [ -f "$new_runtime/usr/share/postgresql/$version/extension/vector.control" ] \
                || die "Runtime staging is missing vector.control for PostgreSQL $version."
            [ -f "$new_runtime/usr/lib/postgresql/$version/lib/vector.so" ] \
                || die "Runtime staging is missing vector.so for PostgreSQL $version."
        fi
    done

    run_root mkdir -p "$BASE_DIR"
    run_root chown "$(id -u):$(id -g)" "$BASE_DIR"
    atomic_replace_directory "$new_runtime" "$RUNTIME_DIR"
    run_root chown -R root:root "$RUNTIME_DIR"
    run_root rm -rf "$BASE_DIR/usr" "$BASE_DIR/lib"

    run_root rm -rf "$stage"
    trap - RETURN
    log "Atomically replaced the runtime at $RUNTIME_DIR; data was not moved."
}

verify_runtime_dependencies() {
    local version bin executable vector_lib missing=0
    for version in "${REQUESTED_VERSIONS[@]}"; do
        bin="$(pg_bin "$version")"
        for executable in initdb pg_ctl postgres psql pg_isready; do
            [ -x "$bin/$executable" ] || die "Missing executable: $bin/$executable"
            if command -v ldd >/dev/null 2>&1 && env "LD_LIBRARY_PATH=$(lib_path_for "$version")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$bin/$executable" 2>&1 | grep -q 'not found'; then
                printf 'Missing dependency for %s:\n' "$bin/$executable" >&2
                env "LD_LIBRARY_PATH=$(lib_path_for "$version")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$bin/$executable" >&2 || true
                missing=1
            fi
        done

        if [ "$POSTGRES_INSTALL_PGVECTOR" = "1" ]; then
            runtime_has_pgvector "$version" || die "PostgreSQL $version runtime is missing pgvector."
            vector_lib="$(pgvector_library_file "$version")"
            if command -v ldd >/dev/null 2>&1 && env "LD_LIBRARY_PATH=$(lib_path_for "$version")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$vector_lib" 2>&1 | grep -q 'not found'; then
                printf 'Missing dependency for %s:\n' "$vector_lib" >&2
                env "LD_LIBRARY_PATH=$(lib_path_for "$version")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$vector_lib" >&2 || true
                missing=1
            fi
        fi
    done
    [ "$missing" -eq 0 ] || die "The PostgreSQL/pgvector runtime is missing shared libraries on the current operating system."
}

sql_quote_literal() {
    printf '%s' "$1" | sed "s/'/''/g"
}

prepare_cluster() {
    local version="$1" port="$2"
    local bin data log_dir run_dir managed_tmp hba_tmp socket_escaped
    bin="$(pg_bin "$version")"
    data="$BASE_DIR/pg_data_$version"
    log_dir="$BASE_DIR/pg_log_$version"
    run_dir="$BASE_DIR/pg_run_$version"

    run_root install -d -o "$POSTGRES_SERVICE_USER" -g "$POSTGRES_SERVICE_GROUP" -m 755 "$log_dir" "$run_dir"

    if [ -f "$data/PG_VERSION" ] && [ "$(cat "$data/PG_VERSION")" != "$version" ]; then
        die "$data contains PG_VERSION=$(cat "$data/PG_VERSION"), which does not match version $version. The installer will not delete data automatically."
    fi

    if [ ! -f "$data/PG_VERSION" ]; then
        run_root rm -rf "$data"
        run_root install -d -o "$POSTGRES_SERVICE_USER" -g "$POSTGRES_SERVICE_GROUP" -m 700 "$data"
        log "Initializing PostgreSQL $version cluster..."
        run_pg "$version" "$bin/initdb" -D "$data" -U postgres \
            --auth-local=trust --auth-host=trust -E UTF8 --locale=C.UTF-8
    else
        log "Keeping the existing PostgreSQL $version cluster at $data."
        if run_pg "$version" "$bin/pg_ctl" -D "$data" status >/dev/null 2>&1; then
            log "Stopping PostgreSQL $version cluster to apply the new configuration/port..."
            run_pg "$version" "$bin/pg_ctl" -D "$data" stop -m fast -w
        fi
    fi

    socket_escaped="$(sql_quote_literal "$run_dir")"
    managed_tmp="$(mktemp)"
    hba_tmp="$(mktemp)"
    cat > "$managed_tmp" <<CFG
# Generated by install-postgres.sh; updated on subsequent runs.
port = $port
listen_addresses = '127.0.0.1'
unix_socket_directories = '$socket_escaped'
hba_file = '$data/pg_hba.kaggle.conf'
CFG
    cat > "$hba_tmp" <<'HBA'
# Allow local/loopback connections only. Suitable for a single-user development notebook.
local   all   all                              trust
host    all   all   127.0.0.1/32               trust
host    all   all   ::1/128                    trust
HBA

    run_root install -o "$POSTGRES_SERVICE_USER" -g "$POSTGRES_SERVICE_GROUP" -m 600 "$managed_tmp" "$data/kaggle-managed.conf"
    run_root install -o "$POSTGRES_SERVICE_USER" -g "$POSTGRES_SERVICE_GROUP" -m 600 "$hba_tmp" "$data/pg_hba.kaggle.conf"
    rm -f "$managed_tmp" "$hba_tmp"

    if ! run_root grep -Fqx "include_if_exists = 'kaggle-managed.conf'" "$data/postgresql.conf"; then
        printf "\n# Configuration managed by the Kaggle installer\ninclude_if_exists = 'kaggle-managed.conf'\n" \
            | run_root tee -a "$data/postgresql.conf" >/dev/null
    fi

    run_root chown -R "$POSTGRES_SERVICE_USER:$POSTGRES_SERVICE_GROUP" "$data" "$log_dir" "$run_dir"
    run_root chmod 700 "$data"
}

write_service_helper() {
    local version="$1" port="$2" helper
    helper="$SYSTEM_DIR/pg${version}-service.sh"

    cat > "$helper" <<EOF
#!/usr/bin/env bash
set -euo pipefail

VERSION="$version"
PORT="$port"
SERVICE_USER="$POSTGRES_SERVICE_USER"
SYSTEM_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="\$SYSTEM_DIR/pg"
RUNTIME_DIR="\$BASE_DIR/runtime"
if [ -x "\$RUNTIME_DIR/usr/lib/postgresql/\$VERSION/bin/initdb" ]; then
    RUNTIME_ROOT="\$RUNTIME_DIR"
else
    RUNTIME_ROOT="\$BASE_DIR"
fi
BIN="\$RUNTIME_ROOT/usr/lib/postgresql/\$VERSION/bin"
DATA="\$BASE_DIR/pg_data_\$VERSION"
LOGFILE="\$BASE_DIR/pg_log_\$VERSION/postgres.log"

lib_path() {
    {
        [ -d "\$RUNTIME_ROOT/usr/lib/postgresql/\$VERSION/lib" ] && printf '%s\n' "\$RUNTIME_ROOT/usr/lib/postgresql/\$VERSION/lib"
        for dir in "\$RUNTIME_ROOT/lib" "\$RUNTIME_ROOT/usr/lib"; do
            [ -d "\$dir" ] || continue
            find "\$dir" -type f -name '*.so*' -printf '%h\n' 2>/dev/null || true
            find "\$dir" -type l -name '*.so*' -printf '%h\n' 2>/dev/null || true
        done
    } | awk -v own="/postgresql/\$VERSION/" 'index(\$0, "/postgresql/") == 0 || index(\$0, own) > 0 { if (!seen[\$0]++) print }' | paste -sd ':' -
}
LIBS="\$(lib_path)"

run_as_service() {
    if [ "\$(id -un)" = "\$SERVICE_USER" ]; then
        "\$@"
    elif [ "\$(id -u)" -eq 0 ]; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "\$SERVICE_USER" -- "\$@"
        else
            quoted=""; printf -v quoted '%q ' "\$@"; su -s /bin/bash "\$SERVICE_USER" -c "\$quoted"
        fi
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "\$SERVICE_USER" -- "\$@"
    else
        echo "Root or sudo is required to control PostgreSQL." >&2
        exit 1
    fi
}

pg_service() {
    run_as_service env "LD_LIBRARY_PATH=\$LIBS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" "\$@"
}

is_running() {
    pg_service "\$BIN/pg_ctl" -D "\$DATA" status >/dev/null 2>&1
}

start_server() {
    if is_running; then
        return
    fi
    if env "LD_LIBRARY_PATH=\$LIBS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" "\$BIN/pg_isready" -h 127.0.0.1 -p "\$PORT" -q >/dev/null 2>&1; then
        echo "Port \$PORT is already used by another PostgreSQL instance; refusing to start the wrong service." >&2
        exit 1
    fi
    pid="\$(pg_service sh -c 'test -f "\$1" && head -n1 "\$1" || true' _ "\$DATA/postmaster.pid")"
    if [ -n "\$pid" ]; then
        if run_as_service kill -0 "\$pid" 2>/dev/null; then
            echo "A live PID \$pid exists in \$DATA/postmaster.pid; refusing to remove the PID file." >&2
            exit 1
        fi
        pg_service rm -f "\$DATA/postmaster.pid"
    fi
    pg_service "\$BIN/pg_ctl" -D "\$DATA" -l "\$LOGFILE" -w start
}

action="\${1:-psql}"
[ "\$#" -eq 0 ] || shift
case "\$action" in
    start) start_server ;;
    stop)
        if is_running; then
            pg_service "\$BIN/pg_ctl" -D "\$DATA" stop -m fast -w
        else
            echo "PostgreSQL \$VERSION is not running."
        fi
        ;;
    status)
        if is_running; then echo "PostgreSQL \$VERSION is running on port \$PORT."; else echo "PostgreSQL \$VERSION is not running."; exit 1; fi
        ;;
    psql)
        start_server
        exec env "LD_LIBRARY_PATH=\$LIBS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" \
            "\$BIN/psql" -h 127.0.0.1 -p "\$PORT" -U postgres -d postgres "\$@"
        ;;
    enable-pgvector)
        start_server
        database="\${1:-postgres}"
        env "LD_LIBRARY_PATH=\$LIBS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" \
            "\$BIN/psql" -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "\$PORT" \
            -U postgres -d "\$database" -c 'CREATE EXTENSION IF NOT EXISTS vector; ALTER EXTENSION vector UPDATE;'
        ;;
    *) echo "Usage: \$0 {start|stop|status|psql [psql args...]|enable-pgvector [database]}" >&2; exit 2 ;;
esac
EOF
    chmod 755 "$helper"

    rm -f "$SYSTEM_DIR/run-psql$version.sh"

    cat > "$SYSTEM_DIR/run-psql$version.sh" <<EOF
#!/usr/bin/env bash
exec "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/pg${version}-service.sh" psql "\$@"
EOF
    rm -f "$SYSTEM_DIR/start-pg$version.sh"
    cat > "$SYSTEM_DIR/start-pg$version.sh" <<EOF
#!/usr/bin/env bash
exec "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/pg${version}-service.sh" start "\$@"
EOF
    rm -f "$SYSTEM_DIR/stop-pg$version.sh"
    cat > "$SYSTEM_DIR/stop-pg$version.sh" <<EOF
#!/usr/bin/env bash
exec "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/pg${version}-service.sh" stop "\$@"
EOF
    rm -f "$SYSTEM_DIR/enable-pgvector$version.sh"
    cat > "$SYSTEM_DIR/enable-pgvector$version.sh" <<EOF
#!/usr/bin/env bash
exec "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/pg${version}-service.sh" enable-pgvector "\$@"
EOF
    chmod 755 "$SYSTEM_DIR/run-psql$version.sh" "$SYSTEM_DIR/start-pg$version.sh" \
        "$SYSTEM_DIR/stop-pg$version.sh" "$SYSTEM_DIR/enable-pgvector$version.sh"
}

enable_default_pgvector_databases() {
    local version="$1" database extversion
    [ "$POSTGRES_AUTO_ENABLE_PGVECTOR" = "1" ] || return 0

    for database in template1 postgres; do
        log "Enabling pgvector in database '$database' for PostgreSQL $version..."
        bash "$SYSTEM_DIR/enable-pgvector$version.sh" "$database" >/dev/null
    done

    extversion="$(
        bash "$SYSTEM_DIR/run-psql$version.sh" -X -tAc "SELECT extversion FROM pg_extension WHERE extname = 'vector';" |
            sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
    )"
    [ -n "$extversion" ] || die "Unable to verify the vector extension in the postgres database for PostgreSQL $version."
    printf '    ✅ pgvector %s is enabled in postgres and template1\n' "$extversion"
}

main() {
    local version need_download=0 output actual_data expected_data

    run_root mkdir -p "$SYSTEM_DIR" "$BASE_DIR"
    run_root chown "$(id -u):$(id -g)" "$SYSTEM_DIR" "$BASE_DIR"
    run_root chmod 755 "$SYSTEM_DIR" "$BASE_DIR"
    ensure_system_user "$POSTGRES_SERVICE_USER" "$BASE_DIR"
    POSTGRES_SERVICE_GROUP="$(id -gn "$POSTGRES_SERVICE_USER")"

    if [ "$POSTGRES_FORCE_RUNTIME_REFRESH" = "1" ]; then
        log "POSTGRES_FORCE_RUNTIME_REFRESH=1; refreshing the runtime while preserving the data cluster."
        need_download=1
    fi
    if [ -d "$BASE_DIR/usr" ] && [ ! -d "$RUNTIME_DIR" ]; then
        log "Detected a legacy runtime; migrating to the separated runtime/data layout."
        need_download=1
    fi
    for version in "${REQUESTED_VERSIONS[@]}"; do
        if [ ! -x "$(pg_bin "$version")/initdb" ]; then
            need_download=1
        fi
        if [ "$POSTGRES_INSTALL_PGVECTOR" = "1" ] && ! runtime_has_pgvector "$version"; then
            log "PostgreSQL $version runtime does not include pgvector; downloading/updating the runtime."
            need_download=1
        fi
    done
    if [ "$need_download" -eq 1 ]; then
        download_runtime
    else
        log "All requested runtimes are already present; skipping package download."
    fi

    verify_runtime_dependencies

    for version in "${REQUESTED_VERSIONS[@]}"; do
        prepare_cluster "$version" "$(port_for "$version")"
        write_service_helper "$version" "$(port_for "$version")"
    done

    for version in "${REQUESTED_VERSIONS[@]}"; do
        log "Starting PostgreSQL $version temporarily for validation..."
        bash "$SYSTEM_DIR/start-pg$version.sh"
        output="$(bash "$SYSTEM_DIR/run-psql$version.sh" -tAc "SELECT version();")"
        actual_data="$(bash "$SYSTEM_DIR/run-psql$version.sh" -tAc "SHOW data_directory;" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        expected_data="$(readlink -f "$BASE_DIR/pg_data_$version")"
        [ "$(readlink -f "$actual_data")" = "$expected_data" ] \
            || die "Port $(port_for "$version") points to a different cluster: $actual_data"
        printf '    ✅ PostgreSQL %s: %s\n' "$version" "$output"
        if [ "$POSTGRES_INSTALL_PGVECTOR" = "1" ]; then
            enable_default_pgvector_databases "$version"
        fi
        if ! list_contains "$version" "$POSTGRES_AUTO_START_VERSIONS"; then
            log "PostgreSQL $version is install-only and not configured for auto-start; stopping it after validation."
            bash "$SYSTEM_DIR/stop-pg$version.sh"
        fi
    done

    ensure_system_scripts_executable "$SYSTEM_DIR"

    echo
    echo "================================================================="
    echo "✅ POSTGRESQL INSTALLATION COMPLETED SUCCESSFULLY"
    echo "================================================================="
    for version in "${REQUESTED_VERSIONS[@]}"; do
        echo "  PostgreSQL $version: postgresql://postgres@127.0.0.1:$(port_for "$version")/postgres"
        echo "    psql : bash $SYSTEM_DIR/run-psql$version.sh"
        echo "    start: bash $SYSTEM_DIR/start-pg$version.sh"
        echo "    stop : bash $SYSTEM_DIR/stop-pg$version.sh"
        if [ "$POSTGRES_INSTALL_PGVECTOR" = "1" ]; then
            echo "    pgvector: bash $SYSTEM_DIR/enable-pgvector$version.sh <database>"
        fi
    done
    echo "  Runtime: $RUNTIME_DIR"
    echo "  Data is kept separately in $BASE_DIR/pg_data_<version>/"
    echo "================================================================="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
