#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/connect-kaggle.sh"
TMP_ROOT="$(mktemp -d)"
trap '[[ "${KEEP_TMP:-0}" == "1" ]] || rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state" "$TMP_ROOT/tmp" "$TMP_ROOT/fake"

cat >"$TMP_ROOT/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_SSH_STATE_DIR:?}"

# Model `ssh -G`: OpenSSH resolves the effective destination without dialing.
for ssh_arg in "$@"; do
  if [[ "$ssh_arg" == "-G" ]]; then
    if [[ "${FAKE_SSH_G_FAIL:-0}" == "1" ]]; then
      exit 3
    fi
    printf 'user %s\n' "${FAKE_SSH_G_USER:-root}"
    printf 'hostname %s\n' "${FAKE_SSH_G_HOSTNAME:-example.invalid}"
    printf 'port %s\n' "${FAKE_SSH_G_PORT:-22}"
    exit 0
  fi
done

control=""
control_op=""
forward_spec=""
master_start=0
while (($#)); do
  case "$1" in
    -S) control="${2:-}"; shift 2 ;;
    -O) control_op="${2:-}"; shift 2 ;;
    -L) forward_spec="${2:-}"; shift 2 ;;
    -M) master_start=1; shift ;;
    -p|-i|-o) shift 2 ;;
    -f|-N|-n|-T|-q) shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

owner_file() { printf '%s/owners.tsv\n' "$state"; }
remove_owner() {
  local tmp="$(owner_file).tmp.$$"
  [[ -f "$(owner_file)" ]] || return 0
  awk -F '\t' -v c="$control" '$2 != c' "$(owner_file)" >"$tmp" || true
  mv -f "$tmp" "$(owner_file)"
}

# Sticky mode lets a single named control socket ignore or defer its exit
# request, modeling a master that is slow to die or refuses to die while every
# other control socket keeps the immediate-exit behavior.
is_sticky_control() {
  [[ -n "${FAKE_SSH_STICKY_CONTROL:-}" && "$control" == "$FAKE_SSH_STICKY_CONTROL" ]]
}
delay_file() {
  printf '%s/delay-%s\n' "$state" "$(printf '%s' "$control" | cksum | awk '{print $1}')"
}

# Every control-socket operation is logged so tests can prove WHICH persisted
# path (stored vs desired) received it.
if [[ -n "$control_op" ]]; then
  printf '%s\t%s\n' "$control_op" "$control" >>"$state/ops.log"
fi

case "$control_op" in
  check)
    delay_path="$(delay_file)"
    if [[ -f "$delay_path" ]]; then
      remaining="$(cat "$delay_path")"
      remaining=$((remaining - 1))
      if (( remaining <= 0 )); then
        rm -f -- "$delay_path"
        remove_owner
        rm -f -- "$control"
        exit 255
      fi
      printf '%s' "$remaining" >"$delay_path"
      exit 0
    fi
    [[ -n "$control" && -f "$control" ]] || exit 255
    exit 0
    ;;
  exit)
    if is_sticky_control && [[ "${FAKE_SSH_STICKY_MODE:-fail}" == "fail" ]]; then
      # A sticky master ignores the exit request and stays alive.
      exit 1
    fi
    if is_sticky_control && [[ "${FAKE_SSH_STICKY_MODE:-}" == "delay" ]]; then
      printf '%s' "${FAKE_SSH_EXIT_DELAY:-3}" >"$(delay_file)"
      exit 0
    fi
    if [[ "${FAKE_SSH_EXIT_FAILS:-0}" == "1" ]]; then
      # Model a master that ignores the exit request and stays alive.
      exit 1
    fi
    remove_owner
    rm -f -- "$control"
    exit 0
    ;;
  forward)
    [[ -n "$control" && -f "$control" ]] || exit 255
    local_port="${forward_spec#*:}"
    local_port="${local_port%%:*}"
    if [[ -f "$(owner_file)" ]] && awk -F '\t' -v p="$local_port" '$1 == p { found=1 } END { exit(found ? 0 : 1) }' "$(owner_file)"; then
      exit 255
    fi
    printf '%s\t%s\n' "$local_port" "$control" >>"$(owner_file)"
    exit 0
    ;;
esac

if (( master_start )); then
  mkdir -p "$(dirname "$control")"
  : >"$control"
  exit 0
fi

printf '%s\n' ${FAKE_REMOTE_PORTS:-}
FAKE
chmod +x "$TMP_ROOT/bin/ssh" "$SCRIPT"

run_connect() {
  local profile="$1" host="$2" port="$3" action="$4"
  shift 4
  local -a mode_env=()
  if [[ -n "$host" ]]; then
    # Direct mode: mirror the CLI endpoint into the fake resolver so the
    # canonical key reflects the actual destination being dialed.
    mode_env=(
      KAGGLE_SSH_HOST="$host"
      KAGGLE_SSH_PORT="$port"
      FAKE_SSH_G_USER="${FAKE_SSH_G_USER:-root}"
      FAKE_SSH_G_HOSTNAME="$host"
      FAKE_SSH_G_PORT="$port"
    )
  fi
  env \
    PATH="$TMP_ROOT/bin:$PATH" \
    FAKE_SSH_STATE_DIR="$TMP_ROOT/fake" \
    XDG_STATE_HOME="$TMP_ROOT/state" \
    TMPDIR="$TMP_ROOT/tmp" \
    KAGGLE_CONNECT_CONTROL_DIR="$TMP_ROOT/tmp/kaggle-connect-$(id -u)" \
    KAGGLE_CONNECT_PROFILE="$profile" \
    KAGGLE_FORWARD_PORTS="6333 6379" \
    FAKE_REMOTE_PORTS="6333 6379" \
    KAGGLE_SSH_IDENTITY_FILE="" \
    "${mode_env[@]}" \
    "$@" \
    "$SCRIPT" "$action"
}

ctl_base() { printf '%s/tmp/kaggle-connect-%s' "$TMP_ROOT" "$(id -u)"; }
socket_for() { printf '%s/%s.sock' "$(ctl_base)" "$(printf '%s' "$1" | cksum | awk '{print $1}')"; }

