#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/connect-kaggle.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file_contains() {
  local file="$1" expected="$2"
  [[ -f "$file" ]] || fail "missing file: $file"
  grep -Fqx -- "$expected" "$file" || {
    printf '%s\n' "--- $file ---" >&2
    cat "$file" >&2 || true
    fail "expected line not found: $expected"
  }
}
assert_file_not_contains() {
  local file="$1" unexpected="$2"
  [[ ! -f "$file" ]] || ! grep -Fqx -- "$unexpected" "$file" || fail "unexpected line found: $unexpected"
}
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

make_fake_ssh() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/ssh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_SSH_STATE_DIR:?}"
mkdir -p "$state"
printf '%q ' "$@" >>"$state/calls.log"; printf '\n' >>"$state/calls.log"

# Model real OpenSSH command-line option validation.
for ssh_arg in "$@"; do
  if [[ "$ssh_arg" == "ConnectTimeout=not-a-time" ]]; then
    printf '%s\n' 'command-line line 0: invalid time value.' >&2
    exit 255
  fi
done

# Model `ssh -G`: OpenSSH resolves the effective destination without dialing.
for ssh_arg in "$@"; do
  if [[ "$ssh_arg" == "-G" ]]; then
    printf 'user %s\n' "${FAKE_SSH_G_USER:-root}"
    printf 'hostname %s\n' "${FAKE_SSH_G_HOSTNAME:-example.invalid}"
    printf 'port %s\n' "${FAKE_SSH_G_PORT:-22}"
    exit 0
  fi
done

control_op=""
forward_spec=""
master_start=0
while (($#)); do
  case "$1" in
    -O) control_op="${2:-}"; shift 2 ;;
    -L) forward_spec="${2:-}"; shift 2 ;;
    -M) master_start=1; shift ;;
    -S|-p|-i|-o) shift 2 ;;
    -f|-N|-n|-T|-q) shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

case "$control_op" in
  check)
    [[ -f "$state/master" ]] || exit 255
    exit 0
    ;;
  exit)
    rm -f "$state/master"
    exit 0
    ;;
  forward)
    [[ -f "$state/master" ]] || exit 255
    local_port="${forward_spec#*:}"
    local_port="${local_port%%:*}"
    for busy in ${FAKE_BUSY_LOCAL_PORTS:-}; do
      if [[ "$busy" == "$local_port" ]]; then
        echo "bind [127.0.0.1]:$local_port: Address already in use" >&2
        exit 255
      fi
    done
    printf '%s\n' "$forward_spec" >>"$state/forwards.log"
    exit 0
    ;;
esac

if (( master_start )); then
  : >"$state/master"
  exit 0
fi

# Any ordinary command using the established master is the remote discovery probe.
[[ -f "$state/master" ]] || exit 255
target="${1:-}"; shift || true
if [[ "${FAKE_EXEC_REMOTE:-0}" == "1" ]]; then
  # OpenSSH sends a remote command string to the login shell; model that
  # reparse instead of exec'ing the local argv vector directly.
  remote_command="$*"
  printf '%s\n' "$remote_command" >"$state/remote-command.log"
  /bin/bash -c "$remote_command"
  exit $?
fi
cat >/dev/null || true
printf '%s\n' ${FAKE_REMOTE_PORTS:-}
FAKE
  chmod +x "$bin_dir/ssh"
}

new_case() {
  local name="$1"
  CASE="$TMP_ROOT/$name"
  mkdir -p "$CASE/bin" "$CASE/state-home" "$CASE/fake-ssh"
  make_fake_ssh "$CASE/bin"
  export PATH="$CASE/bin:$ORIGINAL_PATH"
  export FAKE_SSH_STATE_DIR="$CASE/fake-ssh"
  export XDG_STATE_HOME="$CASE/state-home"
  export TMPDIR="$CASE"
  unset XDG_RUNTIME_DIR KAGGLE_CONNECT_CONTROL_DIR KAGGLE_CONNECT_CONTROL_PATH || true
  export KAGGLE_CONNECT_PROFILE="test"
  export KAGGLE_SSH_TARGET="kaggle"
  export KAGGLE_FORWARD_PORTS="6379 5432 6333"
  export KAGGLE_EXTRA_PORTS=""
  export KAGGLE_PORT_MAPS=""
  unset FAKE_BUSY_LOCAL_PORTS FAKE_EXEC_REMOTE KAGGLE_REMOTE_PROJECT_DIR KAGGLE_REMOTE_WORKING_DIR || true
  unset KAGGLE_SSH_CONNECT_TIMEOUT || true
}

