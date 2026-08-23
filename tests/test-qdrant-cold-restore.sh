#!/usr/bin/env bash
set -euo pipefail

# Test fixtures must not inherit a permissive caller umask. In particular,
# Codespaces/dev shells may be configured differently from GitHub Actions.
# Pin a safe baseline so a fixture created before bootstrap cannot be mistaken
# for a world-writable directory introduced by bootstrap itself.
umask 022

# Regression: Kaggle cold-restore boundary for the Qdrant service user.
#
# /kaggle/working can preserve .system across VM resets while OS accounts are
# wiped. install-all.sh bootstrap recreates redis/postgres/elastic users but
# historically skipped qdrantuser and never repaired persisted Qdrant
# ownership, so QNP PROCESS_MODE=service-user start failed on fresh runtimes.
#
# The scenario is simulated deterministically without touching the host
# account database: the bootstrap process is tricked into "root" mode via a
# stubbed id(1), account lookups (getent/useradd) consult an in-test fake
# database, and chown calls are recorded instead of applied. chmod/stat stay
# real so file modes (0640 config, no world-writable dirs) are verified.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="$TMP/bin"
STATE="$TMP/state"
SYSTEM="$TMP/system"
mkdir -p "$FAKE_BIN" "$STATE"

QDRANT_USER="qdrantuser"

# Fake account database: nobody exists before the cold restore.
: > "$STATE/passwd"
: > "$STATE/chown.log"
: > "$STATE/useradd.log"

cat > "$FAKE_BIN/id" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-u" ]; then printf '0\n'; exit 0; fi
if [ "\${1:-}" = "-un" ]; then exec /usr/bin/id -un; fi
for arg in "\$@"; do
  if grep -qxF "\$arg" "$STATE/passwd" 2>/dev/null; then exit 0; fi
done
exit 1
EOF

cat > "$FAKE_BIN/getent" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = group ]; then
  grep -qxF "\$2" "$STATE/passwd" 2>/dev/null && exit 0
  exit 2
fi
exec /usr/bin/getent "\$@"
EOF

cat > "$FAKE_BIN/useradd" <<EOF
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
printf '%s\n' "useradd \$*" >> "$STATE/useradd.log"
EOF

cat > "$FAKE_BIN/chown" <<EOF
#!/usr/bin/env bash
owner="\$1"; shift
printf '%s\n' "chown \$owner \$*" >> "$STATE/chown.log"
exit 0
EOF

chmod +x "$FAKE_BIN/id" "$FAKE_BIN/getent" "$FAKE_BIN/useradd" "$FAKE_BIN/chown"

# --- Persisted cold-restored Qdrant state ---------------------------------
QBASE="$SYSTEM/qdrant"
INST="$QBASE/instances/1.18.3"
mkdir -p "$INST/config" "$INST/storage/collections" "$INST/snapshots" \
         "$INST/logs" "$INST/tmp" "$SYSTEM/sqlite3" "$SYSTEM/pg" \
         "$SYSTEM/redis" "$SYSTEM/elastic"
# KDK_TEST_FIXTURE_MODE_V1: deterministic directory baseline before bootstrap.
chmod 0755 "$QBASE" "$QBASE/instances" "$INST" "$INST/config" \
    "$INST/storage" "$INST/storage/collections" "$INST/snapshots" \
    "$INST/logs" "$INST/tmp"
printf '%s\n' "$QDRANT_USER" > "$QBASE/service-user"
printf '%s\n' '1.18.3' > "$QBASE/default-version"
# Dummy persisted SQLite tools keep bootstrap off its full reinstall path.
for tool in sqlite3 sqldiff sqlite3_analyzer sqlite3_rsync; do
  printf '#!/usr/bin/env sh\nexit 0\n' > "$SYSTEM/sqlite3/$tool"
  chmod 0755 "$SYSTEM/sqlite3/$tool"
done
cat > "$INST/config/qdrant.yaml" <<'CFG'
service:
  host: 127.0.0.1
  http_port: 6333
CFG
chmod 0640 "$INST/config/qdrant.yaml"
# Sensitive env files whose restrictive policy must survive bootstrap untouched.
printf 'QDRANT__SERVICE__API_KEY=dummy\n' > "$INST/secrets.env"
chmod 0600 "$INST/secrets.env"
printf 'STORAGE__STORAGE_PATH=persisted\n' > "$INST/runtime.env"
chmod 0640 "$INST/runtime.env"
printf 'persisted\n' > "$INST/storage/collections/demo.bin"
chmod 0644 "$INST/storage/collections/demo.bin"

# Precondition: installer honors KAGGLE_SYSTEM_DIR like every other installer.
grep -q 'KAGGLE_SYSTEM_DIR' "$ROOT/install/install-all.sh" || {
  echo 'FAIL: install-all.sh ignores KAGGLE_SYSTEM_DIR; cold restore cannot be exercised' >&2
  exit 1
}

# The fixture itself must start without world-writable directories. Otherwise
# the post-bootstrap assertion below cannot truthfully attribute the condition
# to bootstrap.
if find "$QBASE" -type d -perm -0002 | grep -q .; then
  echo "FAIL: test fixture starts with a world-writable directory under $QBASE" >&2
  echo "Offending fixture directories:" >&2
  find "$QBASE" -type d -perm -0002 -printf '  mode=%m path=%p
' >&2
  echo "Current umask: $(umask)" >&2
  exit 1
fi

PATH="$FAKE_BIN:$PATH" KAGGLE_SYSTEM_DIR="$SYSTEM" \
  bash "$ROOT/install/install-all.sh" bootstrap >"$TMP/bootstrap.log" 2>&1 || {
  cat "$TMP/bootstrap.log" >&2
  echo 'FAIL: bootstrap crashed during cold restore' >&2
  exit 1
}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Service user must be recreated (only because persisted Qdrant state exists).
grep -qx "useradd .* $QDRANT_USER" "$STATE/useradd.log" ||
  fail "bootstrap did not recreate service user $QDRANT_USER"

# Writable instance areas must be repaired to user:user.
for area in storage snapshots logs tmp; do
  grep -qE "^chown -R $QDRANT_USER:$QDRANT_USER .*$area" "$STATE/chown.log" ||
    fail "ownership of $INST/$area was not repaired"
done

# Config must regain root:<service-group> semantics...
grep -qE "^chown root:$QDRANT_USER .*config/qdrant.yaml$" "$STATE/chown.log" ||
  fail "config/qdrant.yaml group ownership was not repaired"

# ...and keep its restrictive 0640 mode (real chmod/stat verified).
[ "$(stat -c '%a' "$INST/config/qdrant.yaml")" = 640 ] ||
  fail "config/qdrant.yaml mode changed from 0640"

# secrets.env/runtime.env keep their restrictive modes...
[ "$(stat -c '%a' "$INST/secrets.env")" = 600 ] ||
  fail "secrets.env mode was modified by bootstrap"
[ "$(stat -c '%a' "$INST/runtime.env")" = 640 ] ||
  fail "runtime.env mode was modified by bootstrap"

# ...and ownership must not be broadened to the service user.
if grep -qE 'secrets\.env|runtime\.env' "$STATE/chown.log"; then
  fail "bootstrap altered ownership of secrets.env/runtime.env"
fi

# No world-writable directory may appear anywhere under the restored tree.
if find "$QBASE" -type d -perm -0002 | grep -q .; then
  fail "world-writable directory introduced under $QBASE"
fi

echo 'PASS: qdrant cold-restore recreates service user and repairs persisted ownership'
