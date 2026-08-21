#!/usr/bin/env bash
set -euo pipefail

# Install SQLite + PostgreSQL + Redis + Elastic Stack + Qdrant + the mise toolchain.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEM_DIR="${KAGGLE_SYSTEM_DIR:-$PROJECT_ROOT/.system}"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/load-config.sh
source "$SCRIPT_DIR/lib/load-config.sh"
load_project_config "$PROJECT_ROOT"
SQLITE_SRC="$SCRIPT_DIR/sqlite3"
SQLITE_ORIGINAL_SRC="$SCRIPT_DIR/sqlite3-original-build"
SQLITE_DIR="$SYSTEM_DIR/sqlite3"

INSTALL_SQLITE="${INSTALL_SQLITE:-1}"
INSTALL_POSTGRES="${INSTALL_POSTGRES:-1}"
INSTALL_REDIS="${INSTALL_REDIS:-1}"
INSTALL_ELASTIC="${INSTALL_ELASTIC:-1}"
INSTALL_QDRANT="${INSTALL_QDRANT:-1}"
INSTALL_MISE_TOOLS="${INSTALL_MISE_TOOLS:-1}"

log() { printf '[install-all] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

install_sqlite() {
    local stage installed="$SQLITE_DIR/sqlite3"

    if [ -f "$installed" ]; then
        log "SQLite is already present; repairing executable permissions and verifying binaries..."
        run_root chmod 755 "$SQLITE_DIR/sqlite3" "$SQLITE_DIR/sqldiff" \
            "$SQLITE_DIR/sqlite3_analyzer" "$SQLITE_DIR/sqlite3_rsync"
        if "$installed" --version >/dev/null 2>&1; then
            log "SQLite: $("$installed" --version)"
            return
        fi
        log "The existing SQLite binaries do not run; reinstalling from the verified bundle..."
    fi

    [ -d "$SQLITE_SRC" ] || die "Missing $SQLITE_SRC"
    [ -f "$SQLITE_SRC/SHA256SUMS" ] || die "Missing $SQLITE_SRC/SHA256SUMS"

    log "Verifying stripped SQLite checksums..."
    (cd "$SQLITE_SRC" && sha256sum -c SHA256SUMS)

    if [ -d "$SQLITE_ORIGINAL_SRC" ]; then
        [ -f "$SQLITE_ORIGINAL_SRC/SHA256SUMS" ] || die "Missing $SQLITE_ORIGINAL_SRC/SHA256SUMS"
        log "Verifying original non-stripped SQLite build checksums..."
        (cd "$SQLITE_ORIGINAL_SRC" && sha256sum -c SHA256SUMS)
    fi

    mkdir -p "$SYSTEM_DIR"
    stage="$(mktemp -d "$SYSTEM_DIR/.sqlite3.XXXXXX")"
    cp -a "$SQLITE_SRC/." "$stage/"
    find "$stage" -type d -exec chmod 755 {} +
    chmod 755 "$stage/sqlite3" "$stage/sqldiff" "$stage/sqlite3_analyzer" "$stage/sqlite3_rsync"
    chmod 644 "$stage/SHA256SUMS" "$stage/BUILD-INFO.txt"

    rm -rf "$SQLITE_DIR.old"
    [ ! -e "$SQLITE_DIR" ] || mv "$SQLITE_DIR" "$SQLITE_DIR.old"
    if mv "$stage" "$SQLITE_DIR"; then
        rm -rf "$SQLITE_DIR.old"
    else
        rm -rf "$stage" "$SQLITE_DIR"
        [ ! -e "$SQLITE_DIR.old" ] || mv "$SQLITE_DIR.old" "$SQLITE_DIR"
        die "Unable to update SQLite; the previous version has been restored."
    fi

    cat > "$SYSTEM_DIR/run-sqlite3.sh" <<'EOF_SQLITE'
#!/usr/bin/env bash
SYSTEM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SYSTEM_DIR/sqlite3/sqlite3" "$@"
EOF_SQLITE
    chmod 755 "$SYSTEM_DIR/run-sqlite3.sh"
    log "SQLite: $("$SQLITE_DIR/sqlite3" --version)"
}

ensure_pg_data_dirs() {
    # Restore can drop empty cluster data subdirectories because Git/ZIP does not preserve empty directories.
    # Recreate the standard PostgreSQL directory set when missing so postgres can start correctly.
    local pg_user="$1" base="$2" data version subdir
    shopt -s nullglob
    for data in "$base"/pg_data_*; do
        [ -f "$data/PG_VERSION" ] || continue
        version="$(cat "$data/PG_VERSION")"
        for subdir in \
            pg_commit_ts pg_dynshmem pg_logical pg_logical/mappings pg_logical/snapshots \
            pg_multixact pg_multixact/members pg_multixact/offsets pg_notify pg_replslot \
            pg_serial pg_snapshots pg_stat pg_stat_tmp pg_subtrans pg_tblspc pg_twophase \
            pg_wal pg_wal/archive_status pg_xact; do
            if [ ! -d "$data/$subdir" ]; then
                # The cluster belongs to the service user after restore; mkdir/chown/chmod
                # must go through run_root so a non-root caller still fails closed.
                run_root mkdir -p "$data/$subdir"
                run_root chown "$pg_user:$pg_user" "$data/$subdir"
                run_root chmod 700 "$data/$subdir"
                log "Recreated PostgreSQL $version cluster data directory: $subdir"
            fi
        done
    done
    shopt -u nullglob
}

repair_soname_symlinks() {
    # After restoring /kaggle/working, soname symlinks (liburing.so.2 -> liburing.so.2.1.0,
    # libpq.so.5 -> libpq.so.5.18, ...) may be lost, preventing the loader from finding libraries.
    local runtime_dir f base soname link_path
    for runtime_dir in "$SYSTEM_DIR"/redis/runtime "$SYSTEM_DIR"/pg/runtime; do
        [ -d "$runtime_dir" ] || continue
        while IFS= read -r -d '' f; do
            base="$(basename "$f")"
            [[ "$base" =~ ^(lib.*\.so\.[0-9]+)\.[0-9.]+$ ]] || continue
            soname="${BASH_REMATCH[1]}"
            link_path="$(dirname "$f")/$soname"
            if [ -L "$link_path" ]; then
                [ -e "$link_path" ] || die "Broken soname symlink after restore: $link_path"
                continue
            fi
            [ ! -e "$link_path" ] || die "Refusing to overwrite a soname path that is not a symlink: $link_path"
            run_root ln -s "$base" "$link_path"
        done < <(find "$runtime_dir" -type f -name '*.so.*' -print0)
    done
}

main() {
    local pg_user="${POSTGRES_SERVICE_USER:-postgres}"

    mkdir -p "$SYSTEM_DIR"
    chmod 755 "$SYSTEM_DIR"

    if [ "$INSTALL_SQLITE" = "1" ]; then
        install_sqlite
    else
        log "Skipping SQLite."
    fi
    if [ "$INSTALL_POSTGRES" = "1" ]; then
        # Persisted PostgreSQL data may survive while required empty cluster
        # directories (for example pg_notify) disappear after cold restore.
        # Repair that structure before install-postgres.sh can inspect/start
        # the existing cluster.
        ensure_system_user "$pg_user" "$SYSTEM_DIR/pg"
        ensure_pg_data_dirs "$pg_user" "$SYSTEM_DIR/pg"
        bash "$SCRIPT_DIR/install-postgres.sh"
    else
        log "Skipping PostgreSQL."
    fi
    if [ "$INSTALL_REDIS" = "1" ]; then
        bash "$SCRIPT_DIR/install-redis.sh"
    else
        log "Skipping Redis."
    fi
    if [ "$INSTALL_ELASTIC" = "1" ]; then
        bash "$SCRIPT_DIR/install-elastic.sh"
    else
        log "Skipping Elastic Stack."
    fi
    if [ "$INSTALL_QDRANT" = "1" ]; then
        bash "$SCRIPT_DIR/install-qdrant.sh"
    else
        log "Skipping Qdrant."
    fi
    if [ "$INSTALL_MISE_TOOLS" = "1" ]; then
        bash "$SCRIPT_DIR/install-other.sh"
    else
        log "Skipping mise/toolchain."
    fi

    ensure_system_scripts_executable "$SYSTEM_DIR"
    repair_soname_symlinks
    ensure_pg_data_dirs "$pg_user" "$SYSTEM_DIR/pg"

    echo
    echo "================================================================="
    echo "✅ FULL INSTALLATION COMPLETED SUCCESSFULLY"
    echo "================================================================="
    find "$SYSTEM_DIR" -maxdepth 1 -type f -name '*.sh' -printf '  - %p\n' | sort
    echo
    [ -f "$SYSTEM_DIR/mise/env.sh" ] && echo "  Activate mise   : source $SYSTEM_DIR/mise/env.sh"
    [ -x "$PROJECT_ROOT/bin/kdev" ] && echo "  Unified CLI     : $PROJECT_ROOT/bin/kdev versions"
    [ -x "$SYSTEM_DIR/run-redis.sh" ] && echo "  Redis default   : bash $SYSTEM_DIR/run-redis.sh PING"
    [ -x "$SYSTEM_DIR/elastic-ctl.sh" ] && echo "  Elastic default : bash $SYSTEM_DIR/elastic-ctl.sh status all"
    [ -x "$SYSTEM_DIR/run-sqlite3.sh" ] && echo "  SQLite          : bash $SYSTEM_DIR/run-sqlite3.sh --version"
    echo "================================================================="
}

repair_qdrant_runtime_ownership() {
    # After Kaggle resets the VM/runtime, .system/qdrant may remain while the
    # service-user account is gone. QNP creates the user only during setup_env (install),
    # while a normal start refuses to proceed if the user does not exist. Bootstrap must
    # recreate the user and repair ownership of persisted state, even when the new UID/GID
    # differs from the previous UID/GID.
    local qdrant_user="$1" inst area

    shopt -s nullglob
    for inst in "$SYSTEM_DIR"/qdrant/instances/*/; do
        for area in storage snapshots logs tmp; do
            if [ -d "$inst$area" ]; then
                run_root chown -R "$qdrant_user:$qdrant_user" "$inst$area"
            fi
        done
        if [ -f "$inst/config/qdrant.yaml" ]; then
            run_root chown "root:$qdrant_user" "$inst/config/qdrant.yaml"
            run_root chmod 0640 "$inst/config/qdrant.yaml"
        fi
    done
    shopt -u nullglob
}

repair_qdrant_runtime_executables() {
    # QNP keeps the Qdrant binary outside generic bin/sbin paths. Kaggle cold
    # restore may preserve the payload while stripping its executable bit.
    local runtime_bin

    [ -d "$SYSTEM_DIR/qdrant/instances" ] || return 0
    while IFS= read -r -d '' runtime_bin; do
        run_root chmod 755 "$runtime_bin"
    done < <(find "$SYSTEM_DIR/qdrant/instances" -type f -path '*/qdrant-*/qdrant' -print0)
}


repair_elastic_bundled_jdk_executables() {
    # Elasticsearch ships a bundled JDK with executable helpers outside bin/.
    # Kaggle cold restore may strip their executable bits even when java and
    # the Elasticsearch launcher themselves have already been repaired.
    # Repair only the known JDK helpers required to execute/spawn processes;
    # never chmod the entire jdk/lib tree.
    local helper

    [ -d "$SYSTEM_DIR/elastic/versions" ] || return 0

    while IFS= read -r -d '' helper; do
        run_root chmod 755 "$helper"
    done < <(
        find "$SYSTEM_DIR/elastic/versions" -type f \
            \( \
                -path '*/runtime/elasticsearch/jdk/lib/jspawnhelper' -o \
                -path '*/runtime/elasticsearch/jdk/lib/jexec' \
            \) \
            -print0
    )
}

bootstrap() {
    init_privilege
    # Direct `bootstrap` retains its historical all-components repair behavior.
    # `restore` uses the internal selected scope so a disabled SQLite component
    # cannot trigger bootstrap's missing-runtime copy/install fallback.
    local scope="${1:-all}"
    local redis_user="${REDIS_SERVICE_USER:-redis}"
    local elastic_user="${ELASTIC_SERVICE_USER:-elastic}"
    local pg_user="${POSTGRES_SERVICE_USER:-postgres}"
    local dir runtime_bin

    run_root mkdir -p "$SYSTEM_DIR"
    run_root chown "$(id -u):$(id -g)" "$SYSTEM_DIR"
    run_root chmod 755 "$SYSTEM_DIR"

    log "Ensuring system users '$redis_user', '$pg_user', and '$elastic_user' exist..."
    ensure_system_user "$redis_user" "$SYSTEM_DIR/redis"
    ensure_system_user "$pg_user" "$SYSTEM_DIR/pg"
    ensure_system_user "$elastic_user" "$SYSTEM_DIR/elastic" /bin/bash
    if [ -d "$SYSTEM_DIR/qdrant" ]; then
        local qdrant_user="${QDRANT_SERVICE_USER:-qdrantuser}"
        if [ -f "$SYSTEM_DIR/qdrant/service-user" ]; then
            qdrant_user="$(tr -d '[:space:]' < "$SYSTEM_DIR/qdrant/service-user")"
        fi
        [ -n "$qdrant_user" ] || qdrant_user="qdrantuser"
        log "Ensuring system user '$qdrant_user' exists (Qdrant cold restore)..."
        ensure_system_user "$qdrant_user" "$SYSTEM_DIR/qdrant"
    fi

    log "Repairing executable permissions after restoring /kaggle/working..."
    ensure_system_scripts_executable "$SYSTEM_DIR"
    if [ "$scope" = "all" ] || [ "$INSTALL_SQLITE" = "1" ]; then
        if [ -f "$SQLITE_DIR/sqlite3" ]; then
            run_root chmod 755 "$SQLITE_DIR/sqlite3" "$SQLITE_DIR/sqldiff" \
                "$SQLITE_DIR/sqlite3_analyzer" "$SQLITE_DIR/sqlite3_rsync"
            if ! "$SQLITE_DIR/sqlite3" --version >/dev/null 2>&1; then
                log "The restored SQLite binary does not run; switching to a full installation..."
                install_sqlite
            fi
        else
            log "SQLite is missing; switching to a full installation..."
            install_sqlite
        fi
    fi
    while IFS= read -r -d '' runtime_bin; do
        run_root chmod 755 "$runtime_bin"
    done < <(find "$SYSTEM_DIR" -type f \( -path '*/bin/*' -o -path '*/sbin/*' \) -print0)
    repair_elastic_bundled_jdk_executables
    repair_qdrant_runtime_executables

    log "Restoring data/log/run ownership for service users..."
    if [ -d "$SYSTEM_DIR/redis/instances" ]; then
        while IFS= read -r -d '' dir; do
            run_root chown -R "$redis_user:$redis_user" "$dir"
        done < <(find "$SYSTEM_DIR/redis/instances" -mindepth 2 -maxdepth 2 -type d \
            \( -name data -o -name logs -o -name run \) -print0)
        while IFS= read -r -d '' dir; do
            run_root chmod 750 "$dir"
        done < <(find "$SYSTEM_DIR/redis/instances" -mindepth 2 -maxdepth 2 -type d -name data -print0)
    else
        for rdir in data logs run; do
            if [ -e "$SYSTEM_DIR/redis/$rdir" ]; then
                run_root chown -R "$redis_user:$redis_user" "$SYSTEM_DIR/redis/$rdir"
            fi
        done
        if [ -d "$SYSTEM_DIR/redis/data" ]; then
            run_root chmod 750 "$SYSTEM_DIR/redis/data"
        fi
    fi
    if [ -d "$SYSTEM_DIR/elastic/versions" ]; then
        while IFS= read -r -d '' dir; do
            run_root chown -R "$elastic_user:$elastic_user" "$dir"
        done < <(find "$SYSTEM_DIR/elastic/versions" -mindepth 2 -maxdepth 2 -type d \
            \( -name config -o -name data -o -name logs -o -name run -o -name home \) -print0)
    fi
    shopt -s nullglob
    for dir in "$SYSTEM_DIR"/pg/pg_data_* "$SYSTEM_DIR"/pg/pg_log_* "$SYSTEM_DIR"/pg/pg_run_*; do
        run_root chown -R "$pg_user:$pg_user" "$dir"
    done
    for dir in "$SYSTEM_DIR"/pg/pg_data_*; do
        if [ -d "$dir" ]; then
            run_root chmod 700 "$dir"
        fi
    done
    shopt -u nullglob

    if [ -d "$SYSTEM_DIR/qdrant" ]; then
        log "Repairing persisted Qdrant ownership for '$qdrant_user' after cold restore..."
        repair_qdrant_runtime_ownership "$qdrant_user"
    fi

    repair_soname_symlinks
    ensure_pg_data_dirs "$pg_user" "$SYSTEM_DIR/pg"

    log "Bootstrap complete: users, executable permissions, and ownership are ready."
}

restore() {
    # Repair recoverable cold-restore damage before installer fast-path probes.
    # Component installers still own exact-version validation and targeted fallback.
    bootstrap selected
    main
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    action="${1:-install}"
    case "$action" in
        install) main ;;
        bootstrap) bootstrap ;;
        restore) restore ;;
        *) echo "Usage: $0 [install|bootstrap|restore]" >&2; exit 2 ;;
    esac
fi
