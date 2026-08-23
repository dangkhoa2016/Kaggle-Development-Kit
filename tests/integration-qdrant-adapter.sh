#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
FAKE="$TMP/fake-qnp"
SYSTEM="$TMP/system"
CFG="$TMP/qdrant.env"
VERSION="1.18.3"
PORT=17633
GRPC=17634
cleanup() {
  if [ -x "$SYSTEM/qdrant-service.sh" ]; then
    "$SYSTEM/qdrant-service.sh" "$VERSION" stop >/dev/null 2>&1 || true
  fi
  if [ "$(id -u)" -eq 0 ]; then
    rm -rf "$TMP"
  else
    sudo rm -rf "$TMP"
  fi
}
trap cleanup EXIT

mkdir -p "$FAKE/scripts"
cat > "$FAKE/VERSION" <<'EOV'
1.0.0
EOV
cat > "$FAKE/scripts/source-integrity.py" <<'PY'
#!/usr/bin/env python3
raise SystemExit(0)
PY
chmod +x "$FAKE/scripts/source-integrity.py"
printf '{}\n' > "$FAKE/SOURCE-MANIFEST.json"

cat > "$FAKE/scripts/01_credentials.sh" <<'EOF1'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$BASE_DIR"
cat > "$BASE_DIR/secrets.env" <<'ENV'
QDRANT_API_KEY=fake-admin-key-for-adapter-test
QDRANT_READ_ONLY_API_KEY=fake-readonly-key-for-adapter-test
ENV
chmod 600 "$BASE_DIR/secrets.env"
EOF1

cat > "$FAKE/scripts/02_setup_env.sh" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$BASE_DIR"/{config,logs,run,storage,tmp,snapshots}
EOF2

cat > "$FAKE/scripts/03_download_qdrant.sh" <<'EOF3'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$BASE_DIR/qdrant-$QDRANT_VERSION"
cat > "$BASE_DIR/qdrant-$QDRANT_VERSION/qdrant" <<BIN
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then echo 'qdrant $QDRANT_VERSION'; exit 0; fi
exit 0
BIN
chmod +x "$BASE_DIR/qdrant-$QDRANT_VERSION/qdrant"
EOF3

cat > "$FAKE/scripts/04_configure_qdrant.sh" <<'EOF4'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$BASE_DIR/config"
cat > "$BASE_DIR/config/qdrant.yaml" <<CFG
service:
  host: $QDRANT_BIND_HOST
  http_port: $QDRANT_HTTP_PORT
  grpc_port: null
telemetry_disabled: true
cluster:
  enabled: false
CFG
EOF4

cat > "$FAKE/scripts/mini-server.py" <<'PY'
#!/usr/bin/env python3
import argparse, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
p=argparse.ArgumentParser(); p.add_argument('--host'); p.add_argument('--port', type=int); p.add_argument('--state'); a=p.parse_args()
state=Path(a.state)
class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def _send(self, code, payload):
        body=json.dumps(payload).encode(); self.send_response(code); self.send_header('content-type','application/json'); self.send_header('content-length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == '/readyz': self._send(200, {'ready':True}); return
        if self.path == '/sentinel':
            payload=json.loads(state.read_text()) if state.exists() else {}
            self._send(200, payload); return
        self._send(404, {'error':'not-found'})
    def do_PUT(self):
        if self.path != '/sentinel': self._send(404, {'error':'not-found'}); return
        n=int(self.headers.get('content-length','0')); payload=json.loads(self.rfile.read(n) or b'{}'); state.parent.mkdir(parents=True, exist_ok=True); state.write_text(json.dumps(payload)); self._send(200, {'status':'ok'})
ThreadingHTTPServer((a.host,a.port),H).serve_forever()
PY
chmod +x "$FAKE/scripts/mini-server.py"

cat > "$FAKE/qdrant.sh" <<'EOFQ'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PID="$BASE_DIR/run/qdrant.pid"; LOG="$BASE_DIR/logs/qdrant.log"; STATE="$BASE_DIR/storage/adapter-sentinel.json"
mkdir -p "$BASE_DIR"/{run,logs,storage}
alive(){ [ -f "$PID" ] && kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null; }
ready(){ curl -fsS --max-time 2 "http://127.0.0.1:$QDRANT_HTTP_PORT/readyz" >/dev/null 2>&1; }
start(){
  if alive && ready; then echo 'fake qdrant already ready'; return; fi
  rm -f "$PID"
  nohup python3 "$ROOT/scripts/mini-server.py" --host "$QDRANT_BIND_HOST" --port "$QDRANT_HTTP_PORT" --state "$STATE" >>"$LOG" 2>&1 & echo $! > "$PID"
  for _ in $(seq 1 30); do ready && { echo 'fake qdrant ready'; return; }; sleep 0.1; done
  echo 'fake qdrant failed readiness' >&2; exit 1
}
stop(){ if alive; then kill "$(cat "$PID")" 2>/dev/null || true; for _ in $(seq 1 30); do alive || break; sleep 0.1; done; fi; rm -f "$PID"; echo 'fake qdrant stopped'; }
case "${1:-status}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  health) ready && echo 'fake qdrant healthy' ;;
  status) alive && ready && echo 'fake qdrant running' || { echo 'fake qdrant stopped'; exit 1; } ;;
  *) echo "unsupported $1" >&2; exit 2 ;;
