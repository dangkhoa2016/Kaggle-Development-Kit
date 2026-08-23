#!/usr/bin/env bash
set -euo pipefail

# Regression: bootstrap privileged repair must be privilege-aware and fail-closed.
#
# Four invariants are proven deterministically (no host account changes):
#
# 1. Fail-closed: when a required ownership repair fails, bootstrap must not
#    report success. The old implementation ran `chown ... 2>/dev/null || true`
#    so a stale-ownership tree silently survived until `bin/kdev qdrant start`
#    failed much later.
#
# 2. Privilege routing (Qdrant): when the caller is non-root but sudo-capable,
#    every privileged ownership repair must route through run_root/sudo. Direct
#    chown calls by the unprivileged caller cannot repair foreign-owned files.
#
# 3. Privilege routing (PostgreSQL restore): recreating the empty directories
#    a cold-restored PostgreSQL data cluster loses (git/zip do not store empty
#    dirs) requires mkdir+chown+chmod inside the service-user-owned cluster,
#    so those operations must also route through run_root/sudo instead of
#    failing against a root/postgres-owned restored tree.
#
# 4. Privilege completeness: restored root-owned control scripts, SQLite tools,
#    runtime bin/sbin executables, the system root mode, and missing soname
#    symlinks must all be repaired via run_root/sudo for a non-root caller.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

QDRANT_USER="qdrantuser"

# Shared fixture: persisted cold-restored Qdrant state inside a custom system dir.
make_fixture() {
    local sys="$1"
    local inst="$sys/qdrant/instances/1.18.3"
    mkdir -p "$inst/config" "$inst/storage/collections" "$inst/snapshots" \
             "$inst/logs" "$inst/tmp" "$sys/sqlite3" "$sys/pg" \
             "$sys/redis" "$sys/elastic"
    printf '%s\n' "$QDRANT_USER" > "$sys/qdrant/service-user"
    printf '%s\n' '1.18.3' > "$sys/qdrant/default-version"
    for tool in sqlite3 sqldiff sqlite3_analyzer sqlite3_rsync; do
        printf '#!/usr/bin/env sh\nexit 0\n' > "$sys/sqlite3/$tool"
        chmod 0755 "$sys/sqlite3/$tool"
    done
    printf 'service:\n  host: 127.0.0.1\n' > "$inst/config/qdrant.yaml"
    chmod 0640 "$inst/config/qdrant.yaml"
}

# Cold-restored PostgreSQL cluster: PG_VERSION survives, empty standard
# subdirectories are lost. Only pg_wal is present so the repair loop must
# recreate the remaining canonical set.
make_pg_tree() {
    local sys="$1"
    mkdir -p "$sys/pg/pg_data_18/pg_wal"
    printf '%s\n' '18' > "$sys/pg/pg_data_18/PG_VERSION"
}

make_account_stubs() {
    # $1 = fake bin dir; id always reports root so init_privilege takes the root path.
    local bin="$1"
    : > "$STATE/passwd"
    cat > "$bin/id" <<EOF_ID
#!/usr/bin/env bash
if [ "\${1:-}" = "-u" ]; then printf '0\n'; exit 0; fi
if [ "\${1:-}" = "-un" ]; then exec /usr/bin/id -un; fi
for arg in "\$@"; do
  if grep -qxF "\$arg" "$STATE/passwd" 2>/dev/null; then exit 0; fi
done
exit 1
EOF_ID
    cat > "$bin/getent" <<EOF_GETENT
#!/usr/bin/env bash
if [ "\${1:-}" = group ]; then
  grep -qxF "\$2" "$STATE/passwd" 2>/dev/null && exit 0
  exit 2
fi
exec /usr/bin/getent "\$@"
EOF_GETENT
    cat > "$bin/useradd" <<EOF_USERADD
#!/usr/bin/env bash
name=""
prev=""
for arg in "\$@"; do
  [ "\$prev" = "--gid" ] && { prev=""; continue; }
  prev="\$arg"
  case "\$arg" in --*) continue ;; esac
  name="\$arg"
done
printf '%s\n' "\$name" >> "$STATE/passwd"
EOF_USERADD
    chmod +x "$bin/id" "$bin/getent" "$bin/useradd"
}

make_nonroot_id_stub() {
    # $1 = fake bin dir; overrides id to report uid 1000 / kdev-tester.
    local bin="$1"
    cat > "$bin/id" <<EOF_ID
#!/usr/bin/env bash
if [ "\${1:-}" = "-u" ]; then printf '1000\n'; exit 0; fi
if [ "\${1:-}" = "-un" ]; then printf 'kdev-tester\n'; exit 0; fi
for arg in "\$@"; do
  if grep -qxF "\$arg" "$STATE/passwd" 2>/dev/null; then exit 0; fi
done
exit 1
EOF_ID
    chmod +x "$bin/id"
}

