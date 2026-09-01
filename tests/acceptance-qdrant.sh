#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ROOT="${KDEV_QDRANT_ACCEPTANCE_ROOT:-$(mktemp -d)}"
SYSTEM="$RUN_ROOT/system"
CFG="$RUN_ROOT/qdrant.env"
EVIDENCE="$RUN_ROOT/evidence"
VERSION="1.18.3"
PORT="${KDEV_QDRANT_ACCEPTANCE_PORT:-16333}"
GRPC_PORT="${KDEV_QDRANT_ACCEPTANCE_GRPC_PORT:-16334}"
COLLECTION="kdev_qdrant_acceptance"
POINT_ID=20260822
MARKER="kdev-qdrant-1.18.3-20260822"
HELPER="$SYSTEM/qdrant-service.sh"
INSTANCE="$SYSTEM/qdrant/instances/$VERSION"

mkdir -p "$RUN_ROOT" "$EVIDENCE"
# mktemp -d creates mode 0700; QNP starts Qdrant as qdrantuser, which must
# be able to traverse this disposable acceptance root to reach its own
# service-owned config/storage/runtime paths. Keep listing/write access closed.
chmod 0711 "$RUN_ROOT"
cleanup() {
  if [ -x "$HELPER" ]; then
    KAGGLE_SYSTEM_DIR="$SYSTEM" KAGGLE_DEV_CONFIG_FILE="$CFG" \
      "$ROOT/bin/kdev" qdrant "$VERSION" stop >/dev/null 2>&1 || true
  fi
  if [ "${KDEV_QDRANT_ACCEPTANCE_KEEP:-0}" != "1" ] && [[ "$RUN_ROOT" == /tmp/* ]]; then
    rm -rf "$RUN_ROOT"
  fi
}
trap cleanup EXIT

cat > "$CFG" <<CFG
INSTALL_POSTGRES=0
INSTALL_REDIS=0
INSTALL_ELASTIC=0
INSTALL_QDRANT=1
INSTALL_TOOLS=0
QDRANT_VERSIONS="$VERSION"
QDRANT_DEFAULT_VERSION="$VERSION"
QDRANT_PORT_1_18_3=$PORT
QDRANT_GRPC_PORT_1_18_3=$GRPC_PORT
QDRANT_ENABLE_GRPC=0
QDRANT_AUTO_START_VERSIONS="$VERSION"
QDRANT_PROFILE=low-memory
QNP_RELEASE=1.0.0
QNP_SOURCE_COMMIT=21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca
CFG
chmod 600 "$CFG"

export KAGGLE_SYSTEM_DIR="$SYSTEM"
export KAGGLE_DEV_CONFIG_FILE="$CFG"

echo '=== Network preflight for real acceptance ==='
if ! git ls-remote -q https://github.com/dangkhoa2016/Qdrant-Native-Portable.git HEAD >/dev/null 2>&1; then
  cat >&2 <<'BLOCKED'
BLOCKED: this release-gate test requires outbound access to github.com.
The current environment cannot fetch the pinned QNP source/Qdrant release, so no
real native Qdrant acceptance claim can be made from this run. Re-run this exact
test in a fresh Kaggle Notebook with Internet enabled.
BLOCKED
  exit 75
fi

# The production adapter intentionally uses QNP service-user mode: orchestration
# runs privileged while Qdrant itself drops to qdrantuser. Escalate only after
# the unprivileged network preflight so blocked-network tests remain fail-closed.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo env \
    KDEV_QDRANT_ACCEPTANCE_ROOT="$RUN_ROOT" \
    KDEV_QDRANT_ACCEPTANCE_PORT="$PORT" \
    KDEV_QDRANT_ACCEPTANCE_GRPC_PORT="$GRPC_PORT" \
    KDEV_QDRANT_ACCEPTANCE_KEEP="${KDEV_QDRANT_ACCEPTANCE_KEEP:-0}" \
    bash "$0" "$@"
fi

echo '=== Fresh install: real pinned QNP + Qdrant 1.18.3 ==='
bash "$ROOT/install/install-qdrant.sh" | tee "$EVIDENCE/install-first.log"

[ -x "$HELPER" ]
[ -x "$INSTANCE/qdrant-$VERSION/qdrant" ]
[ "$(tr -d '[:space:]' < "$SYSTEM/qdrant/qnp/1.0.0-21f83a6df741/VERSION")" = '1.0.0' ]
grep -qx 'commit=21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca' "$SYSTEM/qdrant/qnp/1.0.0-21f83a6df741/.qnp-source-meta"

"$ROOT/bin/kdev" qdrant "$VERSION" health | tee "$EVIDENCE/health-first.txt"
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/readyz" > "$EVIDENCE/readyz.txt"

grep -Eq '^[[:space:]]*host:[[:space:]]*127\.0\.0\.1[[:space:]]*$' "$INSTANCE/config/qdrant.yaml"
grep -Eq "^[[:space:]]*http_port:[[:space:]]*$PORT[[:space:]]*$" "$INSTANCE/config/qdrant.yaml"
[ ! -e "$INSTANCE/run/public-url.txt" ]

# Use generated development credentials without printing them.
set +u
# shellcheck disable=SC1090
source "$INSTANCE/secrets.env"
set -u
: "${QDRANT_API_KEY:?QNP did not generate QDRANT_API_KEY}"
API="http://127.0.0.1:$PORT"
api_curl() { curl -fsS --max-time 10 -H "api-key: $QDRANT_API_KEY" "$@"; }

# Deterministic collection + vector sentinel.
api_curl -X DELETE "$API/collections/$COLLECTION" >/dev/null 2>&1 || true
api_curl -X PUT "$API/collections/$COLLECTION" \
  -H 'content-type: application/json' \
  --data-binary '{"vectors":{"size":4,"distance":"Cosine"}}' \
  > "$EVIDENCE/create-collection.json"
api_curl -X PUT "$API/collections/$COLLECTION/points?wait=true" \
  -H 'content-type: application/json' \
  --data-binary "{\"points\":[{\"id\":$POINT_ID,\"vector\":[1.0,0.0,0.0,0.0],\"payload\":{\"marker\":\"$MARKER\"}}]}" \
  > "$EVIDENCE/upsert.json"
api_curl "$API/collections/$COLLECTION/points/$POINT_ID?with_payload=true&with_vector=true" \
  > "$EVIDENCE/point-before-restart.json"
python3 - "$EVIDENCE/point-before-restart.json" "$MARKER" "$POINT_ID" <<'PY'
import json, sys
payload=json.load(open(sys.argv[1], encoding='utf-8'))
r=payload['result']
assert int(r['id']) == int(sys.argv[3])
assert r['payload']['marker'] == sys.argv[2]
vec=r['vector']
assert len(vec)==4 and abs(float(vec[0])-1.0)<1e-9
PY

api_curl -X POST "$API/collections/$COLLECTION/points/search" \
  -H 'content-type: application/json' \
  --data-binary '{"vector":[1.0,0.0,0.0,0.0],"limit":1,"with_payload":true}' \
  > "$EVIDENCE/search-before-restart.json"
python3 - "$EVIDENCE/search-before-restart.json" "$MARKER" <<'PY'
import json, sys
payload=json.load(open(sys.argv[1], encoding='utf-8'))
rows=payload.get('result') or []
assert rows, payload
assert rows[0]['payload']['marker'] == sys.argv[2]
PY

echo '=== Lifecycle + persistence ==='
"$ROOT/bin/kdev" qdrant "$VERSION" stop | tee "$EVIDENCE/stop.txt"
"$ROOT/bin/kdev" qdrant "$VERSION" start | tee "$EVIDENCE/start-after-stop.txt"
"$ROOT/bin/kdev" qdrant "$VERSION" health | tee "$EVIDENCE/health-after-restart.txt"
api_curl "$API/collections/$COLLECTION/points/$POINT_ID?with_payload=true&with_vector=true" \
  > "$EVIDENCE/point-after-restart.json"
python3 - "$EVIDENCE/point-after-restart.json" "$MARKER" <<'PY'
import json, sys
payload=json.load(open(sys.argv[1], encoding='utf-8'))
assert payload['result']['payload']['marker'] == sys.argv[2]
PY

# Listener must remain local-only. The exact users/process column varies by host.
if command -v ss >/dev/null 2>&1; then
  ss -ltn > "$EVIDENCE/listeners.txt"
  grep -Eq "127\.0\.0\.1:$PORT([[:space:]]|$)" "$EVIDENCE/listeners.txt"
  ! grep -Eq "(^|[[:space:]])(0\.0\.0\.0|\*):$PORT([[:space:]]|$)" "$EVIDENCE/listeners.txt"
fi
! pgrep -af '[c]loudflared.*qdrant' > "$EVIDENCE/unexpected-tunnel-process.txt"

echo '=== Idempotent second install ==='
bash "$ROOT/install/install-qdrant.sh" | tee "$EVIDENCE/install-second.log"
"$ROOT/bin/kdev" qdrant "$VERSION" health | tee "$EVIDENCE/health-second-install.txt"
api_curl "$API/collections/$COLLECTION/points/$POINT_ID?with_payload=true&with_vector=false" \
  > "$EVIDENCE/point-after-second-install.json"
python3 - "$EVIDENCE/point-after-second-install.json" "$MARKER" <<'PY'
import json, sys
payload=json.load(open(sys.argv[1], encoding='utf-8'))
assert payload['result']['payload']['marker'] == sys.argv[2]
PY

# Doctor output is safe: it must not print API keys.
"$ROOT/bin/kdev" doctor > "$EVIDENCE/doctor.txt"
grep -q "Qdrant $VERSION" "$EVIDENCE/doctor.txt"
grep -q "127.0.0.1:$PORT" "$EVIDENCE/doctor.txt"
grep -q 'Result: OK' "$EVIDENCE/doctor.txt"
! grep -Fq "$QDRANT_API_KEY" "$EVIDENCE/doctor.txt"

# Produce a deliberately sanitized acceptance summary suitable for release docs.
cat > "$EVIDENCE/SUMMARY.txt" <<SUMMARY
Qdrant Kaggle Development Kit acceptance
qnp_release=1.0.0
qnp_commit=21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca
qdrant_version=$VERSION
rest_endpoint=127.0.0.1:$PORT
bind_scope=loopback-only
grpc_enabled=0
public_mode=none
fresh_install=PASS
readyz=PASS
vector_upsert_read_search=PASS
restart_persistence=PASS
idempotent_second_install=PASS
doctor=PASS
secrets_in_summary=NO
SUMMARY
cat "$EVIDENCE/SUMMARY.txt"
echo "PASS: real Qdrant $VERSION native acceptance"
echo "Evidence: $EVIDENCE"
