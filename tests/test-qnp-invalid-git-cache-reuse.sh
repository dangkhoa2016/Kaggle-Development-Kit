#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || { printf 'FAIL: sudo is required for privileged fixture mutation\n' >&2; return 1; }
        sudo -n "$@"
    fi
}
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
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
FIXTURE="$TMP/qnp-fixture"
mkdir -p "$FIXTURE/scripts"
cd "$FIXTURE"
git init -q
git config user.email test@example.invalid
git config user.name Test
printf '1.0.0\n' > VERSION
cat > qdrant.sh <<'QSH'
#!/usr/bin/env bash
exit 0
QSH
chmod +x qdrant.sh
for n in 01_credentials 02_setup_env 03_download_qdrant 04_configure_qdrant; do
cat > "scripts/$n.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$BASE_DIR"
case "$(basename "$0")" in
  02_setup_env.sh) mkdir -p "$BASE_DIR"/{storage,snapshots,logs,run,tmp} ;;
  03_download_qdrant.sh)
    mkdir -p "$BASE_DIR/qdrant-$QDRANT_VERSION"
    printf '#!/usr/bin/env bash\nprintf "qdrant %s\\n" "$QDRANT_VERSION"\n' > "$BASE_DIR/qdrant-$QDRANT_VERSION/qdrant"
    chmod +x "$BASE_DIR/qdrant-$QDRANT_VERSION/qdrant" ;;
  04_configure_qdrant.sh)
    mkdir -p "$BASE_DIR/config"
    printf 'service: {}\n' > "$BASE_DIR/config/qdrant.yaml"
    PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    # Reproduce QNP's real runtime-generated marker even when the shared
    # source was chmod a-w. Real Kaggle runs this path as root.
    if [ "$(id -u)" -eq 0 ]; then
        printf '%s\n' "$BASE_DIR" > "$PROJECT_DIR/.qdrant-base"
    else
        printf '%s\n' "$BASE_DIR" | sudo -n tee "$PROJECT_DIR/.qdrant-base" >/dev/null
    fi
    ;;
esac
SCRIPT
chmod +x "scripts/$n.sh"
done
cat > scripts/source-integrity.py <<'PY'
#!/usr/bin/env python3
# Fresh activation only needs the CLI to exit successfully in this fixture.
raise SystemExit(0)
PY
chmod +x scripts/source-integrity.py
FINGERPRINT="$(python3 - "$FIXTURE" <<'PY_MANIFEST'
import hashlib, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
records = []
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    base = pathlib.Path(dirpath)
    dirnames[:] = [d for d in sorted(dirnames) if d != ".git"]
    for name in sorted(filenames):
        path = base / name
        rel = path.relative_to(root).as_posix()
        if rel == "SOURCE-MANIFEST.json" or ".git" in pathlib.PurePosixPath(rel).parts:
            continue
        if path.is_symlink():
            target = os.readlink(path).encode("utf-8", errors="surrogateescape")
            sha = hashlib.sha256(target).hexdigest(); size = len(target); kind = "symlink"
        else:
            data = path.read_bytes(); sha = hashlib.sha256(data).hexdigest(); size = len(data); kind = "file"
        records.append({"path": rel, "sha256": sha, "size": size, "kind": kind})
h = hashlib.sha256()
for record in sorted(records, key=lambda x: x["path"]):
    h.update(record["path"].encode()); h.update(b"\0")
    h.update(record["sha256"].encode("ascii")); h.update(b"\0")
    h.update(str(record["size"]).encode("ascii")); h.update(b"\n")
digest = h.hexdigest()
manifest = {"schema_version": 2, "scope": "project-source-v2", "root_name": "fixture",
            "canonical_sha256": digest, "canonical_file_count": len(records), "files": records}
(root / "SOURCE-MANIFEST.json").write_text(json.dumps(manifest) + "\n")
print(digest)
PY_MANIFEST
)"
git add .
git commit -qm 'fixture'
COMMIT="$(git rev-parse HEAD)"
REFRESH_FIXTURE="$TMP/qnp-refresh-fixture"
cp -a "$FIXTURE" "$REFRESH_FIXTURE"
CONFIG="$TMP/config.env"
SYSTEM="$TMP/system"
cat > "$CONFIG" <<CFG
QDRANT_VERSIONS="1.18.3"
QDRANT_DEFAULT_VERSION="1.18.3"
QDRANT_PORT_1_18_3=6333
QDRANT_GRPC_PORT_1_18_3=6334
QDRANT_ENABLE_GRPC=0
QDRANT_AUTO_START_VERSIONS="1.18.3"
QDRANT_PROFILE=auto
QDRANT_SERVICE_USER=root
QNP_RELEASE=1.0.0
QNP_SOURCE_COMMIT=$COMMIT
QNP_SOURCE_CANONICAL_SHA256=$FINGERPRINT
QNP_GIT_URL=$FIXTURE
CFG