run_connect profile-a 0.tcp.ngrok.io 13468 start >/dev/null

run_connect profile-other other.tcp.ngrok.io 24567 start >/dev/null 2>&1 || true
other_socket="$(socket_for profile-other)"
[[ -f "$other_socket" ]] || { echo 'FAIL: different-endpoint master missing before restart' >&2; exit 1; }

awk -F '\t' -v c="$other_socket" '$2 != c' "$TMP_ROOT/fake/owners.tsv" >"$TMP_ROOT/fake/owners.tmp" || true
mv "$TMP_ROOT/fake/owners.tmp" "$TMP_ROOT/fake/owners.tsv"

set +e
run_connect profile-b 0.tcp.ngrok.io 13468 restart >"$TMP_ROOT/restart.out" 2>"$TMP_ROOT/restart.err"
rc=$?
set -e
if (( rc != 0 )); then
  cat "$TMP_ROOT/restart.out" >&2 || true
  cat "$TMP_ROOT/restart.err" >&2 || true
  echo "FAIL: same-endpoint sibling cleanup did not make restart self-contained (rc=$rc)" >&2
  exit 1
fi

profile_a_hash="$(printf '%s' profile-a | cksum | awk '{print $1}')"
profile_a_socket="$(socket_for profile-a)"
[[ ! -f "$profile_a_socket" ]] || { echo 'FAIL: sibling master on same endpoint was not stopped' >&2; exit 1; }
[[ -f "$other_socket" ]] || { echo 'FAIL: different-endpoint master was stopped' >&2; exit 1; }

grep -Fq '127.0.0.1:6333' "$TMP_ROOT/restart.out" || { echo 'FAIL: 6333 was not forwarded after cleanup' >&2; exit 1; }
grep -Fq '127.0.0.1:6379' "$TMP_ROOT/restart.out" || { echo 'FAIL: 6379 was not forwarded after cleanup' >&2; exit 1; }

run_connect profile-b 0.tcp.ngrok.io 13468 stop >/dev/null
printf '6333\tFOREIGN\n' >>"$TMP_ROOT/fake/owners.tsv"
set +e
run_connect profile-c 0.tcp.ngrok.io 13468 restart >"$TMP_ROOT/foreign.out" 2>"$TMP_ROOT/foreign.err"
foreign_rc=$?
set -e
(( foreign_rc != 0 )) || { echo 'FAIL: restart should fail when a foreign process owns a requested port' >&2; exit 1; }
awk -F '\t' '$1 == "6333" && $2 == "FOREIGN" { found=1 } END { exit(found ? 0 : 1) }' "$TMP_ROOT/fake/owners.tsv" || {
  echo 'FAIL: restart removed a foreign local-port owner' >&2
  exit 1
}
grep -Fq 'Could not bind local port 6333' "$TMP_ROOT/foreign.err" || {
  echo 'FAIL: foreign bind failure was not reported' >&2
  exit 1
}

# 4. A managed ControlMaster that refuses to exit must keep its management
#    state: stop fails closed instead of discarding a live master's metadata.
: >"$TMP_ROOT/fake/owners.tsv"
run_connect profile-sd 0.tcp.ngrok.io 13468 start >/dev/null
sd_hash="$(printf '%s' profile-sd | cksum | awk '{print $1}')"
sd_socket="$(socket_for profile-sd)"
sd_state="$TMP_ROOT/state/kaggle-connect/$sd_hash"
[[ -f "$sd_socket" ]] || { echo 'FAIL: shutdown-test master missing after start' >&2; exit 1; }
[[ -s "$sd_state/forwards.tsv" ]] || { echo 'FAIL: shutdown-test profile has no tracked forwards' >&2; exit 1; }
cp "$sd_state/forwards.tsv" "$TMP_ROOT/sd-forwards-before.tsv"

set +e
FAKE_SSH_EXIT_FAILS=1 run_connect profile-sd 0.tcp.ngrok.io 13468 stop \
  >"$TMP_ROOT/sd-stop.out" 2>"$TMP_ROOT/sd-stop.err"
stop_rc=$?
set -e

(( stop_rc != 0 )) || { echo 'FAIL: stop should fail when the ControlMaster cannot be stopped' >&2; exit 1; }
grep -Fq 'Could not stop SSH ControlMaster' "$TMP_ROOT/sd-stop.err" || {
  echo 'FAIL: failed shutdown did not explain that state is preserved' >&2
  exit 1
}
[[ -f "$sd_socket" ]] || { echo 'FAIL: control socket was discarded while master is still alive' >&2; exit 1; }
[[ -s "$sd_state/endpoint" ]] || { echo 'FAIL: endpoint metadata was discarded on failed shutdown' >&2; exit 1; }
[[ -s "$sd_state/control-path" ]] || { echo 'FAIL: control-path metadata was discarded on failed shutdown' >&2; exit 1; }
[[ -s "$sd_state/profile" ]] || { echo 'FAIL: profile metadata was discarded on failed shutdown' >&2; exit 1; }
cmp -s "$TMP_ROOT/sd-forwards-before.tsv" "$sd_state/forwards.tsv" || {
  echo 'FAIL: tracked forwards were modified on failed shutdown' >&2
  exit 1
}

# 5. An alias retargeted to a different ngrok session is a DIFFERENT physical
#    endpoint even though the alias string is identical: restarting under the
#    retargeted alias must not stop the old session's managed master.
: >"$TMP_ROOT/fake/owners.tsv"
run_connect profile-r1 "" "" start KAGGLE_SSH_TARGET=kaggle-shared \
  FAKE_SSH_G_HOSTNAME=0.tcp.ngrok.io FAKE_SSH_G_PORT=13468 >/dev/null
r1_hash="$(printf '%s' profile-r1 | cksum | awk '{print $1}')"
r1_socket="$(socket_for profile-r1)"
[[ -f "$r1_socket" ]] || { echo 'FAIL: retarget-test initial master missing after start' >&2; exit 1; }

