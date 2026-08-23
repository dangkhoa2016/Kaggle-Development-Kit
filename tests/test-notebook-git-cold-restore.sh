#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTEBOOK="${1:-$ROOT/notebooks/kaggle-dev-bootstrap.ipynb}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    FAILURES=$((FAILURES + 1))
}

CELL="$TMP/cell1.py"
python3 - "$NOTEBOOK" "$CELL" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    notebook = json.load(f)
cell = notebook["cells"][0]
if cell.get("cell_type") != "code":
    raise SystemExit("notebook Cell 1 is not code")
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write("".join(cell.get("source", [])))
    f.write("\n")
PY

make_origin() {
    local name="$1"
    SEED="$TMP/$name-seed"
    REMOTE="$TMP/$name-origin.git"

    git init -q -b main "$SEED"
    git -C "$SEED" config user.name 'KDev Notebook Test'
    git -C "$SEED" config user.email 'kdev-notebook-test@example.invalid'
    printf 'source-v1\n' > "$SEED/tracked.txt"
    printf '.system/\n.kaggle-dev.env\n' > "$SEED/.gitignore"
    git -C "$SEED" add tracked.txt .gitignore
    git -C "$SEED" commit -q -m 'source v1'
    SHA1="$(git -C "$SEED" rev-parse HEAD)"

    printf 'source-v2\n' > "$SEED/tracked.txt"
    git -C "$SEED" add tracked.txt
    git -C "$SEED" commit -q -m 'source v2'
    SHA2="$(git -C "$SEED" rev-parse HEAD)"

    git clone -q --bare "$SEED" "$REMOTE"
    git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
}

run_cell() {
    local project="$1" remote="$2" log="$3"
    KAGGLE_DEV_REPOSITORY_URL="$remote" \
    KAGGLE_DEV_REPOSITORY_REF=main \
    KAGGLE_DEV_PROJECT_DIR="$project" \
    python3 "$CELL" >"$log" 2>&1
}

assert_persisted() {
    local project="$1" service="$2" marker="$3"
    [ "$(cat "$project/.system/$service/marker" 2>/dev/null || true)" = "$marker" ] || \
        fail ".system/$service persisted marker changed or disappeared"
    [ "$(cat "$project/.kaggle-dev.env" 2>/dev/null || true)" = 'CONFIG=preserve-me' ] || \
        fail '.kaggle-dev.env changed or disappeared'
    [ "$(cat "$project/local-persisted.txt" 2>/dev/null || true)" = 'user-persisted' ] || \
        fail 'other untracked persisted state changed or disappeared'
}

seed_persisted() {
    local project="$1" service="$2" marker="$3"
    mkdir -p "$project/.system/$service"
    printf '%s\n' "$marker" > "$project/.system/$service/marker"
    printf 'CONFIG=preserve-me\n' > "$project/.kaggle-dev.env"
    printf 'user-persisted\n' > "$project/local-persisted.txt"
}

# ---------------------------------------------------------------------------
# Scenario A: a healthy existing repo follows the normal fetch/reset path.
# ---------------------------------------------------------------------------
make_origin healthy
PROJECT="$TMP/healthy-project"
git clone -q "$REMOTE" "$PROJECT"
git -C "$PROJECT" reset -q --hard "$SHA1"
seed_persisted "$PROJECT" redis healthy-runtime
if ! run_cell "$PROJECT" "$REMOTE" "$TMP/healthy.log"; then
    cat "$TMP/healthy.log" >&2
    fail 'healthy existing repo update failed'
else
    [ "$(git -C "$PROJECT" rev-parse HEAD)" = "$SHA2" ] || fail 'healthy repo did not advance to exact fetched target'
    [ "$(cat "$PROJECT/tracked.txt")" = source-v2 ] || fail 'healthy repo tracked source was not reset'
    assert_persisted "$PROJECT" redis healthy-runtime
    if compgen -G "$TMP/.healthy-project.git-invalid-cold-restore*" >/dev/null; then
        fail 'healthy repo incorrectly entered invalid-Git quarantine path'
    fi
fi

# ---------------------------------------------------------------------------
# Scenario B: real Kaggle shape — .git exists but HEAD/config/index are gone.
# ---------------------------------------------------------------------------
make_origin invalid
PROJECT="$TMP/invalid-project"
mkdir -p \
    "$PROJECT/.git/objects" \
    "$PROJECT/.git/refs" \
    "$PROJECT/.git/logs" \
    "$PROJECT/.git/hooks" \
    "$PROJECT/.git/info"
printf 'stale-source\n' > "$PROJECT/tracked.txt"
seed_persisted "$PROJECT" redis invalid-runtime
if ! run_cell "$PROJECT" "$REMOTE" "$TMP/invalid.log"; then
    cat "$TMP/invalid.log" >&2
    fail 'invalid .git cold restore did not self-recover'