ORIGINAL_PATH="$PATH"

# 1. First start creates one master and forwards only currently-listening configured ports.
new_case first_start
export FAKE_REMOTE_PORTS="6379"
"$SCRIPT" start >/dev/null
[[ -f "$CASE/fake-ssh/master" ]] || fail "master was not created"
assert_file_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:6379:127.0.0.1:6379"
count="$(wc -l < "$CASE/fake-ssh/forwards.log" | tr -d ' ')"
assert_eq "$count" "1"

# 2. Re-running start is incremental: old forward remains; only the newly-listening port is added.
export FAKE_REMOTE_PORTS="6379 5432"
"$SCRIPT" start >/dev/null
assert_file_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:6379:127.0.0.1:6379"
assert_file_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:5432:127.0.0.1:5432"
count="$(wc -l < "$CASE/fake-ssh/forwards.log" | tr -d ' ')"
assert_eq "$count" "2"

# 3. A third identical start is idempotent and does not add duplicate forwards.
"$SCRIPT" start >/dev/null
count="$(wc -l < "$CASE/fake-ssh/forwards.log" | tr -d ' ')"
assert_eq "$count" "2"

# 4. stop terminates the master and clears tracked forwards.
"$SCRIPT" stop >/dev/null
[[ ! -f "$CASE/fake-ssh/master" ]] || fail "master still exists after stop"
state_file="$(find "$CASE/state-home" -name forwards.tsv -print -quit)"
[[ -n "$state_file" ]] || fail "forwards state file was not created"
[[ ! -s "$state_file" ]] || fail "forwards state file was not cleared by stop"

# 5. restart discards old forwards and re-discovers only services currently listening.
new_case restart
export FAKE_REMOTE_PORTS="6379 5432"
"$SCRIPT" start >/dev/null
export FAKE_REMOTE_PORTS="6333"
"$SCRIPT" restart >/dev/null
state_file="$(find "$CASE/state-home" -name forwards.tsv -print -quit)"
assert_file_contains "$state_file" $'6333\t6333'
assert_file_not_contains "$state_file" $'6379\t6379'
assert_file_not_contains "$state_file" $'5432\t5432'

# 6. Per-port mapping allows a cloud IDE local port to differ from Kaggle's remote port.
new_case mapped
export FAKE_REMOTE_PORTS="5432"
export KAGGLE_PORT_MAPS="15432:5432"
"$SCRIPT" start >/dev/null
assert_file_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:15432:127.0.0.1:5432"
state_file="$(find "$CASE/state-home" -name forwards.tsv -print -quit)"
assert_file_contains "$state_file" $'15432\t5432'

# 7. A failed local bind is reported and is not recorded as active state.
new_case bind_failure
export FAKE_REMOTE_PORTS="6379 5432"
export FAKE_BUSY_LOCAL_PORTS="5432"
set +e
"$SCRIPT" start >"$CASE/out" 2>"$CASE/err"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "start should fail when one requested local port cannot bind"
state_file="$(find "$CASE/state-home" -name forwards.tsv -print -quit)"
assert_file_contains "$state_file" $'6379\t6379'
assert_file_not_contains "$state_file" $'5432\t5432'
grep -Fq "5432" "$CASE/err" || fail "bind failure did not identify port 5432"

# 8. status succeeds while master is running and fails after stop.
new_case status
export FAKE_REMOTE_PORTS="6379"
"$SCRIPT" start >/dev/null
"$SCRIPT" status >"$CASE/status-up"
grep -Fq "RUNNING" "$CASE/status-up" || fail "status did not report RUNNING"
"$SCRIPT" stop >/dev/null
set +e
"$SCRIPT" status >"$CASE/status-down"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "status should be non-zero when master is stopped"
grep -Fq "STOPPED" "$CASE/status-down" || fail "status did not report STOPPED"

