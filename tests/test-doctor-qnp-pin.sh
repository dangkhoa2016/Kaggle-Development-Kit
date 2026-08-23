#!/usr/bin/env bash
set -euo pipefail

# Regression P2.1: scripts/doctor.sh must validate the exact pinned QNP
# source identity, not just the release number.
#
# The Qdrant installer pins an exact 40-character upstream commit and records
# it in .qnp-source-meta; the checkout HEAD must match it. Doctor historically
# printed the commit but reported OK whenever VERSION matched QNP_RELEASE,
# silently accepting a wrong/tampered source cache. The diagnostic tool must
# fail closed on any of: release mismatch, metadata commit mismatch, or
# checkout HEAD mismatch. When .git is intentionally absent from a portable
# cache, metadata may match but doctor must say that tree identity is not
# independently verifiable rather than claiming the pin itself is verified.
# A portable cache may also live underneath the main project Git repository;
# in that case Git parent discovery must never be mistaken for QNP checkout
# identity after the QNP-local .git metadata disappears during cold restore.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

EXPECTED_RELEASE='1.0.0'
WRONG_COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

build_qnp_cache() {
    # $1 = system dir. Builds a real miniature QNP source cache whose checkout
    # HEAD is a genuine commit SHA, echoes that SHA.
    local sys="$1"
    local src="$sys/qdrant/qnp/qdrant-native-platform-1.0.0"
    mkdir -p "$sys/qdrant/qnp" "$TMP/home"
    GIT_CONFIG_NOSYSTEM=1 git init -q "$src" 2>/dev/null
    git -C "$src" -c user.name=kdev-test -c user.email=test@example.com \
        commit --allow-empty -q -m baseline
    local actual
    actual="$(git -C "$src" rev-parse HEAD)"
    printf '%s\n' "$EXPECTED_RELEASE" > "$src/VERSION"
    printf 'commit=%s\n' "$actual" > "$src/.qnp-source-meta"
    printf 'qdrant-native-platform-1.0.0\n' > "$sys/qdrant/qnp-source-name"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sys/qdrant-service.sh"
    chmod 0755 "$sys/qdrant-service.sh"
    printf '%s\n' "$actual"
}

make_defaults() {
    # $1 = defaults file; $2 = configured (expected) QNP_SOURCE_COMMIT.
    printf 'QNP_RELEASE=%s\nQNP_SOURCE_COMMIT=%s\n' "$EXPECTED_RELEASE" "$2" > "$1"
}

run_doctor() {
    # $1 = system dir; $2 = defaults file. Sets rc and DOCTOR_OUT.
    DOCTOR_OUT="$TMP/doctor.$RANDOM.log"
    rc=0
    (
        export HOME="$TMP/home"
        export GIT_CONFIG_NOSYSTEM=1
        export KAGGLE_SYSTEM_DIR="$1"
        export KAGGLE_DEV_DEFAULTS_FILE="$2"
        cd /
        bash "$ROOT/scripts/doctor.sh"
    ) > "$DOCTOR_OUT" 2>&1 || rc=$?
}

mkdir -p "$TMP/home"

SYS="$TMP/system-mismatch"
ACTUAL_COMMIT="$(build_qnp_cache "$SYS")"

DEFAULTS_BAD="$TMP/defaults-wrong-commit.env"
make_defaults "$DEFAULTS_BAD" "$WRONG_COMMIT"

# --- Scenario 1: release matches, commit identity is wrong => doctor FAILS ---
run_doctor "$SYS" "$DEFAULTS_BAD"

[ "$rc" -ne 0 ] ||
  fail "doctor reported success although QNP checkout commit != configured pin (log: $DOCTOR_OUT)"
grep -q '❌[[:space:]]*QNP' "$DOCTOR_OUT" ||
  fail "doctor did not report the QNP pin failure explicitly (log: $DOCTOR_OUT)"

