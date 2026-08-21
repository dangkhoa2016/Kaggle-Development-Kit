#!/usr/bin/env bash
set -euo pipefail

# Cài toàn bộ SQLite + PostgreSQL + Redis + Elastic Stack + mise toolchain.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEM_DIR="$PROJECT_ROOT/.system"

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

    if [ -x "$installed" ] && "$installed" --version >/dev/null 2>&1; then
        log "SQLite đã có sẵn; chỉ sửa quyền thực thi..."
        chmod 755 "$SQLITE_DIR/sqlite3" "$SQLITE_DIR/sqldiff" \
            "$SQLITE_DIR/sqlite3_analyzer" "$SQLITE_DIR/sqlite3_rsync"
        log "SQLite: $("$installed" --version)"
        return
    fi

    [ -d "$SQLITE_SRC" ] || die "Không thấy $SQLITE_SRC"
    [ -f "$SQLITE_SRC/SHA256SUMS" ] || die "Thiếu $SQLITE_SRC/SHA256SUMS"

    log "Xác minh checksum SQLite stripped..."
    (cd "$SQLITE_SRC" && sha256sum -c SHA256SUMS)

    if [ -d "$SQLITE_ORIGINAL_SRC" ]; then
        [ -f "$SQLITE_ORIGINAL_SRC/SHA256SUMS" ] || die "Thiếu $SQLITE_ORIGINAL_SRC/SHA256SUMS"
        log "Xác minh checksum SQLite original non-stripped build..."
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
        die "Không thể cập nhật SQLite; bản cũ đã được khôi phục."
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
    # Restore làm mất các thư mục con rỗng trong data cluster (git/zip không lưu dir rỗng).
    # Tạo lại đúng bộ thư mục chuẩn của PostgreSQL nếu thiếu, kẻo postgres không khởi động được.
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
                mkdir -p "$data/$subdir"
                chown "$pg_user:$pg_user" "$data/$subdir"
                chmod 700 "$data/$subdir"
                log "Đã tạo lại thư mục data cluster $version: $subdir"
            fi
        done
    done
    shopt -u nullglob
}

repair_soname_symlinks() {
    # Sau khi restore /kaggle/working, các symlink soname (liburing.so.2 -> liburing.so.2.1.0,
    # libpq.so.5 -> libpq.so.5.18, ...) có thể bị mất khiến loader không tìm thấy thư viện.
    local runtime_dir f base soname
    for runtime_dir in "$SYSTEM_DIR"/redis/runtime "$SYSTEM_DIR"/pg/runtime; do
        [ -d "$runtime_dir" ] || continue
        while IFS= read -r -d '' f; do
            base="$(basename "$f")"
            [[ "$base" =~ ^(lib.*\.so\.[0-9]+)\.[0-9.]+$ ]] || continue
            soname="${BASH_REMATCH[1]}"
            [ -e "$(dirname "$f")/$soname" ] || ln -s "$base" "$(dirname "$f")/$soname"
        done < <(find "$runtime_dir" -type f -name '*.so.*' -print0)
    done
}

main() {
    mkdir -p "$SYSTEM_DIR"
    chmod 755 "$SYSTEM_DIR"

    [ "$INSTALL_SQLITE" = "1" ] && install_sqlite || log "Bỏ qua SQLite."
    [ "$INSTALL_POSTGRES" = "1" ] && bash "$SCRIPT_DIR/install-postgres.sh" || log "Bỏ qua PostgreSQL."
    [ "$INSTALL_REDIS" = "1" ] && bash "$SCRIPT_DIR/install-redis.sh" || log "Bỏ qua Redis."
    [ "$INSTALL_ELASTIC" = "1" ] && bash "$SCRIPT_DIR/install-elastic.sh" || log "Bỏ qua Elastic Stack."
    [ "$INSTALL_QDRANT" = "1" ] && bash "$SCRIPT_DIR/install-qdrant.sh" || log "Bỏ qua Qdrant."
    [ "$INSTALL_MISE_TOOLS" = "1" ] && bash "$SCRIPT_DIR/install-other.sh" || log "Bỏ qua mise/toolchain."

    ensure_system_scripts_executable "$SYSTEM_DIR"
    repair_soname_symlinks
    ensure_pg_data_dirs "${POSTGRES_SERVICE_USER:-postgres}" "$SYSTEM_DIR/pg"

    echo
    echo "================================================================="
    echo "✅ CÀI ĐẶT TOÀN BỘ THÀNH CÔNG"
    echo "================================================================="
    find "$SYSTEM_DIR" -maxdepth 1 -type f -name '*.sh' -printf '  - %p\n' | sort
    echo
    [ -f "$SYSTEM_DIR/mise/env.sh" ] && echo "  Kích hoạt mise : source $SYSTEM_DIR/mise/env.sh"
    [ -x "$PROJECT_ROOT/bin/kdev" ] && echo "  Unified CLI     : $PROJECT_ROOT/bin/kdev versions"
    [ -x "$SYSTEM_DIR/run-redis.sh" ] && echo "  Redis default   : bash $SYSTEM_DIR/run-redis.sh PING"
    [ -x "$SYSTEM_DIR/elastic-ctl.sh" ] && echo "  Elastic default : bash $SYSTEM_DIR/elastic-ctl.sh status all"
    [ -x "$SYSTEM_DIR/run-sqlite3.sh" ] && echo "  SQLite          : bash $SYSTEM_DIR/run-sqlite3.sh --version"
    echo "================================================================="
}