# 9. Auto-discovery forwards only configured ports that are actually listening,
#    and honors the project's user override file rather than stale defaults.
new_case auto_discovery
export KAGGLE_FORWARD_PORTS=""
export FAKE_EXEC_REMOTE=1
project="$CASE/remote-project"
mkdir -p "$project/config" "$project/install/lib"
cat >"$project/config/defaults.env" <<'CFG'
REDIS_PORT_8_10_0=6379
POSTGRES_PORT_18=5433
QDRANT_PORT_1_18_3=6333
CFG
cat >"$project/.kaggle-dev.env" <<'CFG'
POSTGRES_PORT_18=15433
CFG
cat >"$project/install/lib/load-config.sh" <<'LIB'
load_project_config() {
  local root="$1"
  set -a
  source "$root/config/defaults.env"
  [[ ! -f "$root/.kaggle-dev.env" ]] || source "$root/.kaggle-dev.env"
  set +a
}
LIB
cat >"$CASE/bin/ss" <<'SS'
#!/usr/bin/env bash
cat <<'OUT'
LISTEN 0 128 127.0.0.1:6379 0.0.0.0:*
LISTEN 0 128 127.0.0.1:15433 0.0.0.0:*
LISTEN 0 128 127.0.0.1:9999 0.0.0.0:*
OUT
SS
chmod +x "$CASE/bin/ss"
export KAGGLE_REMOTE_PROJECT_DIR="$project"
"$SCRIPT" start >/dev/null
assert_file_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:6379:127.0.0.1:6379"
assert_file_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:15433:127.0.0.1:15433"
assert_file_not_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:5433:127.0.0.1:5433"
assert_file_not_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:9999:127.0.0.1:9999"

# 10. Help is informational and must work even when OpenSSH is not installed yet.
new_case help_without_ssh
rm -f "$CASE/bin/ssh"
PATH="$CASE/bin:$ORIGINAL_PATH" /bin/bash "$SCRIPT" --help >"$CASE/help"
grep -Fq "Usage:" "$CASE/help" || fail "help output is missing usage text"

# 11. status distinguishes a tracked forward whose Kaggle service has stopped.
new_case status_remote_stopped
export FAKE_REMOTE_PORTS="6379"
"$SCRIPT" start >/dev/null
export FAKE_REMOTE_PORTS=""
"$SCRIPT" status >"$CASE/status-stopped-remote"
grep -Fq "[NOT-LISTENING]" "$CASE/status-stopped-remote" || fail "status should mark a stopped remote service as NOT-LISTENING"

# 12. Without a client-side project path, auto-discovery resolves the checkout
#     on the remote Kaggle filesystem and never expects its config locally.
new_case remote_project_discovery
export KAGGLE_FORWARD_PORTS=""
export FAKE_EXEC_REMOTE=1
export KAGGLE_REMOTE_WORKING_DIR="$CASE/remote-working"
project="$KAGGLE_REMOTE_WORKING_DIR/custom-checkout"
mkdir -p "$project/config" "$project/install/lib"
cat >"$project/config/defaults.env" <<'CFG'
POSTGRES_PORT_18=15433
CFG
cat >"$project/install/lib/load-config.sh" <<'LIB'
load_project_config() {
  local root="$1"
  set -a
  source "$root/config/defaults.env"
  set +a
}
LIB
cat >"$CASE/bin/ss" <<'SS'
#!/usr/bin/env bash
printf '%s\n' 'LISTEN 0 128 127.0.0.1:15433 0.0.0.0:*'
SS
chmod +x "$CASE/bin/ss"
"$SCRIPT" start >/dev/null
assert_file_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:15433:127.0.0.1:15433"