set +e
run_connect profile-r2 "" "" restart KAGGLE_SSH_TARGET=kaggle-shared \
  FAKE_SSH_G_HOSTNAME=2.tcp.ngrok.io FAKE_SSH_G_PORT=18765 \
  >"$TMP_ROOT/r2.out" 2>"$TMP_ROOT/r2.err"
set -e
if grep -Fq 'Stopping managed sibling SSH ControlMaster for profile profile-r1' \
  "$TMP_ROOT/r2.out" "$TMP_ROOT/r2.err"; then
  echo 'FAIL: alias retargeted to another ngrok session was treated as the same endpoint' >&2
  exit 1
fi
[[ -f "$r1_socket" ]] || { echo 'FAIL: restart through a retargeted alias stopped the old physical endpoint' >&2; exit 1; }

# 6. Different aliases resolving to the SAME destination are managed siblings:
#    restart must clean the sibling master and take over the local ports.
: >"$TMP_ROOT/fake/owners.tsv"
run_connect profile-s1 "" "" start KAGGLE_SSH_TARGET=kaggle-alpha \
  FAKE_SSH_G_HOSTNAME=0.tcp.ngrok.io FAKE_SSH_G_PORT=13468 >/dev/null
s1_hash="$(printf '%s' profile-s1 | cksum | awk '{print $1}')"
s1_socket="$(socket_for profile-s1)"
[[ -f "$s1_socket" ]] || { echo 'FAIL: sibling-test initial master missing after start' >&2; exit 1; }

set +e
run_connect profile-s2 "" "" restart KAGGLE_SSH_TARGET=kaggle-beta \
  FAKE_SSH_G_HOSTNAME=0.tcp.ngrok.io FAKE_SSH_G_PORT=13468 \
  >"$TMP_ROOT/s2.out" 2>"$TMP_ROOT/s2.err"
s2_rc=$?
set -e
if (( s2_rc != 0 )); then
  cat "$TMP_ROOT/s2.out" >&2 || true
  cat "$TMP_ROOT/s2.err" >&2 || true
  echo "FAIL: same-resolved-destination restart failed (rc=$s2_rc)" >&2
  exit 1
fi
grep -Fq 'Stopping managed sibling SSH ControlMaster for profile profile-s1' "$TMP_ROOT/s2.out" || {
  echo 'FAIL: different aliases to one destination were not matched as siblings' >&2
  exit 1
}
[[ ! -f "$s1_socket" ]] || { echo 'FAIL: same-destination sibling master was not stopped' >&2; exit 1; }
grep -Fq '127.0.0.1:6379' "$TMP_ROOT/s2.out" || { echo 'FAIL: sibling takeover did not re-bind forwarded port' >&2; exit 1; }

# 7. Direct mode ignores identity-file paths when matching endpoints: the key
#    material is authentication config, not part of the network destination.
: >"$TMP_ROOT/fake/owners.tsv"
printf 'dummy-key-material-a\n' >"$TMP_ROOT/key-a"
printf 'dummy-key-material-b\n' >"$TMP_ROOT/key-b"
chmod 600 "$TMP_ROOT/key-a" "$TMP_ROOT/key-b"
run_connect profile-d1 0.tcp.ngrok.io 13468 start KAGGLE_SSH_IDENTITY_FILE="$TMP_ROOT/key-a" >/dev/null
d1_hash="$(printf '%s' profile-d1 | cksum | awk '{print $1}')"
d1_socket="$(socket_for profile-d1)"
[[ -f "$d1_socket" ]] || { echo 'FAIL: identity-test initial master missing after start' >&2; exit 1; }

set +e
run_connect profile-d2 0.tcp.ngrok.io 13468 restart KAGGLE_SSH_IDENTITY_FILE="$TMP_ROOT/key-b" \
  >"$TMP_ROOT/d2.out" 2>"$TMP_ROOT/d2.err"
d2_rc=$?
set -e
if (( d2_rc != 0 )); then
  cat "$TMP_ROOT/d2.out" >&2 || true
  cat "$TMP_ROOT/d2.err" >&2 || true
  echo "FAIL: same destination with a different identity file failed restart (rc=$d2_rc)" >&2
  exit 1
fi
grep -Fq 'Stopping managed sibling SSH ControlMaster for profile profile-d1' "$TMP_ROOT/d2.out" || {
  echo 'FAIL: identity-file path leaked into endpoint identity' >&2
  exit 1
}
[[ ! -f "$d1_socket" ]] || { echo 'FAIL: same-endpoint sibling with different identity file was not stopped' >&2; exit 1; }

# 8. Same-profile retarget A->B: 'start' is non-destructive and refuses while
#    the stored session is alive; 'restart' is the explicit replacement that
#    stops the stored master, starts the desired one, and relabels metadata.
: >"$TMP_ROOT/fake/owners.tsv"
run_connect profile-h 0.tcp.ngrok.io 13468 start >/dev/null
h_hash="$(printf '%s' profile-h | cksum | awk '{print $1}')"
h_socket="$(socket_for profile-h)"
h_state="$TMP_ROOT/state/kaggle-connect/$h_hash"
[[ -f "$h_socket" ]] || { echo 'FAIL: retarget initial master missing after start' >&2; exit 1; }
h_key_a="$(cat "$h_state/endpoint")"

set +e
run_connect profile-h 3.tcp.ngrok.io 19999 start \
  >"$TMP_ROOT/h-start.out" 2>"$TMP_ROOT/h-start.err"
h_rc=$?
set -e
(( h_rc != 0 )) || { echo 'FAIL: non-destructive start must refuse a live endpoint retarget' >&2; exit 1; }
grep -Fq "non-destructive" "$TMP_ROOT/h-start.err" || {
  echo 'FAIL: retargeted start did not explain it is non-destructive' >&2
  exit 1
}
grep -Fq 'restart' "$TMP_ROOT/h-start.err" || {
  echo 'FAIL: retargeted start did not recommend restart' >&2
  exit 1
}
[[ -f "$h_socket" ]] || { echo 'FAIL: refused start disturbed the existing master' >&2; exit 1; }
[[ "$(cat "$h_state/endpoint")" == "$h_key_a" ]] || {
  echo 'FAIL: refused start rewrote stored endpoint metadata' >&2
  exit 1
}

