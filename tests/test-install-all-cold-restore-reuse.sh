#!/usr/bin/env bash
set -euo pipefail

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

make_project() {
    local proj="$1"
    mkdir -p "$proj/install/lib" "$proj/config"
    cp "$ROOT/install/install-all.sh" "$proj/install/"
    cp "$ROOT/install/lib/common.sh" "$proj/install/lib/"
    cp "$ROOT/install/lib/load-config.sh" "$proj/install/lib/"
    printf '# restore-reuse fixture\n' > "$proj/config/defaults.env"
}

write_ok_script() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
}

write_persisted_sqlite() {
    local system="$1" tool
    mkdir -p "$system/sqlite3"
    for tool in sqlite3 sqldiff sqlite3_analyzer sqlite3_rsync; do
        write_ok_script "$system/sqlite3/$tool"
        chmod 0644 "$system/sqlite3/$tool"
    done
}

make_probe_installer() {
    # $1 project, $2 script name, $3 probe path, $4 label, $5 call log
    local proj="$1" script="$2" probe="$3" label="$4" calls="$5"
    cat > "$proj/install/$script" <<EOF_SCRIPT
#!/usr/bin/env bash
set -euo pipefail
if [ ! -x '$probe' ]; then
    printf 'NETWORK_OR_BUILD %s\n' '$label' >> '$calls'
    exit 90
fi
printf 'REUSED %s\n' '$label' >> '$calls'
EOF_SCRIPT
    chmod +x "$proj/install/$script"
}

# Scenario A: restore is selection-aware. A fresh project with SQLite disabled
# must not fall through bootstrap's normal missing-SQLite install path.
PROJ_A="$TMP/proj-a"
SYSTEM_A="$TMP/system-a"
CALLS_A="$TMP/calls-a.log"
make_project "$PROJ_A"
: > "$CALLS_A"
for script in install-postgres.sh install-redis.sh install-elastic.sh install-qdrant.sh install-other.sh; do
    cat > "$PROJ_A/install/$script" <<EOF_SCRIPT
#!/usr/bin/env bash
printf '%s\n' '$script' >> '$CALLS_A'
exit 99
EOF_SCRIPT
    chmod +x "$PROJ_A/install/$script"
done

rc=0
KAGGLE_SYSTEM_DIR="$SYSTEM_A" \
INSTALL_SQLITE=0 INSTALL_POSTGRES=0 INSTALL_REDIS=0 INSTALL_ELASTIC=0 \
INSTALL_QDRANT=0 INSTALL_MISE_TOOLS=0 \
POSTGRES_SERVICE_USER=root REDIS_SERVICE_USER=root ELASTIC_SERVICE_USER=root QDRANT_SERVICE_USER=root \
    bash "$PROJ_A/install/install-all.sh" restore >"$TMP/a.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "selection-aware restore exited $rc: $(cat "$TMP/a.log")"
[ ! -s "$CALLS_A" ] || fail "disabled component installer ran: $(cat "$CALLS_A")"
[ ! -e "$SYSTEM_A/sqlite3" ] || fail 'disabled SQLite unexpectedly created runtime state'
[ "$(stat -c %u "$SYSTEM_A")" -eq "$(id -u)" ] || \
    fail "restore left top-level SYSTEM_DIR owned by uid $(stat -c %u "$SYSTEM_A"), expected invoking uid $(id -u)"

# Scenario B: persisted runtimes survive but executable bits are stripped.
# The repair phase must make every probe healthy before component installers run.
PROJ_B="$TMP/proj-b"
SYSTEM_B="$TMP/system-b"
CALLS_B="$TMP/calls-b.log"
make_project "$PROJ_B"
: > "$CALLS_B"
write_persisted_sqlite "$SYSTEM_B"

PG_BIN="$SYSTEM_B/pg/runtime/usr/lib/postgresql/18/bin/initdb"
REDIS_BIN="$SYSTEM_B/redis/versions/8.10.0/bin/redis-server"
ES_BIN="$SYSTEM_B/elastic/versions/9.5.0/runtime/elasticsearch/bin/elasticsearch"
ES_JSPAWNHELPER="$SYSTEM_B/elastic/versions/9.5.0/runtime/elasticsearch/jdk/lib/jspawnhelper"
ES_JEXEC="$SYSTEM_B/elastic/versions/9.5.0/runtime/elasticsearch/jdk/lib/jexec"
QDRANT_BIN="$SYSTEM_B/qdrant/instances/1.18.3/qdrant-1.18.3/qdrant"
for path in "$PG_BIN" "$REDIS_BIN" "$ES_BIN" "$ES_JSPAWNHELPER" "$ES_JEXEC" "$QDRANT_BIN"; do
    write_ok_script "$path"
    chmod 0644 "$path"
done

make_probe_installer "$PROJ_B" install-postgres.sh "$PG_BIN" postgres "$CALLS_B"
make_probe_installer "$PROJ_B" install-redis.sh "$REDIS_BIN" redis "$CALLS_B"
make_probe_installer "$PROJ_B" install-elastic.sh "$ES_BIN" elastic "$CALLS_B"
make_probe_installer "$PROJ_B" install-qdrant.sh "$QDRANT_BIN" qdrant "$CALLS_B"
printf '#!/usr/bin/env bash\nexit 0\n' > "$PROJ_B/install/install-other.sh"
chmod +x "$PROJ_B/install/install-other.sh"