# 13. Multiple remote checkouts are ambiguous; fail closed instead of choosing
#     an arbitrary project/config tree.
new_case ambiguous_remote_projects
export KAGGLE_FORWARD_PORTS=""
export FAKE_EXEC_REMOTE=1
export KAGGLE_REMOTE_WORKING_DIR="$CASE/remote-working"
for project in "$KAGGLE_REMOTE_WORKING_DIR/checkout-a" "$KAGGLE_REMOTE_WORKING_DIR/checkout-b"; do
  mkdir -p "$project/config" "$project/install/lib"
  printf '%s\n' 'POSTGRES_PORT_18=15433' >"$project/config/defaults.env"
  cat >"$project/install/lib/load-config.sh" <<'LIB'
load_project_config() { :; }
LIB
done
set +e
"$SCRIPT" start >"$CASE/out" 2>"$CASE/err"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "ambiguous remote project discovery should fail"
grep -Fq "Multiple Kaggle Development Kit checkouts found" "$CASE/err" || fail "ambiguity error was not reported"

# 14. Explicit ports survive the real OpenSSH command-string boundary even when
#     the remote project hint is empty and the port list contains spaces.
new_case explicit_ports_survive_reparse
export KAGGLE_FORWARD_PORTS="5433 6379 6333"
export KAGGLE_REMOTE_WORKING_DIR="$CASE/remote-working"
mkdir -p "$KAGGLE_REMOTE_WORKING_DIR"
export FAKE_EXEC_REMOTE=1
cat >"$CASE/bin/ss" <<'SS'
#!/usr/bin/env bash
cat <<'OUT'
LISTEN 0 128 127.0.0.1:5433 0.0.0.0:*
LISTEN 0 128 127.0.0.1:6379 0.0.0.0:*
LISTEN 0 128 127.0.0.1:6333 0.0.0.0:*
OUT
SS
chmod +x "$CASE/bin/ss"
"$SCRIPT" start >/dev/null
assert_file_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:5433:127.0.0.1:5433"
assert_file_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:6379:127.0.0.1:6379"
assert_file_contains "$CASE/fake-ssh/forwards.log" "127.0.0.1:6333:127.0.0.1:6333"

# 15. A configured candidate that is not listening is a valid empty discovery
#     result and must not fail merely because pipefail is enabled remotely.
new_case no_listening_is_success
export KAGGLE_FORWARD_PORTS="5433"
export FAKE_EXEC_REMOTE=1
project="$CASE/remote-project"
mkdir -p "$project/config" "$project/install/lib"
printf '%s\n' 'POSTGRES_PORT_18=5433' >"$project/config/defaults.env"
cat >"$project/install/lib/load-config.sh" <<'LIB'
load_project_config() { :; }
LIB
export KAGGLE_REMOTE_PROJECT_DIR="$project"
cat >"$CASE/bin/ss" <<'SS'
#!/usr/bin/env bash
exit 0
SS
chmod +x "$CASE/bin/ss"
"$SCRIPT" start >"$CASE/out" 2>"$CASE/err"
grep -Fq 'no configured candidate service is currently listening' "$CASE/out" || fail "empty discovery was not treated as success"

# 16. Generated ControlMaster sockets live in a private per-user directory
#     (mode 0700) instead of a shared-world TMPDIR root.
new_case private_control_dir_default
unset KAGGLE_CONNECT_CONTROL_DIR KAGGLE_CONNECT_CONTROL_PATH XDG_RUNTIME_DIR || true
export FAKE_REMOTE_PORTS="6379"
"$SCRIPT" start >/dev/null
ctl_uid="$(id -u)"
test_hash="$(printf '%s' test | cksum | awk '{print $1}')"
default_base="$CASE/kaggle-connect-$ctl_uid"
[[ -d "$default_base" ]] || fail "private control directory was not created at $default_base"
assert_eq "$(stat -c '%a' "$default_base")" "700"
control_file="$(find "$CASE/state-home" -name control-path -print -quit)"
[[ -n "$control_file" ]] || fail "control-path metadata was not created"
assert_eq "$(cat "$control_file")" "$default_base/$test_hash.sock"