run_connect profile-h 3.tcp.ngrok.io 19999 restart \
  >"$TMP_ROOT/h-restart.out" 2>"$TMP_ROOT/h-restart.err"
h_restart_rc=$?
if (( h_restart_rc != 0 )); then
  cat "$TMP_ROOT/h-restart.out" >&2 || true
  cat "$TMP_ROOT/h-restart.err" >&2 || true
  echo "FAIL: explicit restart must replace the live stored session A->B (rc=$h_restart_rc)" >&2
  exit 1
fi
[[ -f "$(socket_for profile-h)" ]] || { echo 'FAIL: desired master missing after replacement restart' >&2; exit 1; }
h_key_b="$(cat "$h_state/endpoint")"
[[ "$h_key_b" != "$h_key_a" ]] || { echo 'FAIL: restart did not relabel the stored endpoint to B' >&2; exit 1; }
grep -Fq 'ssh|root|3.tcp.ngrok.io|19999' "$h_state/endpoint" || {
  echo 'FAIL: stored endpoint is not the desired destination B' >&2
  exit 1
}
[[ -f "$h_state/control-path" ]] || { echo 'FAIL: control-path metadata missing after restart' >&2; exit 1; }
awk -F '\t' '$1 == "exit" { seen=1 } END { exit(seen ? 0 : 1) }' "$TMP_ROOT/fake/ops.log" || {
  echo 'FAIL: replacement restart never sent an exit to the stored control path' >&2
  exit 1
}
grep -Fq '127.0.0.1:6333' "$TMP_ROOT/h-restart.out" || {
  echo 'FAIL: forwards were not rebound after replacement' >&2
  exit 1
}
run_connect profile-h 3.tcp.ngrok.io 19999 stop >/dev/null
[[ ! -f "$(socket_for profile-h)" ]] || { echo 'FAIL: stop after replacement did not remove the master' >&2; exit 1; }

# 9. A same-endpoint sibling that takes a few poll cycles to terminate must be
#    waited for: restart succeeds only after the sibling is really gone.
: >"$TMP_ROOT/fake/owners.tsv"
run_connect profile-y1 0.tcp.ngrok.io 13468 start >/dev/null
y1_hash="$(printf '%s' profile-y1 | cksum | awk '{print $1}')"
y1_socket="$(socket_for profile-y1)"
[[ -f "$y1_socket" ]] || { echo 'FAIL: delayed-sibling initial master missing after start' >&2; exit 1; }

set +e
FAKE_SSH_STICKY_CONTROL="$y1_socket" FAKE_SSH_STICKY_MODE=delay FAKE_SSH_EXIT_DELAY=3 \
  run_connect profile-y2 0.tcp.ngrok.io 13468 restart \
  >"$TMP_ROOT/y2.out" 2>"$TMP_ROOT/y2.err"
y2_rc=$?
set -e
if (( y2_rc != 0 )); then
  cat "$TMP_ROOT/y2.out" >&2 || true
  cat "$TMP_ROOT/y2.err" >&2 || true
  echo "FAIL: restart did not wait for a slow-to-die same-endpoint sibling (rc=$y2_rc)" >&2
  exit 1
fi
grep -Fq 'Stopping managed sibling SSH ControlMaster for profile profile-y1' "$TMP_ROOT/y2.out" || {
  echo 'FAIL: delayed-sibling restart did not target the sibling master' >&2
  exit 1
}
[[ ! -f "$y1_socket" ]] || { echo 'FAIL: delayed sibling socket survived a successful restart' >&2; exit 1; }
grep -Fq '127.0.0.1:6333' "$TMP_ROOT/y2.out" || {
  echo 'FAIL: restart did not take over forwards after waiting for the delayed sibling' >&2
  exit 1
}

# 10. A same-endpoint sibling that refuses to die must abort the restart:
#     its state stays untouched and no new session is started on top of it.
: >"$TMP_ROOT/fake/owners.tsv"
run_connect profile-n1 0.tcp.ngrok.io 13468 start >/dev/null
n1_hash="$(printf '%s' profile-n1 | cksum | awk '{print $1}')"
n1_socket="$(socket_for profile-n1)"
n1_state="$TMP_ROOT/state/kaggle-connect/$n1_hash"
[[ -f "$n1_socket" ]] || { echo 'FAIL: stubborn-sibling initial master missing after start' >&2; exit 1; }
cp "$n1_state/endpoint" "$TMP_ROOT/n1-endpoint-before"

set +e
FAKE_SSH_STICKY_CONTROL="$n1_socket" FAKE_SSH_STICKY_MODE=fail \
  run_connect profile-n2 0.tcp.ngrok.io 13468 restart \
  >"$TMP_ROOT/n2.out" 2>"$TMP_ROOT/n2.err"
n2_rc=$?
set -e

(( n2_rc != 0 )) || { echo 'FAIL: restart must fail when a same-endpoint sibling refuses to stop' >&2; exit 1; }
grep -Fq 'leaving its state untouched' "$TMP_ROOT/n2.err" || {
  echo 'FAIL: stubborn-sibling failure was not reported' >&2
  exit 1
}
[[ -f "$n1_socket" ]] || { echo 'FAIL: stubborn sibling socket was discarded while still alive' >&2; exit 1; }
cmp -s "$TMP_ROOT/n1-endpoint-before" "$n1_state/endpoint" || {
  echo 'FAIL: stubborn sibling endpoint metadata was modified' >&2
  exit 1
}
[[ -f "$n1_state/control-path" ]] || { echo 'FAIL: stubborn sibling control-path metadata was removed' >&2; exit 1; }
! grep -Fq 'Forward sync complete' "$TMP_ROOT/n2.out" || {
  echo 'FAIL: restart proceeded with start after a failed sibling cleanup' >&2
  exit 1
}