rc=0
KAGGLE_SYSTEM_DIR="$SYSTEM_B" \
INSTALL_SQLITE=1 INSTALL_POSTGRES=1 INSTALL_REDIS=1 INSTALL_ELASTIC=1 \
INSTALL_QDRANT=1 INSTALL_MISE_TOOLS=0 \
POSTGRES_SERVICE_USER=root REDIS_SERVICE_USER=root ELASTIC_SERVICE_USER=root QDRANT_SERVICE_USER=root \
    bash "$PROJ_B/install/install-all.sh" restore >"$TMP/b.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "cold-restore reuse exited $rc: $(cat "$TMP/b.log")"
! grep -q '^NETWORK_OR_BUILD ' "$CALLS_B" || fail "healthy restore reached fallback: $(cat "$CALLS_B")"
for label in postgres redis elastic qdrant; do
    grep -qx "REUSED $label" "$CALLS_B" || fail "$label runtime was not reused"
done
for path in "$PG_BIN" "$REDIS_BIN" "$ES_BIN" "$QDRANT_BIN"; do
    [ -x "$path" ] || fail "restore did not repair executable bit: $path"
done

for path in "$ES_JSPAWNHELPER" "$ES_JEXEC"; do
    [ -x "$path" ] || fail "restore did not repair bundled JDK helper executable: $path"
done

# Scenario C: one genuinely missing runtime gets targeted recovery while the
# other healthy components remain reusable/offline.
rm -f "$REDIS_BIN"
: > "$CALLS_B"
cat > "$PROJ_B/install/install-redis.sh" <<EOF_REDIS
#!/usr/bin/env bash
set -euo pipefail
if [ -e '$REDIS_BIN' ]; then
    printf 'REUSED redis\n' >> '$CALLS_B'
    exit 0
fi
printf 'TARGETED_DOWNLOAD redis\n' >> '$CALLS_B'
mkdir -p '$(dirname "$REDIS_BIN")'
printf '#!/usr/bin/env bash\nexit 0\n' > '$REDIS_BIN'
chmod 0755 '$REDIS_BIN'
EOF_REDIS
chmod +x "$PROJ_B/install/install-redis.sh"

rc=0
KAGGLE_SYSTEM_DIR="$SYSTEM_B" \
INSTALL_SQLITE=1 INSTALL_POSTGRES=1 INSTALL_REDIS=1 INSTALL_ELASTIC=1 \
INSTALL_QDRANT=1 INSTALL_MISE_TOOLS=0 \
POSTGRES_SERVICE_USER=root REDIS_SERVICE_USER=root ELASTIC_SERVICE_USER=root QDRANT_SERVICE_USER=root \
    bash "$PROJ_B/install/install-all.sh" restore >"$TMP/c.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "targeted restore exited $rc: $(cat "$TMP/c.log")"
grep -qx 'TARGETED_DOWNLOAD redis' "$CALLS_B" || fail 'missing Redis did not receive targeted recovery'
[ "$(grep -c '^TARGETED_DOWNLOAD ' "$CALLS_B")" -eq 1 ] || fail "recovery was not targeted: $(cat "$CALLS_B")"
for label in postgres elastic qdrant; do
    grep -qx "REUSED $label" "$CALLS_B" || fail "$label was not reused during Redis recovery"
done

# Scenario D: restore orchestration must not swallow an explicit force-refresh
# override owned by a component installer.
: > "$CALLS_B"
cat > "$PROJ_B/install/install-redis.sh" <<EOF_FORCE
#!/usr/bin/env bash
set -euo pipefail
if [ "\${REDIS_FORCE_RUNTIME_REFRESH:-0}" = 1 ]; then
    printf 'FORCE_REFRESH redis\n' >> '$CALLS_B'
else
    printf 'REUSED redis\n' >> '$CALLS_B'
fi
EOF_FORCE
chmod +x "$PROJ_B/install/install-redis.sh"

rc=0
KAGGLE_SYSTEM_DIR="$SYSTEM_B" \
INSTALL_SQLITE=1 INSTALL_POSTGRES=0 INSTALL_REDIS=1 INSTALL_ELASTIC=0 \
INSTALL_QDRANT=0 INSTALL_MISE_TOOLS=0 REDIS_FORCE_RUNTIME_REFRESH=1 \
POSTGRES_SERVICE_USER=root REDIS_SERVICE_USER=root ELASTIC_SERVICE_USER=root QDRANT_SERVICE_USER=root \
    bash "$PROJ_B/install/install-all.sh" restore >"$TMP/d.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "force-refresh restore exited $rc: $(cat "$TMP/d.log")"
grep -qx 'FORCE_REFRESH redis' "$CALLS_B" || fail 'restore swallowed REDIS_FORCE_RUNTIME_REFRESH=1'

echo 'PASS: restore is selection-aware, repairs/reuses persisted runtimes, targets missing components, and preserves force refresh'