# 17. An explicit KAGGLE_CONNECT_CONTROL_PATH is still honored verbatim for
#     environments that manage their own socket location.
new_case custom_control_path
export KAGGLE_CONNECT_CONTROL_PATH="$CASE/custom-sockets/custom.sock"
export FAKE_REMOTE_PORTS="6379"
"$SCRIPT" start >/dev/null
control_file="$(find "$CASE/state-home" -name control-path -print -quit)"
assert_eq "$(cat "$control_file")" "$CASE/custom-sockets/custom.sock"

# 18. A symlink at the private directory path is rejected: an attacker must not
#     be able to relocate the ControlMaster socket via a pre-planted link.
new_case control_dir_symlink
unset KAGGLE_CONNECT_CONTROL_DIR KAGGLE_CONNECT_CONTROL_PATH XDG_RUNTIME_DIR || true
symlink_base="$CASE/kaggle-connect-$ctl_uid"
mkdir -p "$CASE/evil-target"
ln -s "$CASE/evil-target" "$symlink_base"
set +e
"$SCRIPT" start >"$CASE/out" 2>"$CASE/err"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "start should fail when the control directory is a symlink"
grep -Fq 'symlink' "$CASE/err" || fail "symlink rejection was not reported"
[[ ! -f "$CASE/evil-target/$test_hash.sock" ]] || fail "socket was created inside the symlink target"

# 19. A regular file occupying the private directory path is rejected.
new_case control_dir_not_dir
unset KAGGLE_CONNECT_CONTROL_DIR KAGGLE_CONNECT_CONTROL_PATH XDG_RUNTIME_DIR || true
file_base="$CASE/kaggle-connect-$ctl_uid"
: >"$file_base"
set +e
"$SCRIPT" start >"$CASE/out" 2>"$CASE/err"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "start should fail when the control directory path is a file"
grep -Fq 'not a directory' "$CASE/err" || fail "non-directory rejection was not reported"

# 20. A widened private directory mode is tightened back to 0700 on start.
new_case control_dir_mode_tightened
unset KAGGLE_CONNECT_CONTROL_DIR KAGGLE_CONNECT_CONTROL_PATH XDG_RUNTIME_DIR || true
tight_base="$CASE/kaggle-connect-$ctl_uid"
mkdir -m 755 "$tight_base"
export FAKE_REMOTE_PORTS="6379"
"$SCRIPT" start >/dev/null
assert_eq "$(stat -c '%a' "$tight_base")" "700"

# 21. XDG_RUNTIME_DIR is the parent of a dedicated child directory, not a
#     string suffix: base must be $XDG_RUNTIME_DIR/kaggle-connect.
new_case xdg_runtime_base
export XDG_RUNTIME_DIR="$CASE/runtime"
export FAKE_REMOTE_PORTS="6379"
"$SCRIPT" start >/dev/null
xdg_base="$CASE/runtime/kaggle-connect"
[[ -d "$xdg_base" ]] || fail "XDG control directory was not created at $xdg_base"
assert_eq "$(stat -c '%a' "$xdg_base")" "700"
control_file="$(find "$CASE/state-home" -name control-path -print -quit)"
[[ -n "$control_file" ]] || fail "control-path metadata was not created"
assert_eq "$(cat "$control_file")" "$xdg_base/$test_hash.sock"
[[ ! -e "$CASE/runtime-$ctl_uid" ]] || fail "broken runtime-uid path was used instead of an XDG child directory"

# 22. status is observational: a fresh profile reports STOPPED without creating
#     any state directory, metadata file, or control directory.
new_case status_nonmutating
unset KAGGLE_CONNECT_CONTROL_DIR KAGGLE_CONNECT_CONTROL_PATH XDG_RUNTIME_DIR || true
set +e
"$SCRIPT" status >"$CASE/status-fresh.out" 2>"$CASE/status-fresh.err"
fresh_rc=$?
set -e
[[ "$fresh_rc" -ne 0 ]] || fail "status of a fresh profile should be non-zero"
grep -Fq "STOPPED" "$CASE/status-fresh.out" || fail "fresh profile status did not report STOPPED"
[[ ! -e "$CASE/state-home/kaggle-connect/$test_hash" ]] || fail "status created per-profile state metadata"
[[ ! -e "$CASE/kaggle-connect-$ctl_uid" ]] || fail "status created the generated control directory"