# 11. Stale recovery: stored metadata whose master has DIED must not block a
#     later start against a different desired endpoint.
: >"$TMP_ROOT/fake/owners.tsv"
run_connect profile-stale 0.tcp.ngrok.io 13468 start >/dev/null
stale_socket="$(socket_for profile-stale)"
stale_state="$TMP_ROOT/state/kaggle-connect/$(printf '%s' profile-stale | cksum | awk '{print $1}')"
[[ -f "$stale_socket" ]] || { echo 'FAIL: stale-test master missing after start' >&2; exit 1; }
# Simulate the master process dying while its metadata stays behind.
rm -f -- "$stale_socket"
awk -F '\t' -v c="$stale_socket" '$2 != c' "$TMP_ROOT/fake/owners.tsv" >"$TMP_ROOT/fake/owners.tmp" || true
mv "$TMP_ROOT/fake/owners.tmp" "$TMP_ROOT/fake/owners.tsv"

run_connect profile-stale 3.tcp.ngrok.io 19999 start \
  >"$TMP_ROOT/stale-start.out" 2>"$TMP_ROOT/stale-start.err"
stale_rc=$?
if (( stale_rc != 0 )); then
  cat "$TMP_ROOT/stale-start.out" >&2 || true
  cat "$TMP_ROOT/stale-start.err" >&2 || true
  echo "FAIL: dead stored master must not block starting the desired session (rc=$stale_rc)" >&2
  exit 1
fi
grep -Fq 'ssh|root|3.tcp.ngrok.io|19999' "$stale_state/endpoint" || {
  echo 'FAIL: stale endpoint metadata was not replaced by the desired endpoint' >&2
  exit 1
}
[[ -f "$(socket_for profile-stale)" ]] || { echo 'FAIL: desired master missing after stale recovery' >&2; exit 1; }
run_connect profile-stale 3.tcp.ngrok.io 19999 stop >/dev/null

# 12. Path-policy change with a live stored master: start REUSES the persisted
#     control path (and routes discovery/forwards through it) instead of
#     silently replacing it with the newly computed desired path.
: >"$TMP_ROOT/fake/owners.tsv"
legacy_a="$TMP_ROOT/tmp/legacy-migrate-a.sock"
run_connect profile-mig 0.tcp.ngrok.io 13468 start KAGGLE_CONNECT_CONTROL_PATH="$legacy_a" >/dev/null
[[ -f "$legacy_a" ]] || { echo 'FAIL: legacy master missing after explicit-path start' >&2; exit 1; }
mig_state="$TMP_ROOT/state/kaggle-connect/$(printf '%s' profile-mig | cksum | awk '{print $1}')"
[[ "$(cat "$mig_state/control-path")" == "$legacy_a" ]] || {
  echo 'FAIL: control-path metadata does not record the legacy path' >&2
  exit 1
}

run_connect profile-mig 0.tcp.ngrok.io 13468 start KAGGLE_EXTRA_PORTS="8080" \
  FAKE_REMOTE_PORTS="6333 6379 8080" \
  >"$TMP_ROOT/mig-reuse.out" 2>"$TMP_ROOT/mig-reuse.err"
mig_reuse_rc=$?
if (( mig_reuse_rc != 0 )); then
  cat "$TMP_ROOT/mig-reuse.err" >&2 || true
  echo "FAIL: start must reuse a live stored master after a path-policy change (rc=$mig_reuse_rc)" >&2
  exit 1
fi
[[ -f "$legacy_a" ]] || { echo 'FAIL: reused legacy master was replaced by start' >&2; exit 1; }
[[ ! -f "$(socket_for profile-mig)" ]] || {
  echo 'FAIL: start created a second desired-path master instead of reusing the stored one' >&2
  exit 1
}
last_forward_target="$(awk -F '\t' '$1 == "forward" { last=$2 } END { print last }' "$TMP_ROOT/fake/ops.log")"
[[ "$last_forward_target" == "$legacy_a" ]] || {
  echo "FAIL: incremental forward used '$last_forward_target' instead of the active stored path" >&2
  exit 1
}
[[ "$(cat "$mig_state/control-path")" == "$legacy_a" ]] || {
  echo 'FAIL: start silently relabeled ownership to the desired path' >&2
  exit 1
}

# 13. restart is the migration boundary: it stops the live legacy-path master,
#     verifies termination, and starts the newly computed generated path.
run_connect profile-mig 0.tcp.ngrok.io 13468 restart \
  >"$TMP_ROOT/mig-restart.out" 2>"$TMP_ROOT/mig-restart.err"
mig_restart_rc=$?
if (( mig_restart_rc != 0 )); then
  cat "$TMP_ROOT/mig-restart.out" >&2 || true
  cat "$TMP_ROOT/mig-restart.err" >&2 || true
  echo "FAIL: restart must migrate a live legacy ControlPath to the new policy (rc=$mig_restart_rc)" >&2
  exit 1
fi
[[ ! -f "$legacy_a" ]] || { echo 'FAIL: legacy master survived a migrating restart' >&2; exit 1; }
[[ -f "$(socket_for profile-mig)" ]] || { echo 'FAIL: desired-path master missing after migration' >&2; exit 1; }
exit_targets="$(awk -F '\t' '$1 == "exit" { print $2 }' "$TMP_ROOT/fake/ops.log")"
rtk_found_legacy_exit=0
while IFS= read -r target; do
  [[ "$target" == "$legacy_a" ]] && rtk_found_legacy_exit=1
done <<<"$exit_targets"
(( rtk_found_legacy_exit )) || { echo 'FAIL: migration restart never exited the legacy control path' >&2; exit 1; }
[[ "$(cat "$mig_state/control-path")" == "$(socket_for profile-mig)" ]] || {
  echo 'FAIL: control-path metadata did not migrate to the desired path' >&2
  exit 1
}
grep -Fq '127.0.0.1:6333' "$TMP_ROOT/mig-restart.out" || {
  echo 'FAIL: forwards were not rebound on the new path after migration' >&2
  exit 1
}
run_connect profile-mig 0.tcp.ngrok.io 13468 stop >/dev/null