else
    [ "$(git -C "$PROJECT" rev-parse HEAD)" = "$SHA2" ] || fail 'invalid .git recovery HEAD mismatch'
    [ "$(cat "$PROJECT/tracked.txt")" = source-v2 ] || fail 'invalid .git recovery did not reset tracked source'
    assert_persisted "$PROJECT" redis invalid-runtime
    backup="$(find "$TMP" -maxdepth 1 -name '.invalid-project.git-invalid-cold-restore*' -print -quit)"
    [ -n "$backup" ] || fail 'invalid Git metadata was not preserved for diagnostics'
    [ -d "$backup/objects" ] || fail 'preserved invalid Git metadata lost its objects directory'
fi

# ---------------------------------------------------------------------------
# Scenario C: project/persisted state exists but .git is missing entirely.
# ---------------------------------------------------------------------------
make_origin missing
PROJECT="$TMP/missing-project"
mkdir -p "$PROJECT"
printf 'stale-source\n' > "$PROJECT/tracked.txt"
seed_persisted "$PROJECT" postgres missing-runtime
if ! run_cell "$PROJECT" "$REMOTE" "$TMP/missing.log"; then
    cat "$TMP/missing.log" >&2
    fail 'missing .git cold restore did not self-recover'
else
    [ "$(git -C "$PROJECT" rev-parse HEAD)" = "$SHA2" ] || fail 'missing .git recovery HEAD mismatch'
    [ "$(cat "$PROJECT/tracked.txt")" = source-v2 ] || fail 'missing .git recovery did not reset tracked source'
    assert_persisted "$PROJECT" postgres missing-runtime
fi

# ---------------------------------------------------------------------------
# Scenario D: config/index are missing but Git still recognizes the worktree.
# Cell 1 must recreate origin instead of failing on `remote set-url`.
# ---------------------------------------------------------------------------
make_origin partial
PROJECT="$TMP/partial-project"
git clone -q "$REMOTE" "$PROJECT"
git -C "$PROJECT" reset -q --hard "$SHA1"
seed_persisted "$PROJECT" qdrant partial-runtime
rm -f "$PROJECT/.git/config" "$PROJECT/.git/index"
if ! run_cell "$PROJECT" "$REMOTE" "$TMP/partial.log"; then
    cat "$TMP/partial.log" >&2
    fail 'partial config/index loss did not recover origin metadata'
else
    [ "$(git -C "$PROJECT" rev-parse HEAD)" = "$SHA2" ] || fail 'partial metadata recovery HEAD mismatch'
    [ "$(git -C "$PROJECT" remote get-url origin)" = "$REMOTE" ] || fail 'origin was not recreated after config loss'
    assert_persisted "$PROJECT" qdrant partial-runtime
fi

# ---------------------------------------------------------------------------
# Scenario E: recovery cannot fetch. It must fail closed without claiming the
# project is ready and without deleting persisted service/config state.
# ---------------------------------------------------------------------------
PROJECT="$TMP/failure-project"
mkdir -p "$PROJECT/.git/objects" "$PROJECT/.git/refs"
printf 'original-invalid-git\n' > "$PROJECT/.git/original-marker"
printf 'stale-source\n' > "$PROJECT/tracked.txt"
seed_persisted "$PROJECT" elastic failure-runtime
BAD_REMOTE="$TMP/does-not-exist.git"
set +e
run_cell "$PROJECT" "$BAD_REMOTE" "$TMP/failure.log"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    fail 'recovery unexpectedly succeeded with a nonexistent origin'
fi
assert_persisted "$PROJECT" elastic failure-runtime
if grep -Eq '^Project:|^Commit:' "$TMP/failure.log"; then
    fail 'failed recovery printed final ready/source identity output'
fi
[ "$(cat "$PROJECT/.git/original-marker" 2>/dev/null || true)" = original-invalid-git ] || \
    fail 'failed recovery did not roll original invalid Git metadata back into place'
if compgen -G "$TMP/.failure-project.git-invalid-cold-restore*" >/dev/null; then
    fail 'failed recovery left a quarantine sibling instead of restoring original Git metadata'
fi

# ---------------------------------------------------------------------------
# Scenario F: missing-.git recovery cannot fetch. The failed attempt must not
# leave synthetic partial Git metadata behind; persisted state remains intact.
# ---------------------------------------------------------------------------
PROJECT="$TMP/missing-failure-project"
mkdir -p "$PROJECT"
printf 'stale-source\n' > "$PROJECT/tracked.txt"
seed_persisted "$PROJECT" postgres missing-failure-runtime
set +e
run_cell "$PROJECT" "$BAD_REMOTE" "$TMP/missing-failure.log"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    fail 'missing-.git recovery unexpectedly succeeded with a nonexistent origin'
fi
assert_persisted "$PROJECT" postgres missing-failure-runtime
if [ -e "$PROJECT/.git" ] || [ -L "$PROJECT/.git" ]; then
    fail 'failed missing-.git recovery left synthetic partial Git metadata behind'
fi
if grep -Eq '^Project:|^Commit:' "$TMP/missing-failure.log"; then
    fail 'failed missing-.git recovery printed final ready/source identity output'
fi

if [ "$FAILURES" -ne 0 ]; then
    printf 'FAIL: %d notebook Git cold-restore regression assertion(s) failed\n' "$FAILURES" >&2
    exit 1
fi

echo 'PASS: notebook Cell 1 handles healthy, invalid, missing and partial Git metadata while preserving persisted state and failing closed'