esac
EOFQ
chmod +x "$FAKE/qdrant.sh" "$FAKE/scripts/"*.sh

(
  cd "$FAKE"
  git init -q
  git config user.email test@example.invalid
  git config user.name test
  git add .
  git commit -qm baseline
)
SHA="$(git -C "$FAKE" rev-parse HEAD)"

cat > "$CFG" <<CFG
INSTALL_POSTGRES=0
INSTALL_REDIS=0
INSTALL_ELASTIC=0
INSTALL_QDRANT=1
INSTALL_TOOLS=0
QDRANT_VERSIONS="$VERSION"
QDRANT_DEFAULT_VERSION="$VERSION"
QDRANT_PORT_1_18_3=$PORT
QDRANT_GRPC_PORT_1_18_3=$GRPC
QDRANT_ENABLE_GRPC=0
QDRANT_AUTO_START_VERSIONS="$VERSION"
QDRANT_PROFILE=low-memory
QNP_RELEASE=1.0.0
QNP_SOURCE_COMMIT=$SHA
QNP_GIT_URL=$FAKE
CFG
chmod 600 "$CFG"
export KAGGLE_SYSTEM_DIR="$SYSTEM" KAGGLE_DEV_CONFIG_FILE="$CFG"

bash "$ROOT/install/install-qdrant.sh" >/dev/null
"$ROOT/bin/kdev" qdrant "$VERSION" health | grep -q healthy
[ "$("$ROOT/bin/kdev" qdrant "$VERSION" url)" = "http://127.0.0.1:$PORT" ]
curl -fsS -X PUT -H 'content-type: application/json' --data-binary '{"marker":"adapter-persistence-pass"}' "http://127.0.0.1:$PORT/sentinel" >/dev/null
curl -fsS "http://127.0.0.1:$PORT/sentinel" | grep -q adapter-persistence-pass

"$ROOT/bin/kdev" qdrant "$VERSION" stop >/dev/null
"$ROOT/bin/kdev" qdrant "$VERSION" start >/dev/null
curl -fsS "http://127.0.0.1:$PORT/sentinel" | grep -q adapter-persistence-pass

# A second install must reuse the pinned cache and preserve live storage.
bash "$ROOT/install/install-qdrant.sh" >/dev/null
curl -fsS "http://127.0.0.1:$PORT/sentinel" | grep -q adapter-persistence-pass

# The adapter itself must enforce loopback configuration and no public artifact.
grep -Eq 'host:[[:space:]]*127\.0\.0\.1' "$SYSTEM/qdrant/instances/$VERSION/config/qdrant.yaml"
[ ! -e "$SYSTEM/qdrant/instances/$VERSION/run/public-url.txt" ]
"$ROOT/bin/kdev" qdrant "$VERSION" version | grep -q "$VERSION"

echo 'PASS: qdrant adapter local process lifecycle and persistence'