# --- Scenario 2: correct release + correct commit => doctor stays OK ---------
DEFAULTS_GOOD="$TMP/defaults-correct.env"
make_defaults "$DEFAULTS_GOOD" "$ACTUAL_COMMIT"

run_doctor "$SYS" "$DEFAULTS_GOOD"

[ "$rc" -eq 0 ] ||
  fail "doctor failed a correctly pinned QNP cache (log: $DOCTOR_OUT)"
grep -q '✅[[:space:]]*QNP' "$DOCTOR_OUT" ||
  fail "doctor did not report the healthy QNP cache as OK (log: $DOCTOR_OUT)"

# --- Scenario 3: metadata matches but .git is absent => cautious WARN --------
QNP_SRC="$SYS/qdrant/qnp/qdrant-native-platform-1.0.0"
rm -rf "$QNP_SRC/.git"
run_doctor "$SYS" "$DEFAULTS_GOOD"

[ "$rc" -eq 0 ] ||
  fail "doctor should warn, not fail, when portable QNP metadata matches but .git is absent (log: $DOCTOR_OUT)"
grep -q '⚠️[[:space:]]*QNP' "$DOCTOR_OUT" ||
  fail "doctor did not report metadata-only QNP verification as a warning (log: $DOCTOR_OUT)"
grep -q 'source tree identity cannot be independently verified' "$DOCTOR_OUT" ||
  fail "doctor warning overstates metadata-only QNP evidence (log: $DOCTOR_OUT)"
if grep -q 'pin verified via metadata' "$DOCTOR_OUT"; then
  fail "doctor still claims the QNP pin is verified from metadata alone (log: $DOCTOR_OUT)"
fi

# --- Scenario 4: cold-restored QNP below parent repo must not inherit HEAD ----
# Reproduce the Kaggle layout: .system/qdrant/qnp lives beneath the main
# project repository. Once QNP-local .git disappears, plain `git -C` walks up
# to the project .git and returns the wrong repository HEAD.
PARENT="$TMP/nested-project"
GIT_CONFIG_NOSYSTEM=1 git init -q "$PARENT" 2>/dev/null
git -C "$PARENT" -c user.name=kdev-test -c user.email=test@example.com \
    commit --allow-empty -q -m parent-baseline
PARENT_HEAD="$(git -C "$PARENT" rev-parse HEAD)"
NESTED_SYS="$PARENT/.system"
NESTED_QNP_COMMIT="$(build_qnp_cache "$NESTED_SYS")"
[ "$PARENT_HEAD" != "$NESTED_QNP_COMMIT" ] ||
  fail 'test setup unexpectedly produced identical parent and QNP commits'
NESTED_DEFAULTS="$TMP/defaults-nested.env"
make_defaults "$NESTED_DEFAULTS" "$NESTED_QNP_COMMIT"
NESTED_QNP_SRC="$NESTED_SYS/qdrant/qnp/qdrant-native-platform-1.0.0"
rm -rf "$NESTED_QNP_SRC/.git"

run_doctor "$NESTED_SYS" "$NESTED_DEFAULTS"

[ "$rc" -eq 0 ] ||
  fail "doctor followed parent Git metadata for cold-restored QNP cache (parent=$PARENT_HEAD qnp=$NESTED_QNP_COMMIT log: $DOCTOR_OUT)"
grep -q '⚠️[[:space:]]*QNP' "$DOCTOR_OUT" ||
  fail "doctor did not downgrade nested metadata-only QNP verification to a warning (log: $DOCTOR_OUT)"
grep -q 'source tree identity cannot be independently verified' "$DOCTOR_OUT" ||
  fail "doctor did not report unavailable QNP-local Git identity for nested cold restore (log: $DOCTOR_OUT)"
if grep -Fq "checkout HEAD=$PARENT_HEAD" "$DOCTOR_OUT"; then
  fail "doctor incorrectly used parent project HEAD as QNP checkout identity (log: $DOCTOR_OUT)"
fi

echo 'PASS: doctor validates QNP pin identity without inheriting parent repository HEAD'