# 14. stop targets the PERSISTED control path even when the current path
#     policy computes something else, and never starts a desired master.
: >"$TMP_ROOT/fake/owners.tsv"
legacy_b="$TMP_ROOT/tmp/legacy-stop.sock"
run_connect profile-sp 0.tcp.ngrok.io 13468 start KAGGLE_CONNECT_CONTROL_PATH="$legacy_b" >/dev/null
[[ -f "$legacy_b" ]] || { echo 'FAIL: stop-test legacy master missing after start' >&2; exit 1; }

run_connect profile-sp 0.tcp.ngrok.io 13468 stop >/dev/null
sp_stop_rc=$?
if (( sp_stop_rc != 0 )); then
  echo "FAIL: stop must tear down the stored session regardless of path policy (rc=$sp_stop_rc)" >&2
  exit 1
fi
[[ ! -f "$legacy_b" ]] || { echo 'FAIL: stored legacy master was not stopped by stop' >&2; exit 1; }
[[ ! -f "$(socket_for profile-sp)" ]] || {
  echo 'FAIL: stop created or left a desired-path master behind' >&2
  exit 1
}
stop_check_targets="$(awk -F '\t' '$1 == "check" { print $2 }' "$TMP_ROOT/fake/ops.log")"
rtk_seen_stored_check=0
while IFS= read -r target; do
  [[ "$target" == "$legacy_b" ]] && rtk_seen_stored_check=1
done <<<"$stop_check_targets"
(( rtk_seen_stored_check )) || { echo 'FAIL: stop never probed the persisted control path' >&2; exit 1; }

# 15. stop is independent of fresh authentication: a deleted identity file and
#     a failing `ssh -G` must not prevent teardown of the stored master.
: >"$TMP_ROOT/fake/owners.tsv"
id_key="$TMP_ROOT/tmp/id-key"
printf 'dummy-key-material\n' >"$id_key"
chmod 600 "$id_key"
run_connect profile-id 0.tcp.ngrok.io 13468 start KAGGLE_SSH_IDENTITY_FILE="$id_key" >/dev/null
id_socket="$(socket_for profile-id)"
[[ -f "$id_socket" ]] || { echo 'FAIL: identity-test master missing after start' >&2; exit 1; }
rm -f -- "$id_key"

set +e
FAKE_SSH_G_FAIL=1 run_connect profile-id 0.tcp.ngrok.io 13468 stop \
  >"$TMP_ROOT/id-stop.out" 2>"$TMP_ROOT/id-stop.err"
id_stop_rc=$?
set -e
if (( id_stop_rc != 0 )); then
  cat "$TMP_ROOT/id-stop.out" >&2 || true
  cat "$TMP_ROOT/id-stop.err" >&2 || true
  echo "FAIL: stop must not require the old identity file or ssh -G (rc=$id_stop_rc)" >&2
  exit 1
fi
[[ ! -f "$id_socket" ]] || { echo 'FAIL: stored master was not stopped without the identity file' >&2; exit 1; }

# 16. status reports lifecycle labels without mutating anything: a live
#     retargeted profile reports RETARGETED with both endpoints.
: >"$TMP_ROOT/fake/owners.tsv"
run_connect profile-r3 0.tcp.ngrok.io 13468 start >/dev/null
r3_state="$TMP_ROOT/state/kaggle-connect/$(printf '%s' profile-r3 | cksum | awk '{print $1}')"
r3_key="$(cat "$r3_state/endpoint")"

set +e
run_connect profile-r3 3.tcp.ngrok.io 19999 status \
  >"$TMP_ROOT/r3-status.out" 2>"$TMP_ROOT/r3-status.err"
r3_status_rc=$?
set -e
if (( r3_status_rc != 0 )); then
  cat "$TMP_ROOT/r3-status.out" >&2 || true
  echo "FAIL: status of a live managed master must stay exit-zero (rc=$r3_status_rc)" >&2
  exit 1
fi
grep -Fq 'RUNNING' "$TMP_ROOT/r3-status.out" || { echo 'FAIL: retargeted status lost RUNNING' >&2; exit 1; }
grep -Fq 'RETARGETED' "$TMP_ROOT/r3-status.out" || {
  echo 'FAIL: status did not label a live retargeted profile as RETARGETED' >&2
  exit 1
}
grep -Fq 'ssh|root|0.tcp.ngrok.io|13468' "$TMP_ROOT/r3-status.out" || {
  echo 'FAIL: status did not show the stored endpoint' >&2
  exit 1
}
grep -Fq 'ssh|root|3.tcp.ngrok.io|19999' "$TMP_ROOT/r3-status.out" || {
  echo 'FAIL: status did not show the desired endpoint' >&2
  exit 1
}
[[ "$(cat "$r3_state/endpoint")" == "$r3_key" ]] || {
  echo 'FAIL: status mutated stored endpoint metadata' >&2
  exit 1
}

# 17. Destructive ordering: an invalid desired ControlPath directory aborts
#     restart BEFORE the healthy stored session is stopped.
: >"$TMP_ROOT/fake/owners.tsv"
run_connect profile-pf 0.tcp.ngrok.io 13468 start >/dev/null
pf_socket="$(socket_for profile-pf)"
pf_state="$TMP_ROOT/state/kaggle-connect/$(printf '%s' profile-pf | cksum | awk '{print $1}')"
pf_key="$(cat "$pf_state/endpoint")"
[[ -f "$pf_socket" ]] || { echo 'FAIL: preflight-test master missing after start' >&2; exit 1; }

ln -sfn "$TMP_ROOT/no-such-target" "$TMP_ROOT/tmp/pf-link-dir"
set +e
run_connect profile-pf 0.tcp.ngrok.io 13468 restart KAGGLE_CONNECT_CONTROL_DIR="$TMP_ROOT/tmp/pf-link-dir" \
  >"$TMP_ROOT/pf-restart.out" 2>"$TMP_ROOT/pf-restart.err"
