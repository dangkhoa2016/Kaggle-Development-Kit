#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for `install-all.sh install`:
# - enabled component failures must propagate without a false success banner;
# - a cold-restored PostgreSQL cluster must have required empty directories
#   recreated before the PostgreSQL component installer is invoked.
#
# The historical dispatch used the unsafe AND/OR idiom:
#
#   [ "$INSTALL_QDRANT" = "1" ] && bash ".../install-qdrant.sh" || log "Skipping Qdrant."
#
# When an enabled installer exits non-zero, `log` succeeds, so the whole
# AND/OR list returns success, `set -e` does not stop it, later components
# keep running, and the global success banner prints even though the install
# is broken. Dispatch must use explicit if/else blocks and propagate the
# exact non-zero status of a failed enabled installer.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

BANNER='FULL INSTALLATION COMPLETED SUCCESSFULLY'

make_component() {
    # $1 = project dir; $2 = component script name; $3 = exit code
    cat > "$1/install/$2" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$2' >> "\${KDEV_TEST_CALLS_LOG:?}"
exit $3
EOF
}

make_project() {
    # Real orchestrator + shared libs, fake per-service installers. The repo
    # defaults hard-enable every INSTALL_* toggle, so the fixture ships a
    # minimal defaults file and drives component selection via environment.
    local proj="$1"
    mkdir -p "$proj/install/lib" "$proj/config"
    cp "$ROOT/install/install-all.sh" "$proj/install/"
    cp "$ROOT/install/lib/common.sh" "$proj/install/lib/"
    cp "$ROOT/install/lib/load-config.sh" "$proj/install/lib/"
    printf '%s\n' '# fixture defaults: component toggles come from the test environment' \
        > "$proj/config/defaults.env"
    make_component "$proj" install-postgres.sh 0
    make_component "$proj" install-redis.sh 0
    make_component "$proj" install-elastic.sh 0
    make_component "$proj" install-qdrant.sh 0
    make_component "$proj" install-other.sh 0
}

run_install() {
    # $1 = project dir; remaining args = INSTALL_* KEY=VALUE overrides.
    local proj="$1"; shift
    CALLS_LOG="$TMP/calls.$RANDOM.log"
    OUT_LOG="$TMP/out.$RANDOM.log"
    : > "$CALLS_LOG"
    rc=0
    (
        export KDEV_TEST_CALLS_LOG="$CALLS_LOG"
        cd /
        env "$@" bash "$proj/install/install-all.sh"
    ) > "$OUT_LOG" 2>&1 || rc=$?
}

# --- Scenario 1: disabled components are skipped, orchestration continues ----
PROJ1="$TMP/proj1"
make_project "$PROJ1"

run_install "$PROJ1" \
    INSTALL_SQLITE=0 INSTALL_POSTGRES=0 INSTALL_REDIS=0 \
    INSTALL_ELASTIC=0 INSTALL_QDRANT=0 INSTALL_MISE_TOOLS=0

[ "$rc" -eq 0 ] || fail "skip-only install exited $rc (log: $OUT_LOG)"
grep -qF "$BANNER" "$OUT_LOG" || fail "success banner missing for skip-only install"
[ ! -s "$CALLS_LOG" ] || fail "disabled components were executed: $(cat "$CALLS_LOG")"
grep -q 'Skipping PostgreSQL' "$OUT_LOG" || fail "PostgreSQL skip was not logged"

# --- Scenario 2: enabled installer failure propagates exactly ----------------
PROJ2="$TMP/proj2"
make_project "$PROJ2"
cat > "$PROJ2/install/install-qdrant.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' 'install-qdrant.sh' >> "\${KDEV_TEST_CALLS_LOG:?}"
exit 42
EOF

run_install "$PROJ2" \
    INSTALL_SQLITE=0 INSTALL_POSTGRES=0 INSTALL_REDIS=0 \
    INSTALL_ELASTIC=1 INSTALL_QDRANT=1 INSTALL_MISE_TOOLS=1

[ "$rc" -ne 0 ] ||
  fail "install succeeded despite failing enabled component qdrant (log: $OUT_LOG)"
[ "$rc" -eq 42 ] ||
  fail "component failure was not propagated verbatim (expected 42, got $rc)"
! grep -qF "$BANNER" "$OUT_LOG" ||
  fail "global success banner printed despite failed component (log: $OUT_LOG)"
grep -qx 'install-elastic.sh' "$CALLS_LOG" ||
  fail "elastic should have run before the failing qdrant component"
grep -qx 'install-qdrant.sh' "$CALLS_LOG" ||
  fail "fixture did not exercise the failing qdrant component (harness broken)"
! grep -qx 'install-other.sh' "$CALLS_LOG" ||
  fail "mise/toolchain ran after a failed component; install cannot be treated as complete"

# --- Scenario 3: PostgreSQL cold-restore repair precedes installer invocation -
PROJ3="$TMP/proj3"
SYS3="$TMP/system3"
BIN3="$TMP/bin3"
make_project "$PROJ3"
mkdir -p "$SYS3/pg/pg_data_18/pg_wal" "$BIN3"
printf '%s\n' '18' > "$SYS3/pg/pg_data_18/PG_VERSION"

cat > "$BIN3/id" <<'EOF_ID3'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '0\n'; exit 0 ;;
  postgres) exit 0 ;;
esac
exec /usr/bin/id "$@"
EOF_ID3

cat > "$BIN3/chown" <<'EOF_CHOWN3'
#!/usr/bin/env bash
exit 0
EOF_CHOWN3
chmod +x "$BIN3/id" "$BIN3/chown"

cat > "$PROJ3/install/install-postgres.sh" <<'EOF_PG3'
#!/usr/bin/env bash
set -euo pipefail
data="${KAGGLE_SYSTEM_DIR:?}/pg/pg_data_18"
for dir in \
  pg_notify \
  pg_logical/mappings \
  pg_logical/snapshots \
  pg_multixact/members \
  pg_multixact/offsets \
  pg_wal/archive_status \
  pg_xact; do
    [ -d "$data/$dir" ] || {
      printf 'missing required PostgreSQL cold-restore directory before installer: %s\n' "$dir" >&2
      exit 43
    }
done
printf '%s\n' 'install-postgres.sh' >> "${KDEV_TEST_CALLS_LOG:?}"
EOF_PG3
chmod +x "$PROJ3/install/install-postgres.sh"

run_install "$PROJ3" \
  PATH="$BIN3:$PATH" \
  KAGGLE_SYSTEM_DIR="$SYS3" \
  POSTGRES_SERVICE_USER=postgres \
  INSTALL_SQLITE=0 INSTALL_POSTGRES=1 INSTALL_REDIS=0 \
  INSTALL_ELASTIC=0 INSTALL_QDRANT=0 INSTALL_MISE_TOOLS=0

[ "$rc" -eq 0 ] ||
  fail "cold-restored PostgreSQL structure was not repaired before installer invocation (rc=$rc; log: $OUT_LOG)"
grep -qx 'install-postgres.sh' "$CALLS_LOG" ||
  fail "PostgreSQL installer did not run after cold-restore preflight"

for dir in \
  pg_notify \
  pg_logical/mappings \
  pg_logical/snapshots \
  pg_multixact/members \
  pg_multixact/offsets \
  pg_wal/archive_status \
  pg_xact; do
    [ -d "$SYS3/pg/pg_data_18/$dir" ] ||
      fail "cold-restore preflight did not recreate $dir"
done

echo 'PASS: install-all.sh dispatch propagates failures, skips cleanly, and preflights PostgreSQL cold restore'