cd "$ROOT"
KAGGLE_DEV_CONFIG_FILE="$CONFIG" KAGGLE_SYSTEM_DIR="$SYSTEM" bash install/install-qdrant.sh >/dev/null
SOURCE="$SYSTEM/qdrant/qnp/1.0.0-${COMMIT:0:12}"
[ -d "$SOURCE/.git" ] || fail 'initial cached QNP checkout missing .git'
[ -f "$SOURCE/.qnp-source-meta" ] || fail 'initial cache missing identity metadata'
[ -x "$SOURCE/qdrant.sh" ] || fail 'initial cached QNP entrypoint was not executable before cold restore'
[ ! -e "$SOURCE/.qdrant-base" ] || fail 'initial QNP configure left generated .qdrant-base in the authenticated source cache'

# Simulate Kaggle cold restore: source payload survives, nested Git metadata does not.
run_privileged chmod -R u+w "$SOURCE"
run_privileged rm -rf "$SOURCE/.git"

# Real Kaggle cold restore can preserve source bytes while dropping executable
# mode bits. KDK invokes these files through bash/python, so executable mode is
# not required for canonical reuse or configuration.
run_privileged chmod a-x \
  "$SOURCE/qdrant.sh" \
  "$SOURCE/scripts/01_credentials.sh" \
  "$SOURCE/scripts/02_setup_env.sh" \
  "$SOURCE/scripts/03_download_qdrant.sh" \
  "$SOURCE/scripts/04_configure_qdrant.sh" \
  "$SOURCE/scripts/source-integrity.py"

[ ! -x "$SOURCE/qdrant.sh" ] || \
  fail 'cold-restore fixture did not remove the QNP entrypoint executable bit'

printf '/tmp/poison-qdrant-base\n' | run_privileged tee "$SOURCE/.qdrant-base" >/dev/null
rm -rf "$FIXTURE"
# Any attempt to refetch now must fail because QNP_GIT_URL no longer exists.
rc=0
KAGGLE_DEV_CONFIG_FILE="$CONFIG" KAGGLE_SYSTEM_DIR="$SYSTEM" \
  bash install/install-qdrant.sh >"$TMP/restore.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "intact QNP cache with invalid nested .git triggered refetch/failure (rc=$rc): $(cat "$TMP/restore.log")"
grep -q 'cached; reusing it\|verified payload' "$TMP/restore.log" || fail 'restore did not report QNP cache reuse'
! grep -q 'Fetch QNP' "$TMP/restore.log" || \
  fail '.qdrant-base overlay triggered an unnecessary QNP refetch'
[ ! -e "$SOURCE/.qdrant-base" ] || \
  fail 'restore left the generated .qdrant-base overlay in the authenticated source cache'
[ ! -d "$SOURCE/.git" ] || fail 'test expected offline reuse without reconstructing Git metadata'
[ -x "$SOURCE/qdrant.sh" ] || \
  fail 'cold-restore permission normalization did not restore the QNP entrypoint executable mode'

# A non-file object at .qdrant-base is not a repairable overlay. The helper must
# not rm -rf it; reuse is refused and targeted refresh is attempted instead.
run_privileged mkdir "$SOURCE/.qdrant-base"
rc=0
KAGGLE_DEV_CONFIG_FILE="$CONFIG" KAGGLE_SYSTEM_DIR="$SYSTEM" \
  bash install/install-qdrant.sh >"$TMP/weird-marker.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'directory .qdrant-base was accepted as a repairable generated overlay'
[ -d "$SOURCE/.qdrant-base" ] || fail 'directory .qdrant-base was recursively deleted'
grep -q 'Refusing to remove unexpected non-file QNP .qdrant-base overlay' "$TMP/weird-marker.log" || \
  fail 'directory .qdrant-base did not fail closed in the overlay repair layer'
grep -q 'Fetch QNP' "$TMP/weird-marker.log" || \
  fail 'directory .qdrant-base did not fall back to targeted source refresh'