pf_rc=$?
set -e
(( pf_rc != 0 )) || { echo 'FAIL: restart must fail when the desired control dir is a symlink' >&2; exit 1; }
grep -Fq 'symlink' "$TMP_ROOT/pf-restart.err" || {
  echo 'FAIL: symlink rejection was not reported for the desired control dir' >&2
  exit 1
}
[[ -f "$pf_socket" ]] || { echo 'FAIL: invalid desired path destroyed the healthy stored session' >&2; exit 1; }
[[ "$(cat "$pf_state/endpoint")" == "$pf_key" ]] || {
  echo 'FAIL: aborted restart modified stored endpoint metadata' >&2
  exit 1
}
run_connect profile-pf 0.tcp.ngrok.io 13468 stop >/dev/null

# 18. Partial-state recovery: a LIVE desired-path master whose ownership
#     metadata (endpoint, control-path, profile) was lost must never be
#     silently orphaned by restart. Restart is the explicit replacement
#     boundary, so it must send the live socket an exit, verify termination,
#     and only then start the fresh desired session.
: >"$TMP_ROOT/fake/owners.tsv"
run_connect profile-lu 4.tcp.ngrok.io 24444 start >/dev/null
lu_socket="$(socket_for profile-lu)"
lu_state="$TMP_ROOT/state/kaggle-connect/$(printf '%s' profile-lu | cksum | awk '{print $1}')"
[[ -f "$lu_socket" ]] || { echo 'FAIL: untracked-restart initial master missing after start' >&2; exit 1; }

rm -f -- "$lu_state/endpoint" "$lu_state/control-path" "$lu_state/profile"

set +e
run_connect profile-lu 4.tcp.ngrok.io 24444 restart \
  >"$TMP_ROOT/lu.out" 2>"$TMP_ROOT/lu.err"
lu_rc=$?
set -e
if (( lu_rc != 0 )); then
  cat "$TMP_ROOT/lu.out" >&2 || true
  cat "$TMP_ROOT/lu.err" >&2 || true
  echo "FAIL: verified teardown-and-replace of an untracked live desired master failed (rc=$lu_rc)" >&2
  exit 1
fi
awk -F '\t' -v t="$lu_socket" '$1 == "exit" && $2 == t { seen=1 } END { exit(seen ? 0 : 1) }' "$TMP_ROOT/fake/ops.log" || {
  echo 'FAIL: restart discarded a live untracked ControlMaster without sending it an exit' >&2
  exit 1
}
[[ -f "$(socket_for profile-lu)" ]] || { echo 'FAIL: replacement master missing after untracked-master recovery' >&2; exit 1; }
[[ "$(cat "$lu_state/control-path")" == "$lu_socket" ]] || {
  echo 'FAIL: ownership metadata was not rebuilt after untracked-master recovery' >&2
  exit 1
}
grep -Fq '127.0.0.1:6333' "$TMP_ROOT/lu.out" || {
  echo 'FAIL: forwards were not rebound after untracked-master recovery' >&2
  exit 1
}

# 19. A newly created ControlMaster is a NEW multiplexing session and must
#     begin with EMPTY forward bookkeeping: stale forwards.tsv rows from a
#     previous dead session must neither produce a false 'Keeping ...' state
#     nor suppress real -O forward operations for the fresh master.
: >"$TMP_ROOT/fake/owners.tsv"
sf_profile="profile-sf"
sf_state="$TMP_ROOT/state/kaggle-connect/$(printf '%s' "$sf_profile" | cksum | awk '{print $1}')"
mkdir -p "$sf_state"
printf '15432\t6333\n16379\t6379\n' >"$sf_state/forwards.tsv"
chmod 600 "$sf_state/forwards.tsv"

set +e
run_connect "$sf_profile" 5.tcp.ngrok.io 25555 start \
  >"$TMP_ROOT/sf.out" 2>"$TMP_ROOT/sf.err"
sf_rc=$?
set -e
if (( sf_rc != 0 )); then
  cat "$TMP_ROOT/sf.out" >&2 || true
  cat "$TMP_ROOT/sf.err" >&2 || true
  echo "FAIL: start with stale forward bookkeeping failed (rc=$sf_rc)" >&2
  exit 1
fi
sf_socket="$(socket_for "$sf_profile")"
sf_forward_count=0
while IFS= read -r forward_target; do
  [[ "$forward_target" == "$sf_socket" ]] && sf_forward_count=$((sf_forward_count + 1))
done < <(awk -F '\t' '$1 == "forward" { print $2 }' "$TMP_ROOT/fake/ops.log")
(( sf_forward_count == 2 )) || {
  echo "FAIL: expected 2 real forward operations for the new master, got $sf_forward_count" >&2
  exit 1
}
if grep -Fq 'Keeping' "$TMP_ROOT/sf.out"; then
  echo 'FAIL: stale bookkeeping produced a false Keeping state for a brand-new master' >&2
  exit 1
fi
grep -Fq 'Added   127.0.0.1:6333 -> Kaggle 127.0.0.1:6333' "$TMP_ROOT/sf.out" || {
  echo 'FAIL: discovered ports were not really forwarded for the new master' >&2
  exit 1
}
grep -Fq $'6333\t6333' "$sf_state/forwards.tsv" || {
  echo 'FAIL: fresh forward tracking missing after start' >&2
  exit 1
}
if grep -Fq $'15432\t6333' "$sf_state/forwards.tsv"; then
  echo 'FAIL: stale forward bookkeeping survived creation of a new master' >&2
  exit 1
fi
run_connect "$sf_profile" 5.tcp.ngrok.io 25555 stop >/dev/null

