#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SYSTEM="$TMP/system"
CFG="$TMP/config.env"
mkdir -p "$SYSTEM/qdrant/instances/1.18.3/qdrant-1.18.3" \
         "$SYSTEM/qdrant/instances/1.18.3/config" \
         "$SYSTEM/qdrant/qnp/1.0.0-066084be23d2"
cat > "$CFG" <<'CFG'
INSTALL_QDRANT=1
QDRANT_VERSIONS="1.18.2 1.18.3"
QDRANT_DEFAULT_VERSION="1.18.3"
QDRANT_PORT_1_18_2=6335
QDRANT_GRPC_PORT_1_18_2=6336
QDRANT_PORT_1_18_3=6333
QDRANT_GRPC_PORT_1_18_3=6334
QDRANT_ENABLE_GRPC=0
QDRANT_AUTO_START_VERSIONS="1.18.3"
QDRANT_PROFILE=auto
QNP_RELEASE=1.0.0
QNP_SOURCE_COMMIT=066084be23d23a5be11ca8e5df28d5da9eef1cc4
CFG
printf '1.18.3\n' > "$SYSTEM/qdrant/default-version"
printf '1.0.0-066084be23d2\n' > "$SYSTEM/qdrant/qnp-source-name"
printf 'qdrantuser\n' > "$SYSTEM/qdrant/service-user"
printf '1.18.3\n' > "$SYSTEM/qdrant/instances/1.18.3/kdev-version"
printf '6333\n' > "$SYSTEM/qdrant/instances/1.18.3/kdev-rest-port"
printf '6334\n' > "$SYSTEM/qdrant/instances/1.18.3/kdev-grpc-port"
printf '0\n' > "$SYSTEM/qdrant/instances/1.18.3/kdev-grpc-enabled"
printf 'auto\n' > "$SYSTEM/qdrant/instances/1.18.3/kdev-profile-requested"
cat > "$SYSTEM/qdrant/instances/1.18.3/config/qdrant.yaml" <<'YAML'
service:
  host: 127.0.0.1
  http_port: 6333
telemetry_disabled: true
YAML
cat > "$SYSTEM/qdrant/instances/1.18.3/qdrant-1.18.3/qdrant" <<'BIN'
#!/usr/bin/env bash
printf 'qdrant 1.18.3\n'
BIN
chmod +x "$SYSTEM/qdrant/instances/1.18.3/qdrant-1.18.3/qdrant"
printf '1.0.0\n' > "$SYSTEM/qdrant/qnp/1.0.0-066084be23d2/VERSION"
cat > "$SYSTEM/qdrant/qnp/1.0.0-066084be23d2/.qnp-source-meta" <<'META'
release=1.0.0
commit=066084be23d23a5be11ca8e5df28d5da9eef1cc4
origin=https://github.com/dangkhoa2016/Qdrant-Native-Portable.git
META
cat > "$SYSTEM/qdrant-service.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
SYSTEM_DIR="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$SYSTEM_DIR/qdrant-cli.log"
printf 'helper:%s\n' "$*"
HELPER
chmod +x "$SYSTEM/qdrant-service.sh"

run_kdev() {
  KAGGLE_SYSTEM_DIR="$SYSTEM" KAGGLE_DEV_CONFIG_FILE="$CFG" "$ROOT/bin/kdev" "$@"
}

out="$(run_kdev qdrant status)"
[ "$out" = 'helper:1.18.3 status' ]
out="$(run_kdev qdrant 1.18.2 url)"
[ "$out" = 'helper:1.18.2 url' ]
out="$(run_kdev qdrant version)"
[ "$out" = 'helper:1.18.3 version' ]
out="$(run_kdev qdrant 1.18.3 logs -n 5)"
[ "$out" = 'helper:1.18.3 logs -n 5' ]

grep -qx '1.18.3 status' "$SYSTEM/qdrant-cli.log"
grep -qx '1.18.2 url' "$SYSTEM/qdrant-cli.log"
grep -qx '1.18.3 version' "$SYSTEM/qdrant-cli.log"
grep -qx '1.18.3 logs -n 5' "$SYSTEM/qdrant-cli.log"

versions="$(run_kdev versions)"
grep -q 'Qdrant' <<<"$versions"
grep -q '1.18.2 1.18.3' <<<"$versions"
grep -q 'QNP.*1.0.0' <<<"$versions"
grep -q '066084be23d2' <<<"$versions"

# Doctor must understand configured + installed Qdrant state without treating a
# stopped instance as broken.
doctor="$(KAGGLE_SYSTEM_DIR="$SYSTEM" KAGGLE_DEV_CONFIG_FILE="$CFG" bash "$ROOT/scripts/doctor.sh")"
grep -q 'Qdrant' <<<"$doctor"
grep -q 'Qdrant 1.18.3' <<<"$doctor"
grep -q 'QNP.*1.0.0' <<<"$doctor"
grep -q '127.0.0.1:6333' <<<"$doctor"

echo 'PASS: qdrant kdev routing and doctor reporting'