make_sudo_stub() {
    # $1 = fake bin dir; $2 = sudo log. Records wrapped invocations, then runs.
    cat > "$1/sudo" <<EOF_SUDO
#!/usr/bin/env bash
if [ "\${1:-}" = "-n" ] && [ "\${2:-}" = "true" ]; then exit 0; fi
printf '%s\n' "sudo \$*" >> "$2"
exec "\$@"
EOF_SUDO
    chmod +x "$1/sudo"
}

# --- Scenario 1: failing chown must fail bootstrap (fail-closed) -------------
BIN1="$TMP/bin1"; STATE="$TMP/state1"; SYS1="$TMP/system1"
mkdir -p "$BIN1" "$STATE"
make_account_stubs "$BIN1"

cat > "$BIN1/chown" <<EOF_CHOWN1
#!/usr/bin/env bash
printf '%s\n' "chown \$*" >> "$STATE/chown.log"
exit 1
EOF_CHOWN1
chmod +x "$BIN1/chown"

make_fixture "$SYS1"

rc=0
PATH="$BIN1:$PATH" KAGGLE_SYSTEM_DIR="$SYS1" \
  bash "$ROOT/install/install-all.sh" bootstrap >"$TMP/boot1.log" 2>&1 || rc=$?

[ "$rc" -ne 0 ] ||
  fail "bootstrap reported success while required ownership repairs failed (log: $TMP/boot1.log)"

grep -q '^chown ' "$STATE/chown.log" ||
  fail "test fixture did not exercise any chown repair (harness broken)"

# --- Scenario 2: non-root + sudo caller must route repairs through run_root --
BIN2="$TMP/bin2"; STATE="$TMP/state2"; SYS2="$TMP/system2"; SUDO_LOG="$TMP/sudo.log"
mkdir -p "$BIN2" "$STATE"
make_account_stubs "$BIN2"
make_nonroot_id_stub "$BIN2"
make_sudo_stub "$BIN2" "$SUDO_LOG"

cat > "$BIN2/chown" <<EOF_CHOWN2
#!/usr/bin/env bash
printf '%s\n' "chown \$*" >> "$STATE/chown.log"
exit 0
EOF_CHOWN2
chmod +x "$BIN2/id" "$BIN2/sudo" "$BIN2/chown"

make_fixture "$SYS2"

PATH="$BIN2:$PATH" KAGGLE_SYSTEM_DIR="$SYS2" \
  bash "$ROOT/install/install-all.sh" bootstrap >"$TMP/boot2.log" 2>&1 ||
  fail "bootstrap crashed for non-root+sudo caller (log: $TMP/boot2.log)"

grep -qE "^chown .*$QDRANT_USER" "$STATE/chown.log" ||
  fail "fixture did not record qdrant ownership repairs (harness broken)"

while IFS= read -r line; do
    grep -qF -- "sudo $line" "$SUDO_LOG" ||
      fail "ownership repair did not route through sudo/run_root: $line"
done < "$STATE/chown.log"

# --- Scenario 3: PostgreSQL empty-dir restore routes through run_root --------
BIN3="$TMP/bin3"; STATE="$TMP/state3"; SYS3="$TMP/system3"
SUDO_LOG3="$TMP/sudo3.log"; OPS_LOG="$TMP/ops3.log"
mkdir -p "$BIN3" "$STATE"
make_account_stubs "$BIN3"
make_nonroot_id_stub "$BIN3"
make_sudo_stub "$BIN3" "$SUDO_LOG3"

for op in mkdir chown chmod; do
    cat > "$BIN3/$op" <<EOF_OP3
#!/usr/bin/env bash
printf '%s\n' "$op \$*" >> "$OPS_LOG"
exit 0
EOF_OP3
    chmod +x "$BIN3/$op"
done

make_fixture "$SYS3"
make_pg_tree "$SYS3"

PATH="$BIN3:$PATH" KAGGLE_SYSTEM_DIR="$SYS3" \
  bash "$ROOT/install/install-all.sh" bootstrap >"$TMP/boot3.log" 2>&1 ||
  fail "bootstrap crashed for non-root+sudo PostgreSQL restore (log: $TMP/boot3.log)"

grep -q '^mkdir -p .*pg/pg_data_18/' "$OPS_LOG" ||
  fail "fixture did not exercise PostgreSQL directory recreation (harness broken)"