# 20. Destructive ordering: a live untracked master at the newly computed
#     DESIRED ControlPath must abort restart BEFORE the healthy STORED master
#     is touched -- a tracked session is never sacrificed for a replacement
#     path already known to be occupied.
: >"$TMP_ROOT/fake/owners.tsv"
conflict_a="$TMP_ROOT/tmp/conflict-a.sock"
run_connect profile-co 6.tcp.ngrok.io 26666 start KAGGLE_CONNECT_CONTROL_PATH="$conflict_a" >/dev/null
co_state="$TMP_ROOT/state/kaggle-connect/$(printf '%s' profile-co | cksum | awk '{print $1}')"
[[ -f "$conflict_a" ]] || { echo 'FAIL: conflict-test stored master missing after start' >&2; exit 1; }
cp "$co_state/forwards.tsv" "$TMP_ROOT/co-forwards-before.tsv"
co_key="$(cat "$co_state/endpoint")"

conflict_b="$(socket_for profile-co)"
mkdir -p "$(dirname "$conflict_b")"
: >"$conflict_b"

set +e
run_connect profile-co 6.tcp.ngrok.io 26666 restart \
  >"$TMP_ROOT/co.out" 2>"$TMP_ROOT/co.err"
co_rc=$?
set -e

(( co_rc != 0 )) || { echo 'FAIL: restart must fail closed when the desired ControlPath is already occupied' >&2; exit 1; }
[[ -f "$conflict_a" ]] || { echo 'FAIL: healthy stored master A was destroyed by the conflicted restart' >&2; exit 1; }
[[ -f "$conflict_b" ]] || { echo 'FAIL: untracked desired-path master B was auto-stopped by restart' >&2; exit 1; }
[[ "$(cat "$co_state/endpoint")" == "$co_key" ]] || {
  echo 'FAIL: conflicted restart rewrote stored endpoint metadata' >&2
  exit 1
}
[[ -s "$co_state/control-path" ]] || { echo 'FAIL: conflicted restart removed control-path metadata' >&2; exit 1; }
cmp -s "$TMP_ROOT/co-forwards-before.tsv" "$co_state/forwards.tsv" || {
  echo 'FAIL: conflicted restart modified tracked forward bookkeeping' >&2
  exit 1
}
awk -F '\t' -v t_a="$conflict_a" -v t_b="$conflict_b" '
  ($1 == "exit" && ($2 == t_a || $2 == t_b)) { n++ }
  END { exit(n == 0 ? 0 : 1) }
' "$TMP_ROOT/fake/ops.log" || {
  echo 'FAIL: conflicted restart sent an exit to stored master A or untracked master B' >&2
  exit 1
}
grep -Fq 'already occupied' "$TMP_ROOT/co.err" || {
  echo 'FAIL: desired-path occupancy conflict was not reported' >&2
  exit 1
}
if grep -Fq 'Forward sync complete' "$TMP_ROOT/co.out"; then
  echo 'FAIL: conflicted restart proceeded into starting a fresh session' >&2
  exit 1
fi
run_connect profile-co 6.tcp.ngrok.io 26666 stop >/dev/null

# One-shot stale-owner recovery: stale STORED metadata for a DEAD A must
# be cleared from both disk and in-process STORED_* state so a LIVE
# untracked DESIRED B can be explicitly replaced in this SAME restart
# invocation. A second restart must not be required.
: >"$TMP_ROOT/fake/owners.tsv"

os_profile="profile-one-shot"
os_a="$TMP_ROOT/tmp/one-shot-stored-a.sock"

run_connect "$os_profile" 7.tcp.ngrok.io 27777 start \
  KAGGLE_CONNECT_CONTROL_PATH="$os_a" >/dev/null

os_state="$TMP_ROOT/state/kaggle-connect/$(printf '%s' "$os_profile" | cksum | awk '{print $1}')"

[[ -f "$os_a" ]] || {
  echo 'FAIL: one-shot recovery stored master A missing after start' >&2
  exit 1
}

[[ "$(cat "$os_state/control-path")" == "$os_a" ]] || {
  echo 'FAIL: one-shot recovery did not persist stored path A' >&2
  exit 1
}

# Simulate A dying while its ownership metadata remains stale.
rm -f -- "$os_a"

awk -F '\t' -v c="$os_a" '$2 != c' \
  "$TMP_ROOT/fake/owners.tsv" >"$TMP_ROOT/fake/owners.tmp" || true
mv "$TMP_ROOT/fake/owners.tmp" "$TMP_ROOT/fake/owners.tsv"

# Current policy now resolves to B. Model a live master at B without
# changing this profile's stale ownership metadata: B is untracked.
os_b="$(socket_for "$os_profile")"
mkdir -p "$(dirname "$os_b")"
: >"$os_b"

set +e
run_connect "$os_profile" 8.tcp.ngrok.io 28888 restart \
  >"$TMP_ROOT/os.out" 2>"$TMP_ROOT/os.err"
os_rc=$?
set -e

if (( os_rc != 0 )); then
  cat "$TMP_ROOT/os.out" >&2 || true
  cat "$TMP_ROOT/os.err" >&2 || true
  echo "FAIL: stale A + live untracked B must recover in one restart invocation (rc=$os_rc)" >&2
  exit 1
fi

awk -F '\t' -v t="$os_b" '
  $1 == "exit" && $2 == t { seen=1 }
  END { exit(seen ? 0 : 1) }
' "$TMP_ROOT/fake/ops.log" || {
  echo 'FAIL: one-shot restart never explicitly stopped live untracked B' >&2
  exit 1
}

[[ -f "$os_b" ]] || {
  echo 'FAIL: fresh desired master B missing after one-shot recovery' >&2
  exit 1
}

[[ "$(cat "$os_state/control-path")" == "$os_b" ]] || {
  echo 'FAIL: control-path metadata was not rebuilt for B' >&2
  exit 1
}

grep -Fqx 'ssh|root|8.tcp.ngrok.io|28888' "$os_state/endpoint" || {
  echo 'FAIL: endpoint metadata was not rebuilt for desired endpoint B' >&2
  exit 1
}

grep -Fq 'Forward sync complete' "$TMP_ROOT/os.out" || {
  echo 'FAIL: one-shot recovery did not rebuild forwards' >&2
  exit 1
}

echo 'PASS: restart cleans same-endpoint managed siblings and preserves foreign owners'