# 23. stop manages the STORED session independently of the current desired
#     SSH configuration: an invalid KAGGLE_SSH_PORT must not prevent teardown
#     of a live stored ControlMaster.
new_case stop_invalid_current_port
export FAKE_REMOTE_PORTS="6379"
export KAGGLE_SSH_PORT=""
"$SCRIPT" start >/dev/null
master_file="$CASE/fake-ssh/master"
[[ -f "$master_file" ]] || fail "stored master missing before invalid-current-port stop"

set +e
KAGGLE_SSH_PORT=not-a-port "$SCRIPT" stop >"$CASE/out" 2>"$CASE/err"
stop_rc=$?
set -e
[[ "$stop_rc" -eq 0 ]] || fail "stop must succeed despite an invalid current KAGGLE_SSH_PORT"
[[ ! -f "$master_file" ]] || fail "stored master was not stopped with an invalid current port"
state_file="$(find "$CASE/state-home" -name forwards.tsv -print -quit)"
[[ ! -s "$state_file" ]] || fail "tracked forwards were not cleared by invalid-current-port stop"
control_meta="$(find "$CASE/state-home" -name control-path -print -quit)"
[[ ! -s "$control_meta" ]] || fail "control-path metadata was not cleared by invalid-current-port stop"
grep -Fq -- "-O exit" "$CASE/fake-ssh/calls.log" || fail "stop did not send an exit through the stored control path"

# 24. status degrades safely when the CURRENT desired configuration is
#     malformed: a live stored master still reports RUNNING/UNKNOWN exit-zero
#     without mutation instead of dying on desired-port validation.
new_case status_invalid_current_port
export FAKE_REMOTE_PORTS="6379"
export KAGGLE_SSH_PORT=""
"$SCRIPT" start >/dev/null
master_file="$CASE/fake-ssh/master"
[[ -f "$master_file" ]] || fail "stored master missing before invalid-current-port status"
state_file="$(find "$CASE/state-home" -name forwards.tsv -print -quit)"
cp "$state_file" "$CASE/forwards-before.tsv"
endpoint_meta="$(find "$CASE/state-home" -name endpoint -print -quit)"
ep_before="$(cat "$endpoint_meta")"
control_meta="$(find "$CASE/state-home" -name control-path -print -quit)"
ctl_before="$(cat "$control_meta")"

set +e
KAGGLE_SSH_PORT=not-a-port "$SCRIPT" status >"$CASE/out" 2>"$CASE/err"
st_rc=$?
set -e
[[ "$st_rc" -eq 0 ]] || fail "status must stay exit-zero for a live stored master despite invalid current KAGGLE_SSH_PORT"
grep -Fq "RUNNING" "$CASE/out" || fail "invalid-current-port status lost RUNNING"
grep -Fq "Lifecycle state: UNKNOWN" "$CASE/out" || fail "invalid-current-port status did not degrade to UNKNOWN"
grep -Fq "ssh|root|example.invalid|22" "$CASE/out" || fail "invalid-current-port status hid the stored endpoint"
assert_file_not_contains "$CASE/out" "Desired endpoint:"
cmp -s "$CASE/forwards-before.tsv" "$state_file" || fail "invalid-current-port status mutated tracked forwards"
assert_eq "$(cat "$endpoint_meta")" "$ep_before" || fail "invalid-current-port status mutated endpoint metadata"
assert_eq "$(cat "$control_meta")" "$ctl_before" || fail "invalid-current-port status mutated control-path metadata"
[[ -f "$master_file" ]] || fail "invalid-current-port status disturbed the stored master"