grep -E '^sudo chmod 700 .*pg/pg_data_18/' "$SUDO_LOG3" >/dev/null ||
  fail "recreated PostgreSQL directories did not receive mode 0700 via run_root"

while IFS= read -r line; do
    case "$line" in *'/pg/pg_data_'*)
        grep -qF -- "sudo $line" "$SUDO_LOG3" ||
          fail "PostgreSQL cluster repair bypassed sudo/run_root: $line"
    ;; esac
done < "$OPS_LOG"

# --- Scenario 4: remaining restore mutations are privilege-complete ----------
BIN4="$TMP/bin4"; STATE="$TMP/state4"; SYS4="$TMP/system4"
SUDO_LOG4="$TMP/sudo4.log"; OPS_LOG4="$TMP/ops4.log"
mkdir -p "$BIN4" "$STATE"
make_account_stubs "$BIN4"
make_nonroot_id_stub "$BIN4"
make_sudo_stub "$BIN4" "$SUDO_LOG4"

cat > "$BIN4/chown" <<EOF_CHOWN4
#!/usr/bin/env bash
printf '%s\n' "chown \$*" >> "$OPS_LOG4"
exit 0
EOF_CHOWN4
cat > "$BIN4/chmod" <<EOF_CHMOD4
#!/usr/bin/env bash
printf '%s\n' "chmod \$*" >> "$OPS_LOG4"
exec /usr/bin/chmod "\$@"
EOF_CHMOD4
cat > "$BIN4/ln" <<EOF_LN4
#!/usr/bin/env bash
printf '%s\n' "ln \$*" >> "$OPS_LOG4"
exec /usr/bin/ln "\$@"
EOF_LN4
chmod +x "$BIN4/chown" "$BIN4/chmod" "$BIN4/ln"

make_fixture "$SYS4"
printf '#!/usr/bin/env sh\nexit 0\n' > "$SYS4/restore-helper.sh"
chmod 0700 "$SYS4/restore-helper.sh"
chmod 0700 "$SYS4/sqlite3/sqlite3" "$SYS4/sqlite3/sqldiff" \
    "$SYS4/sqlite3/sqlite3_analyzer" "$SYS4/sqlite3/sqlite3_rsync"
mkdir -p "$SYS4/pg/runtime/usr/bin" "$SYS4/pg/runtime/usr/lib"
printf '#!/usr/bin/env sh\nexit 0\n' > "$SYS4/pg/runtime/usr/bin/kdev-test-bin"
chmod 0700 "$SYS4/pg/runtime/usr/bin/kdev-test-bin"
printf 'test\n' > "$SYS4/pg/runtime/usr/lib/libkdevtest.so.2.1.0"
rm -f "$SYS4/pg/runtime/usr/lib/libkdevtest.so.2"

PATH="$BIN4:$PATH" KAGGLE_SYSTEM_DIR="$SYS4" \
  bash "$ROOT/install/install-all.sh" bootstrap >"$TMP/boot4.log" 2>&1 ||
  fail "bootstrap crashed during privilege-completeness restore (log: $TMP/boot4.log)"

require_sudo4() {
    local op="$1"
    grep -qF -- "sudo $op" "$SUDO_LOG4" ||
      fail "restore operation bypassed sudo/run_root: $op"
}

require_sudo4 "chmod 755 $SYS4"
require_sudo4 "chown root:root $SYS4/restore-helper.sh"
require_sudo4 "chmod 755 $SYS4/restore-helper.sh"
require_sudo4 "chmod 755 $SYS4/sqlite3/sqlite3 $SYS4/sqlite3/sqldiff $SYS4/sqlite3/sqlite3_analyzer $SYS4/sqlite3/sqlite3_rsync"
require_sudo4 "chmod 755 $SYS4/pg/runtime/usr/bin/kdev-test-bin"
require_sudo4 "ln -s libkdevtest.so.2.1.0 $SYS4/pg/runtime/usr/lib/libkdevtest.so.2"

[ -L "$SYS4/pg/runtime/usr/lib/libkdevtest.so.2" ] ||
  fail "soname repair did not recreate the expected symlink"
[ "$(readlink "$SYS4/pg/runtime/usr/lib/libkdevtest.so.2")" = 'libkdevtest.so.2.1.0' ] ||
  fail "soname repair created an unexpected symlink target"

# Every recorded privileged mutation touching the dedicated restore fixtures
# above must have a corresponding sudo wrapper entry.
while IFS= read -r line; do
    case "$line" in
      *"$SYS4"*) require_sudo4 "$line" ;;
    esac
done < "$OPS_LOG4"

echo 'PASS: bootstrap privileged restore repairs are complete, sudo-routed and fail-closed'
