#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  if [ "$(id -u)" -eq 0 ]; then
    rm -rf "$TMP"
  else
    sudo rm -rf "$TMP"
  fi
}
trap cleanup EXIT

FIXTURE="$TMP/qnp-fixture"
mkdir -p "$FIXTURE/scripts"
cd "$FIXTURE"
git init -q
git config user.email test@example.invalid
git config user.name Test
printf '1.0.0\n' > VERSION
cat > qdrant.sh <<'QSH'
#!/usr/bin/env bash
set -euo pipefail
action="${1:-help}"
printf '%s\n' "$action" >> "$BASE_DIR/qdrant-sh-actions.log"
case "$action" in
  start) mkdir -p "$BASE_DIR/run"; printf '%s\n' "$$" > "$BASE_DIR/run/qdrant.pid" ;;
  stop) rm -f "$BASE_DIR/run/qdrant.pid" ;;
  restart) mkdir -p "$BASE_DIR/run"; printf '%s\n' "$$" > "$BASE_DIR/run/qdrant.pid" ;;
  status) printf 'fake status %s\n' "$QDRANT_VERSION" ;;
  health) printf 'fake healthy %s\n' "$QDRANT_VERSION" ;;
  *) : ;;
esac
QSH
chmod +x qdrant.sh
for n in 01_credentials 02_setup_env 03_download_qdrant 04_configure_qdrant 05_start_qdrant 06_verify_qdrant; do
cat > "scripts/$n.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
mkdir -p "$BASE_DIR"
printf '%s version=%s rest=%s grpc=%s grpc_enabled=%s mode=%s public=%s bind=%s base=%s\n' \
  "$name" "$QDRANT_VERSION" "$QDRANT_HTTP_PORT" "$QDRANT_GRPC_PORT" "$QDRANT_ENABLE_GRPC" \
  "$PROCESS_MODE" "$PUBLIC_MODE" "$QDRANT_BIND_HOST" "$BASE_DIR" >> "$BASE_DIR/calls.log"
case "$name" in
  01_credentials.sh)
    printf 'QDRANT_API_KEY=fake-test-only\nQDRANT_READ_ONLY_API_KEY=fake-readonly-test-only\n' > "$BASE_DIR/secrets.env"
    chmod 600 "$BASE_DIR/secrets.env" ;;
  02_setup_env.sh) mkdir -p "$BASE_DIR"/{storage,snapshots,logs,run,tmp,downloads,tokens} ;;
  03_download_qdrant.sh)
    mkdir -p "$BASE_DIR/qdrant-$QDRANT_VERSION"
    cat > "$BASE_DIR/qdrant-$QDRANT_VERSION/qdrant" <<BIN
#!/usr/bin/env bash
printf 'qdrant $QDRANT_VERSION\\n'
BIN
    chmod +x "$BASE_DIR/qdrant-$QDRANT_VERSION/qdrant" ;;
  04_configure_qdrant.sh)
    mkdir -p "$BASE_DIR/config"
    cat > "$BASE_DIR/config/qdrant.yaml" <<CFG
service:
  host: $QDRANT_BIND_HOST
  http_port: $QDRANT_HTTP_PORT
  grpc_port: $QDRANT_GRPC_PORT
telemetry_disabled: true
CFG
    ;;
esac
SCRIPT
chmod +x "scripts/$n.sh"
done
# The real pinned source carries this verifier. Fixture only needs the interface.
cat > scripts/source-integrity.py <<'PY'
#!/usr/bin/env python3
raise SystemExit(0)
PY
chmod +x scripts/source-integrity.py
printf '{}\n' > SOURCE-MANIFEST.json
git add .
git commit -qm 'fixture qnp 1.0.0'
COMMIT="$(git rev-parse HEAD)"

CONFIG="$TMP/config.env"
SYSTEM="$TMP/system"
cat > "$CONFIG" <<CFG
INSTALL_QDRANT=1
QDRANT_VERSIONS="1.18.2 1.18.3"
QDRANT_DEFAULT_VERSION="1.18.3"
QDRANT_PORT_1_18_2=6335
QDRANT_GRPC_PORT_1_18_2=6336
QDRANT_PORT_1_18_3=6333
QDRANT_GRPC_PORT_1_18_3=6334
QDRANT_ENABLE_GRPC=0
QDRANT_AUTO_START_VERSIONS=""
QDRANT_PROFILE=auto
QNP_RELEASE=1.0.0
QNP_SOURCE_COMMIT=$COMMIT
QNP_GIT_URL=$FIXTURE
CFG

