#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_apt_stub() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/apt-get" <<'EOF_APT'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$APT_STUB_LOG"

case " $* " in
  *" update "*)
    # Model the real Kaggle failure: an unrelated third-party mirror can make
    # apt-get update return 100 while existing Ubuntu indexes remain usable.
    exit 100
    ;;
  *" install "*)
    count_file="${APT_STUB_LOG}.install-count"
    count=0
    if [[ -f "$count_file" ]]; then
      count="$(cat "$count_file")"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"

    case "$APT_STUB_MODE" in
      install-success)
        ;;
      fail-once-then-success)
        if [[ "$count" -eq 1 ]]; then
          exit 100
        fi
        ;;
      always-fail)
        exit 100
        ;;
      *)
        echo "unknown APT_STUB_MODE=$APT_STUB_MODE" >&2
        exit 2
        ;;
    esac

    cat > "$APT_STUB_BIN/sshd" <<'EOF_CMD'
#!/usr/bin/env bash
exit 0
EOF_CMD
    cat > "$APT_STUB_BIN/ssh-keygen" <<'EOF_CMD'
#!/usr/bin/env bash
exit 0
EOF_CMD
    chmod +x "$APT_STUB_BIN/sshd" "$APT_STUB_BIN/ssh-keygen"
    exit 0
    ;;
esac

echo "unexpected apt-get invocation: $*" >&2
exit 2
EOF_APT
  chmod +x "$bin/apt-get"
}

count_call() {
  local pattern="$1" file="$2"
  grep -c -- "$pattern" "$file" 2>/dev/null || true
}

run_ensure() {
  local name="$1" mode="$2"
  local bin="$TMP/$name/bin"
  local state="$TMP/$name/state"
  local log="$TMP/$name/apt.log"

  mkdir -p "$state"
  make_apt_stub "$bin"

  set +e
  env \
    PATH="$bin:/usr/bin:/bin" \
    KAGGLE_SSH_STATE_DIR="$state/ssh-state" \
    KAGGLE_SSH_WORK_DIR="$state/work" \
    APT_STUB_MODE="$mode" \
    APT_STUB_LOG="$log" \
    APT_STUB_BIN="$bin" \
    /usr/bin/bash -c '
      set -Eeuo pipefail
      source "$1"
      ensure_directories
      ensure_openssh
    ' _ "$ROOT/setup.sh"
  rc=$?
  set -e

  printf '%s\n' "$rc" > "$TMP/$name/rc"
  printf '%s\n' "$log" > "$TMP/$name/log-path"
}

# Scenario 1: the exact successful Kaggle path. Existing package indexes can
# install OpenSSH, so no apt-get update should be attempted at all.
run_ensure direct-install install-success
rc="$(cat "$TMP/direct-install/rc")"
[[ "$rc" -eq 0 ]] ||
  fail "OpenSSH install from existing indexes failed (rc=$rc)"
log="$(cat "$TMP/direct-install/log-path")"
[[ "$(count_call ' install ' "$log")" -eq 1 ]] ||
  fail "expected exactly one initial apt install"
[[ "$(count_call ' update ' "$log")" -eq 0 ]] ||
  fail "apt-get update ran even though existing indexes could install OpenSSH"

# Scenario 2: initial install fails; an unrelated mirror also makes update fail;
# retrying install from whatever indexes are usable succeeds.
run_ensure mirror-sync-fallback fail-once-then-success
rc="$(cat "$TMP/mirror-sync-fallback/rc")"
[[ "$rc" -eq 0 ]] ||
  fail "mirror-sync fallback did not recover (rc=$rc)"
log="$(cat "$TMP/mirror-sync-fallback/log-path")"
[[ "$(count_call ' install ' "$log")" -eq 2 ]] ||
  fail "expected initial install plus one install retry"
[[ "$(count_call ' update ' "$log")" -eq 1 ]] ||
  fail "expected one on-failure apt index refresh"

# Scenario 3: if OpenSSH really cannot be installed, bootstrap remains fail-closed.
run_ensure hard-failure always-fail
rc="$(cat "$TMP/hard-failure/rc")"
[[ "$rc" -ne 0 ]] ||
  fail "ensure_openssh reported success while every install attempt failed"

# Notebook contract: Cell 5 must include the proven no-update OpenSSH preinstall
# before setup.sh, without committing runtime outputs.
python3 - "$ROOT/notebooks/kaggle-dev-bootstrap.ipynb" <<'PY'
import ast
import json
import sys

path = sys.argv[1]
nb = json.load(open(path, encoding="utf-8"))
cells = nb.get("cells") or []
target = None

for cell in cells:
    if cell.get("cell_type") != "code":
        continue
    source = "".join(cell.get("source") or [])
    if source.startswith("# CELL 5 — OPTIONAL: start SSH + ngrok"):
        target = cell
        break

assert target is not None, "Cell 5 SSH bootstrap cell not found"
assert target.get("execution_count") is None
assert not target.get("outputs"), "public source notebook must not contain runtime SSH/ngrok output"

source = "".join(target["source"])
tree = ast.parse(source)

commands = []
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    if not isinstance(node.func, ast.Attribute):
        continue
    if node.func.attr != "run" or not node.args:
        continue
    arg = node.args[0]
    if not isinstance(arg, (ast.List, ast.Tuple)):
        continue
    values = []
    ok = True
    for elt in arg.elts:
        if isinstance(elt, ast.Constant) and isinstance(elt.value, str):
            values.append(elt.value)
        else:
            ok = False
            break
    if ok:
        commands.append((getattr(node, "lineno", 0), values))

apt = [
    (line, cmd) for line, cmd in commands
    if cmd and cmd[0] == "apt-get"
]
setup = [
    (line, cmd) for line, cmd in commands
    if cmd[:2] == ["bash", "setup.sh"]
]

assert apt, "Cell 5 must pre-install OpenSSH from existing Kaggle APT indexes"
assert setup, "Cell 5 must invoke setup.sh"
apt_line, apt_cmd = apt[0]
setup_line, _ = setup[0]
assert "install" in apt_cmd
assert "openssh-server" in apt_cmd
assert "update" not in apt_cmd
assert apt_line < setup_line
assert "START_SSH = False" in source

print("PASS: notebook SSH preflight installs OpenSSH from existing indexes before setup.sh.")
PY

echo 'PASS: OpenSSH install avoids unconditional apt update, tolerates mirror-sync failure, and remains fail-closed.'