run_privileged rm -rf "$SOURCE/.qdrant-base"

# Unknown extras must remain strict canonical-verifier failures. The .qdrant-base
# repair must not turn into a generic whitelist for unexpected payload.
printf 'unexpected\n' | run_privileged tee "$SOURCE/evil-extra-file" >/dev/null
rc=0
KAGGLE_DEV_CONFIG_FILE="$CONFIG" KAGGLE_SYSTEM_DIR="$SYSTEM" \
  bash install/install-qdrant.sh >"$TMP/unknown-extra.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'unknown extra payload was blindly reused'
! grep -q 'canonical payload verified for offline reuse' "$TMP/unknown-extra.log" || \
  fail 'unknown extra payload was incorrectly reported as canonical'
grep -q 'Fetch QNP' "$TMP/unknown-extra.log" || \
  fail 'unknown extra payload did not fall back to targeted source refresh'
run_privileged rm -f "$SOURCE/evil-extra-file"

# Corrupt the independently verified verifier itself. Offline reuse must now be
# refused; with the configured source gone, targeted refetch must fail closed.
printf '\n# corruption\n' | run_privileged tee -a "$SOURCE/scripts/source-integrity.py" >/dev/null
rc=0
KAGGLE_DEV_CONFIG_FILE="$CONFIG" KAGGLE_SYSTEM_DIR="$SYSTEM" \
  bash install/install-qdrant.sh >"$TMP/corrupt.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'corrupt QNP payload was blindly reused'
! grep -q 'canonical payload verified for offline reuse' "$TMP/corrupt.log" || \
  fail 'corrupt QNP payload was incorrectly reported as verified'
grep -q 'Fetch QNP' "$TMP/corrupt.log" || \
  fail 'corrupt cache did not fall back to targeted source refresh'

# Stronger tamper case: update the manifest record to match the corrupted
# verifier while dishonestly leaving canonical_sha256 unchanged. A verifier
# record cannot be trusted until the manifest fingerprint itself is recomputed.
CORRUPT_VERIFIER_SHA="$(sha256sum "$SOURCE/scripts/source-integrity.py" | awk '{print $1}')"
CORRUPT_VERIFIER_SIZE="$(stat -c %s "$SOURCE/scripts/source-integrity.py")"
run_privileged python3 - "$SOURCE/SOURCE-MANIFEST.json" "$CORRUPT_VERIFIER_SHA" "$CORRUPT_VERIFIER_SIZE" <<'PY_TAMPER'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
value = json.loads(p.read_text())
for record in value["files"]:
    if record.get("path") == "scripts/source-integrity.py":
        record["sha256"] = sys.argv[2]
        record["size"] = int(sys.argv[3])
p.write_text(json.dumps(value) + "\n")
PY_TAMPER
rc=0
KAGGLE_DEV_CONFIG_FILE="$CONFIG" KAGGLE_SYSTEM_DIR="$SYSTEM" \
  bash install/install-qdrant.sh >"$TMP/tampered-manifest.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'tampered QNP manifest+verifier bypassed canonical fingerprint validation'
! grep -q 'canonical payload verified for offline reuse' "$TMP/tampered-manifest.log" || \
  fail 'tampered QNP manifest+verifier was incorrectly reported as verified'

# Explicit force refresh must bypass even a reusable cache and atomically restore
# from the configured source. Use a retained copy of the original fixture repo.
FORCE_CONFIG="$TMP/force-config.env"
sed "s|^QNP_GIT_URL=.*|QNP_GIT_URL=$REFRESH_FIXTURE|" "$CONFIG" > "$FORCE_CONFIG"
printf 'QNP_FORCE_SOURCE_REFRESH=1\n' >> "$FORCE_CONFIG"
KAGGLE_DEV_CONFIG_FILE="$FORCE_CONFIG" KAGGLE_SYSTEM_DIR="$SYSTEM" \
  bash install/install-qdrant.sh >"$TMP/force.log" 2>&1 || \
  fail "QNP force refresh failed: $(cat "$TMP/force.log")"
grep -q 'Fetch QNP' "$TMP/force.log" || fail 'QNP_FORCE_SOURCE_REFRESH=1 did not force a fetch'
[ -d "$SOURCE/.git" ] || fail 'force refresh did not restore the canonical Git checkout'
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$COMMIT" ] || fail 'force refresh restored the wrong QNP commit'

echo 'PASS: QNP cache reuses verified payload without nested Git, rejects corruption, and preserves force refresh'