cd "$ROOT"
KAGGLE_DEV_CONFIG_FILE="$CONFIG" KAGGLE_SYSTEM_DIR="$SYSTEM" \
  bash install/install-qdrant.sh

SHORT="${COMMIT:0:12}"
SOURCE="$SYSTEM/qdrant/qnp/1.0.0-$SHORT"
[ -d "$SOURCE/.git" ]
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$COMMIT" ]
grep -qx 'release=1.0.0' "$SOURCE/.qnp-source-meta"
grep -qx "commit=$COMMIT" "$SOURCE/.qnp-source-meta"
[ -x "$SYSTEM/qdrant-service.sh" ]

for v in 1.18.2 1.18.3; do
  base="$SYSTEM/qdrant/instances/$v"
  [ -x "$base/qdrant-$v/qdrant" ]
  [ -f "$base/config/qdrant.yaml" ]
  [ "$(wc -l < "$base/calls.log")" -eq 4 ]
  grep -q "version=$v" "$base/calls.log"
  grep -q 'mode=service-user' "$base/calls.log"
  grep -q 'public=none' "$base/calls.log"
  grep -q 'bind=127.0.0.1' "$base/calls.log"
done
grep -q '^02_setup_env.sh .*mode=service-user' "$SYSTEM/qdrant/instances/1.18.3/calls.log"
grep -q 'rest=6335 grpc=6336' "$SYSTEM/qdrant/instances/1.18.2/calls.log"
grep -q 'rest=6333 grpc=6334' "$SYSTEM/qdrant/instances/1.18.3/calls.log"

# Generated service helper must delegate lifecycle/utility actions to QNP.
[ "$(bash "$SYSTEM/qdrant-service.sh" 1.18.3 url)" = "http://127.0.0.1:6333" ]
bash "$SYSTEM/qdrant-service.sh" 1.18.3 status | grep -q 'fake status 1.18.3'
bash "$SYSTEM/qdrant-service.sh" 1.18.3 start
bash "$SYSTEM/qdrant-service.sh" 1.18.3 health | grep -q 'fake healthy 1.18.3'
bash "$SYSTEM/qdrant-service.sh" 1.18.3 stop
bash "$SYSTEM/qdrant-service.sh" 1.18.3 version | grep -q 'qdrant 1.18.3'

# Release mismatch must fail closed before activation.
BAD="$TMP/bad.env"
sed 's/^QNP_RELEASE=.*/QNP_RELEASE=2.0.0/' "$CONFIG" > "$BAD"
if KAGGLE_DEV_CONFIG_FILE="$BAD" KAGGLE_SYSTEM_DIR="$TMP/bad-system" \
     bash install/install-qdrant.sh >"$TMP/bad.log" 2>&1; then
  echo 'expected QNP release mismatch to fail' >&2
  exit 1
fi
grep -qi 'VERSION\|release' "$TMP/bad.log"

# Cached source must be sufficient for an idempotent second install.
rm -rf "$FIXTURE"
KAGGLE_DEV_CONFIG_FILE="$CONFIG" KAGGLE_SYSTEM_DIR="$SYSTEM" \
  bash install/install-qdrant.sh
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$COMMIT" ]
for v in 1.18.2 1.18.3; do
  [ "$(wc -l < "$SYSTEM/qdrant/instances/$v/calls.log")" -eq 8 ]
done

# Duplicate REST ports across configured Qdrant versions must fail.
DUP="$TMP/dup.env"
sed 's/^QDRANT_PORT_1_18_2=.*/QDRANT_PORT_1_18_2=6333/' "$CONFIG" > "$DUP"
if KAGGLE_DEV_CONFIG_FILE="$DUP" KAGGLE_SYSTEM_DIR="$TMP/dup-system" \
     bash install/install-qdrant.sh >"$TMP/dup.log" 2>&1; then
  echo 'expected duplicate Qdrant REST ports to fail' >&2
  exit 1
fi
grep -qi 'port' "$TMP/dup.log"

echo 'PASS: qdrant installer pinning, isolation, and idempotency'