bootstrap() {
    local redis_user="${REDIS_SERVICE_USER:-redis}"
    local elastic_user="${ELASTIC_SERVICE_USER:-elastic}"
    local pg_user="${POSTGRES_SERVICE_USER:-postgres}"
    local dir

    mkdir -p "$SYSTEM_DIR"
    chmod 755 "$SYSTEM_DIR"

    log "Đảm bảo system users '$redis_user', '$pg_user', '$elastic_user' tồn tại..."
    ensure_system_user "$redis_user" "$SYSTEM_DIR/redis"
    ensure_system_user "$pg_user" "$SYSTEM_DIR/pg"
    ensure_system_user "$elastic_user" "$SYSTEM_DIR/elastic" /bin/bash

    log "Sửa quyền thực thi sau khi restore /kaggle/working..."
    ensure_system_scripts_executable "$SYSTEM_DIR"
    if [ -x "$SQLITE_DIR/sqlite3" ]; then
        chmod 755 "$SQLITE_DIR/sqlite3" "$SQLITE_DIR/sqldiff" \
            "$SQLITE_DIR/sqlite3_analyzer" "$SQLITE_DIR/sqlite3_rsync"
    else
        log "Thiếu SQLite; chuyển sang cài đặt đầy đủ..."
        install_sqlite
    fi
    find "$SYSTEM_DIR" -type f \( -path '*/bin/*' -o -path '*/sbin/*' \) -exec chmod 755 {} +

    log "Khôi phục ownership data/log/run cho user service..."
    if [ -d "$SYSTEM_DIR/redis/instances" ]; then
        find "$SYSTEM_DIR/redis/instances" -mindepth 2 -maxdepth 2 -type d \
            \( -name data -o -name logs -o -name run \) -exec chown -R "$redis_user:$redis_user" {} + 2>/dev/null || true
        find "$SYSTEM_DIR/redis/instances" -mindepth 2 -maxdepth 2 -type d -name data -exec chmod 750 {} + 2>/dev/null || true
    else
        chown -R "$redis_user:$redis_user" "$SYSTEM_DIR/redis/data" "$SYSTEM_DIR/redis/logs" "$SYSTEM_DIR/redis/run" 2>/dev/null || true
        chmod 750 "$SYSTEM_DIR/redis/data" 2>/dev/null || true
    fi
    if [ -d "$SYSTEM_DIR/elastic/versions" ]; then
        find "$SYSTEM_DIR/elastic/versions" -mindepth 2 -maxdepth 2 -type d \
            \( -name config -o -name data -o -name logs -o -name run -o -name home \) \
            -exec chown -R "$elastic_user:$elastic_user" {} + 2>/dev/null || true
    fi
    shopt -s nullglob
    for dir in "$SYSTEM_DIR"/pg/pg_data_* "$SYSTEM_DIR"/pg/pg_log_* "$SYSTEM_DIR"/pg/pg_run_*; do
        chown -R "$pg_user:$pg_user" "$dir" 2>/dev/null || true
    done
    shopt -u nullglob
    chmod 700 "$SYSTEM_DIR"/pg/pg_data_* 2>/dev/null || true

    repair_soname_symlinks
    ensure_pg_data_dirs "$pg_user" "$SYSTEM_DIR/pg"

    log "Bootstrap hoàn tất: users, quyền thực thi, ownership đã sẵn sàng."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    action="${1:-install}"
    case "$action" in
        install) main ;;
        bootstrap) bootstrap ;;
        *) echo "Dùng: $0 [install|bootstrap]" >&2; exit 2 ;;
    esac
fi