# 25. With no managed master, a malformed current desired port still yields
#     STOPPED-style reporting, stays non-mutating, and exits non-zero.
"$SCRIPT" stop >/dev/null
new_case status_invalid_port_fresh
export FAKE_REMOTE_PORTS=""
export KAGGLE_SSH_PORT=""
set +e
KAGGLE_SSH_PORT=not-a-port "$SCRIPT" status >"$CASE/out" 2>"$CASE/err"
fresh_rc=$?
set -e
[[ "$fresh_rc" -ne 0 ]] || fail "status of a fresh profile should stay non-zero with invalid current KAGGLE_SSH_PORT"
grep -Fq "STOPPED" "$CASE/out" || fail "fresh invalid-current-port status did not report STOPPED"
[[ ! -e "$CASE/state-home/kaggle-connect/$test_hash" ]] || fail "fresh invalid-current-port status created per-profile state"

# stop must use only mux-control-safe options for an already-owned session:
# malformed current connection-only options must not orphan the master.
new_case stop_invalid_connect_timeout
export FAKE_REMOTE_PORTS="6379"

"$SCRIPT" start >/dev/null

master_file="$CASE/fake-ssh/master"
[[ -f "$master_file" ]] ||
  fail "stored master missing before malformed-timeout stop"

set +e
KAGGLE_SSH_CONNECT_TIMEOUT=not-a-time \
  "$SCRIPT" stop >"$CASE/out" 2>"$CASE/err"
timeout_stop_rc=$?
set -e

[[ "$timeout_stop_rc" -eq 0 ]] ||
  fail "stop must succeed despite malformed current KAGGLE_SSH_CONNECT_TIMEOUT"

[[ ! -f "$master_file" ]] ||
  fail "stored master was orphaned by malformed current ConnectTimeout"

state_file="$(find "$CASE/state-home" -name forwards.tsv -print -quit)"
[[ ! -s "$state_file" ]] ||
  fail "tracked forwards were not cleared by malformed-timeout stop"

grep -Fq -- "-O exit" "$CASE/fake-ssh/calls.log" ||
  fail "stop never sent mux exit with malformed current ConnectTimeout"

# status must observe the stored mux independently of malformed current
# connection-only options, while desired-endpoint reporting degrades.
new_case status_invalid_connect_timeout
export FAKE_REMOTE_PORTS="6379"

"$SCRIPT" start >/dev/null

master_file="$CASE/fake-ssh/master"
[[ -f "$master_file" ]] ||
  fail "stored master missing before malformed-timeout status"

state_file="$(find "$CASE/state-home" -name forwards.tsv -print -quit)"
endpoint_meta="$(find "$CASE/state-home" -name endpoint -print -quit)"
control_meta="$(find "$CASE/state-home" -name control-path -print -quit)"

cp "$state_file" "$CASE/forwards-before.tsv"
ep_before="$(cat "$endpoint_meta")"
ctl_before="$(cat "$control_meta")"

set +e
KAGGLE_SSH_CONNECT_TIMEOUT=not-a-time \
  "$SCRIPT" status >"$CASE/out" 2>"$CASE/err"
timeout_status_rc=$?
set -e

[[ "$timeout_status_rc" -eq 0 ]] ||
  fail "status must remain exit-zero while the stored master is live"

grep -Fq 'SSH ControlMaster: RUNNING' "$CASE/out" ||
  fail "malformed-timeout status lost RUNNING"

grep -Fq 'Lifecycle state: UNKNOWN' "$CASE/out" ||
  fail "malformed-timeout status must degrade desired endpoint to UNKNOWN"

grep -Fq 'Stored endpoint:' "$CASE/out" ||
  fail "malformed-timeout status hid stored endpoint"

if grep -Fq 'Desired endpoint:' "$CASE/out"; then
  fail "malformed-timeout status reported a desired endpoint that could not be resolved"
fi

cmp -s "$CASE/forwards-before.tsv" "$state_file" ||
  fail "malformed-timeout status mutated forwards"

assert_eq "$(cat "$endpoint_meta")" "$ep_before"
assert_eq "$(cat "$control_meta")" "$ctl_before"

[[ -f "$master_file" ]] ||
  fail "malformed-timeout status disturbed the stored master"

printf 'PASS: connect-kaggle.sh behavioral tests\n'
