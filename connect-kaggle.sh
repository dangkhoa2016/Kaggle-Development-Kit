#!/usr/bin/env bash
set -euo pipefail

# Stateful local-port manager for a Kaggle SSH session.
#
# Run this script on the LOCAL development machine / cloud IDE (Codespaces,
# Google Cloud Shell Editor, Gitpod-like VS Code environments, etc.), not on
# Kaggle. It uses only Bash + the OpenSSH client locally. The Kaggle side is
# expected to be reachable through a user-configured local `kaggle` SSH host
# alias, or through the KAGGLE_SSH_* environment variables below. setup.sh runs
# on Kaggle: it can print connection information, but it cannot modify this
# local machine's ~/.ssh/config.

PROGRAM="${0##*/}"
ACTION="${1:-start}"

KAGGLE_CONNECT_PROFILE="${KAGGLE_CONNECT_PROFILE:-kaggle}"
KAGGLE_SSH_TARGET="${KAGGLE_SSH_TARGET:-kaggle}"
KAGGLE_SSH_HOST="${KAGGLE_SSH_HOST:-}"
KAGGLE_SSH_USER="${KAGGLE_SSH_USER:-root}"
KAGGLE_SSH_PORT="${KAGGLE_SSH_PORT:-}"
KAGGLE_SSH_IDENTITY_FILE="${KAGGLE_SSH_IDENTITY_FILE:-}"
KAGGLE_SSH_HOST_KEY_ALIAS="${KAGGLE_SSH_HOST_KEY_ALIAS:-kaggle-notebook}"
KAGGLE_SSH_CONNECT_TIMEOUT="${KAGGLE_SSH_CONNECT_TIMEOUT:-12}"

# Optional REMOTE path hint. Empty means resolve the project on the Kaggle machine.
KAGGLE_REMOTE_PROJECT_DIR="${KAGGLE_REMOTE_PROJECT_DIR:-}"
# Remote search root used only on Kaggle when the project hint is empty.
KAGGLE_REMOTE_WORKING_DIR="${KAGGLE_REMOTE_WORKING_DIR:-/kaggle/working}"
# Empty = discover ports from Kaggle-Development-Kit's effective config.
# Non-empty = explicit candidate ports, e.g. "6379 5432 6333".
KAGGLE_FORWARD_PORTS="${KAGGLE_FORWARD_PORTS:-}"
# Extra ports are added to either discovery mode, e.g. "3000 8000 7860".
KAGGLE_EXTRA_PORTS="${KAGGLE_EXTRA_PORTS:-}"
# Optional LOCAL:REMOTE overrides, e.g. "15432:5432 16379:6379".
KAGGLE_PORT_MAPS="${KAGGLE_PORT_MAPS:-}"

STATE_HOME="${KAGGLE_CONNECT_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/kaggle-connect}"
PROFILE_HASH="$(printf '%s' "$KAGGLE_CONNECT_PROFILE" | cksum | awk '{print $1}')"
STATE_DIR="$STATE_HOME/$PROFILE_HASH"
STATE_FILE="$STATE_DIR/forwards.tsv"
SESSION_ENDPOINT_FILE="$STATE_DIR/endpoint"
SESSION_CONTROL_FILE="$STATE_DIR/control-path"
SESSION_PROFILE_FILE="$STATE_DIR/profile"

# Lifecycle state vocabulary:
#   STORED_*  describes the managed session this profile already owns
#             (read only from STATE_DIR metadata).
#   DESIRED_* describes what the CURRENT invocation resolves to
#             (endpoint via ssh -G, ControlPath via current policy).
#   ACTIVE_CONTROL_PATH is the socket discovery and forward synchronization
#             actually use; it is set only after a master is known to be alive.
STORED_ENDPOINT=""
STORED_CONTROL_PATH=""
DESIRED_ENDPOINT=""
DESIRED_CONTROL_PATH=""
DESIRED_CONTROL_BASE=""
ACTIVE_CONTROL_PATH=""
STATUS_DESIRED_INVALID=0
SSH_ERR_LOG="${TMPDIR:-/tmp}/kaggle-connect-ssh-err-$$.log"
trap 'rm -f "$SSH_ERR_LOG" 2>/dev/null || true' EXIT

log() { printf '[kaggle-connect] %s\n' "$*"; }
warn() { printf '[kaggle-connect] WARNING: %s\n' "$*" >&2; }
die() { printf '[kaggle-connect] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
Usage:
  connect-kaggle.sh start
  connect-kaggle.sh status
  connect-kaggle.sh stop
  connect-kaggle.sh restart

Default connection mode:
  Uses the standard OpenSSH host alias `kaggle` from ~/.ssh/config.

Direct connection mode (no SSH alias required):
  KAGGLE_SSH_HOST=0.tcp.eu.ngrok.io \
  KAGGLE_SSH_PORT=26345 \
  KAGGLE_SSH_IDENTITY_FILE=~/.ssh/id_ed25519 \
  ./connect-kaggle.sh start

Port discovery:
  By default the script resolves the project checkout on the Kaggle machine,
  then loads its config/defaults.env plus .kaggle-dev.env, finds configured
  PostgreSQL/Redis/Elastic/Qdrant ports, and forwards only ports that are
  actually LISTENING on Kaggle. No Kaggle project/config directory is read
  from the local VS Code/Codespaces filesystem.

  If multiple checkouts exist under /kaggle/working, specify the REMOTE path:
    KAGGLE_REMOTE_PROJECT_DIR=/kaggle/working/my-checkout ./connect-kaggle.sh start

  Override discovery completely:
    KAGGLE_FORWARD_PORTS="6379 5432 6333" ./connect-kaggle.sh start

  Add arbitrary app ports to auto-discovery:
    KAGGLE_EXTRA_PORTS="3000 8000 7860" ./connect-kaggle.sh start

  Remap local ports when a cloud IDE already uses the same port:
    KAGGLE_PORT_MAPS="15432:5432 16379:6379" ./connect-kaggle.sh start

Important behavior:
  * start is incremental, idempotent, and non-destructive: it never replaces a
    live managed session. A live stored session on a different SSH endpoint is
    refused; run restart to replace it deliberately.
  * Running start again adds newly-listening ports without removing old ones.
  * stop tears down the STORED managed session through its persisted control
    path and does not require the current alias, keys, or endpoint to match.
  * restart is the explicit replacement boundary: it stops this profile's
    stored master, verifies termination, cleans managed sibling masters on the
    DESIRED endpoint, then performs fresh discovery + start. Masters for other
    endpoints and unrelated local processes are never terminated.
  * All local forwards bind to 127.0.0.1 only.
HELP
}

case "$ACTION" in
  help|-h|--help)
    usage
    exit 0
    ;;
  start|stop|restart|status)
    ;;
  *)
    usage >&2
    die "Unknown action: $ACTION"
    ;;
esac

# The ControlMaster socket directory must be a real, private directory: no
# symlink indirection (a planted link could relocate the socket) and never a
# group/world-readable mode on a multi-user machine.
ensure_private_control_dir() {
  local dir="$1" mode
  if [[ -L "$dir" ]]; then
    die "Refusing symlinked SSH ControlMaster directory '$dir'; expected a real directory with mode 0700."
  fi
  if [[ -e "$dir" && ! -d "$dir" ]]; then
    die "SSH ControlMaster directory path '$dir' exists but is not a directory."
  fi
  mkdir -p -- "$dir" || die "Could not create SSH ControlMaster directory '$dir'."
  mode="$(stat -c '%a' "$dir")"
  if [[ "$mode" != "700" ]]; then
    chmod 700 -- "$dir" || die "Could not restrict SSH ControlMaster directory '$dir' to mode 0700."
    mode="$(stat -c '%a' "$dir")"
    [[ "$mode" == "700" ]] || die "SSH ControlMaster directory '$dir' could not be restricted to mode 0700 (got $mode)."
  fi
}

compute_desired_control_path() {
  # Generated sockets live in a private per-user directory so a multi-user
  # TMPDIR cannot be used to pre-plant or hijack another user's socket.
  # KAGGLE_CONNECT_CONTROL_PATH wins verbatim for environments managing their
  # own socket location and imposes no generated-directory policy.
  DESIRED_CONTROL_BASE=""
  if [[ -n "${KAGGLE_CONNECT_CONTROL_PATH:-}" ]]; then
    DESIRED_CONTROL_PATH="$KAGGLE_CONNECT_CONTROL_PATH"
    return 0
  fi
  if [[ -n "${KAGGLE_CONNECT_CONTROL_DIR:-}" ]]; then
    DESIRED_CONTROL_BASE="$KAGGLE_CONNECT_CONTROL_DIR"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    DESIRED_CONTROL_BASE="$XDG_RUNTIME_DIR/kaggle-connect"
  else
    DESIRED_CONTROL_BASE="${TMPDIR:-/tmp}/kaggle-connect-$(id -u)"
  fi
  DESIRED_CONTROL_PATH="$DESIRED_CONTROL_BASE/$PROFILE_HASH.sock"
}

prepare_desired_control_location() {
  compute_desired_control_path
  if [[ -n "$DESIRED_CONTROL_BASE" ]]; then
    ensure_private_control_dir "$DESIRED_CONTROL_BASE"
  fi
}

prepare_profile_state_dir() {
  mkdir -p -- "$STATE_DIR"
  touch "$STATE_FILE"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

validate_port_list() {
  local label="$1" list="$2" port
  for port in $list; do
    validate_port "$port" || die "$label contains invalid TCP port: $port"
  done
}

validate_maps() {
  local pair local_port remote_port
  for pair in $KAGGLE_PORT_MAPS; do
    [[ "$pair" == *:* && "$pair" != *:*:* ]] || die "Invalid KAGGLE_PORT_MAPS entry '$pair'; expected LOCAL:REMOTE."
    local_port="${pair%%:*}"
    remote_port="${pair##*:}"
    validate_port "$local_port" || die "Invalid local port in mapping: $pair"
    validate_port "$remote_port" || die "Invalid remote port in mapping: $pair"
  done
}

normalize_identity_path() {
  local path="$1"
  if [[ "$path" == '~/'* ]]; then
    printf '%s/%s\n' "$HOME" "${path#~/}"
  else
    printf '%s\n' "$path"
  fi
}

SSH_TARGET="$KAGGLE_SSH_TARGET"
SSH_CONTROL_OPTS=(
  -o BatchMode=yes
)
SSH_OPTS=(
  "${SSH_CONTROL_OPTS[@]}"
  -o "ConnectTimeout=$KAGGLE_SSH_CONNECT_TIMEOUT"
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=10
  -o TCPKeepAlive=yes
)

if [[ -n "$KAGGLE_SSH_HOST" ]] || [[ -n "$KAGGLE_SSH_PORT" ]]; then
  case "$ACTION" in
    start|restart|status)
      if [[ -n "$KAGGLE_SSH_HOST" ]]; then
        SSH_TARGET="${KAGGLE_SSH_USER}@${KAGGLE_SSH_HOST}"
        SSH_OPTS+=(
          -o "HostKeyAlias=$KAGGLE_SSH_HOST_KEY_ALIAS"
          -o StrictHostKeyChecking=accept-new
        )
      fi

      if [[ -n "$KAGGLE_SSH_PORT" ]]; then
        # start/restart need a usable DESIRED endpoint, so an invalid port is
        # fatal. status only reports on it and degrades instead of dying.
        if [[ "$ACTION" == "status" ]]; then
          validate_port "$KAGGLE_SSH_PORT" || STATUS_DESIRED_INVALID=1
        else
          validate_port "$KAGGLE_SSH_PORT" || die "Invalid KAGGLE_SSH_PORT: $KAGGLE_SSH_PORT"
        fi
        if (( ! STATUS_DESIRED_INVALID )); then
          SSH_OPTS+=(-p "$KAGGLE_SSH_PORT")
        fi
      fi
      ;;
    # Desired endpoint configuration addresses the DESIRED session only.
    # Teardown manages the STORED session through its persisted control path
    # and must stay independent of the current alias/port/key settings.
    stop)
      ;;
  esac
fi

# Canonical session identity is the RESOLVED SSH destination (user, hostname,
# port). Authentication material such as identity-file paths and the alias
# string itself are deliberately excluded: two sessions reaching the same
# destination share lifecycle state, while an alias retargeted to another
# destination must not. Prints the key; returns non-zero when resolution fails
# so callers can decide whether that is fatal (start/restart) or merely
# degrades reporting (status) — teardown never needs it at all.
make_endpoint_key() {
  local config key value
  local resolved_user=""
  local resolved_hostname=""
  local resolved_port=""

  rm -f "$SSH_ERR_LOG" 2>/dev/null || true
  if ! config="$(ssh "${SSH_OPTS[@]}" -G "$SSH_TARGET" 2>"$SSH_ERR_LOG")"; then
    return 1
  fi

  while IFS=' ' read -r key value _; do
    case "$key" in
      user)
        [[ -n "$resolved_user" ]] || resolved_user="$value"
        ;;
      hostname)
        [[ -n "$resolved_hostname" ]] || resolved_hostname="$value"
        ;;
      port)
        [[ -n "$resolved_port" ]] || resolved_port="$value"
        ;;
    esac
  done <<<"$config"

  if [[ -z "$resolved_user" || -z "$resolved_hostname" ]]; then
    printf 'Missing resolved user or hostname from SSH configuration.\n' >"$SSH_ERR_LOG"
    return 1
  fi
  if ! validate_port "$resolved_port"; then
    printf "Invalid resolved port '%s' from SSH configuration.\n" "$resolved_port" >"$SSH_ERR_LOG"
    return 1
  fi

  printf 'ssh|%s|%s|%s\n' \
    "$resolved_user" \
    "$resolved_hostname" \
    "$resolved_port"
}

# start/restart preflight: everything about the DESIRED session that can be
# validated locally must succeed before any destructive step runs, so a healthy
# stored session is never torn down for an already-invalid new configuration.
prepare_desired_connection() {
  require_command ssh
  validate_port_list KAGGLE_FORWARD_PORTS "$KAGGLE_FORWARD_PORTS"
  validate_port_list KAGGLE_EXTRA_PORTS "$KAGGLE_EXTRA_PORTS"
  validate_maps

  if [[ -n "$KAGGLE_SSH_IDENTITY_FILE" ]]; then
    identity="$(normalize_identity_path "$KAGGLE_SSH_IDENTITY_FILE")"
    [[ -r "$identity" ]] || die "SSH identity file is not readable: $identity"
    SSH_OPTS+=(-i "$identity" -o IdentitiesOnly=yes)
  fi

  if ! DESIRED_ENDPOINT="$(make_endpoint_key)"; then
    local err_details=""
    if [[ -r "$SSH_ERR_LOG" ]]; then
      err_details="$(<"$SSH_ERR_LOG")"
    fi
    local err_msg="Could not resolve SSH destination for endpoint tracking: $SSH_TARGET"
    if [[ -n "$err_details" ]]; then
      err_msg+=$'\n'"  [SSH Error] ${err_details}"
      if [[ "$err_details" == *"Bad owner or permissions"* ]]; then
        err_msg+=$'\n'"  [Fix Suggestion] Run 'chmod 600 ~/.ssh/config' or 'chmod 700 ~/.ssh'"
      fi
    fi
    die "$err_msg"
  fi

  prepare_desired_control_location
}

read_state_value() {
  local file="$1" value=""
  [[ -r "$file" ]] || return 0
  IFS= read -r value <"$file" || true
  printf '%s\n' "$value"
}

# Stored metadata describes OWNERSHIP of the existing managed session. It is
# read from disk and never filled in from desired values.
load_stored_session() {
  STORED_ENDPOINT="$(read_state_value "$SESSION_ENDPOINT_FILE")"
  STORED_CONTROL_PATH="$(read_state_value "$SESSION_CONTROL_FILE")"
}

write_session_metadata() {
  local endpoint="$1" control_path="$2"
  printf '%s\n' "$endpoint" >"$SESSION_ENDPOINT_FILE"
  printf '%s\n' "$control_path" >"$SESSION_CONTROL_FILE"
  printf '%s\n' "$KAGGLE_CONNECT_PROFILE" >"$SESSION_PROFILE_FILE"
  chmod 600 "$SESSION_ENDPOINT_FILE" "$SESSION_CONTROL_FILE" "$SESSION_PROFILE_FILE" 2>/dev/null || true
}

clear_stored_metadata() {
  rm -f -- "$SESSION_ENDPOINT_FILE" "$SESSION_CONTROL_FILE" "$SESSION_PROFILE_FILE" 2>/dev/null || true
  STORED_ENDPOINT=""
  STORED_CONTROL_PATH=""
}

clear_forward_state() {
  [[ -e "$STATE_FILE" ]] || return 0
  : >"$STATE_FILE"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}

master_running_at() {
  local control_path="$1"
  ssh "${SSH_CONTROL_OPTS[@]}" -S "$control_path" -O check "$SSH_TARGET" >/dev/null 2>&1
}

# Stop the master listening at an explicit control path. Returns non-zero while
# the master is still alive; managed state must only be discarded after this
# returns zero (verified termination).
stop_master_at() {
  local control_path="$1"
  if master_running_at "$control_path"; then
    log "Stopping SSH ControlMaster and all managed local forwards ..."

    if ! ssh "${SSH_CONTROL_OPTS[@]}" \
      -S "$control_path" \
      -O exit \
      "$SSH_TARGET" >/dev/null 2>&1; then

      if master_running_at "$control_path"; then
        warn "Could not stop SSH ControlMaster; it is still running. Preserving managed state and control socket."
        return 1
      fi
    elif ! wait_master_stopped_at "$control_path"; then
      warn "SSH ControlMaster did not terminate after exit request. Preserving managed state and control socket."
      return 1
    fi
  else
    log "SSH ControlMaster is already stopped."
  fi

  rm -f -- "$control_path" 2>/dev/null || true
}

wait_master_stopped_at() {
  local control_path="$1" attempt
  for attempt in 1 2 3 4 5; do
    if ! master_running_at "$control_path"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Stale stored state (dead master, leftover socket/metadata/bookkeeping) may be
# cleaned safely — but only after liveness has just been checked as false.
cleanup_dead_stored_session() {
  [[ -n "$STORED_CONTROL_PATH" ]] || return 0
  if master_running_at "$STORED_CONTROL_PATH"; then
    return 1
  fi
  rm -f -- "$STORED_CONTROL_PATH" 2>/dev/null || true
  clear_forward_state
  clear_stored_metadata
}

start_new_desired_session() {
  prepare_profile_state_dir

  # Non-negotiable: a live control socket is never discarded, and session
  # bookkeeping is only reset after the desired path is proven safe. Callers
  # preflight their own state; this backstop keeps that invariant local to
  # the only place an unlink and a bookkeeping reset happen.
  if master_running_at "$DESIRED_CONTROL_PATH"; then
    die "Refusing to replace a live SSH ControlMaster at '$DESIRED_CONTROL_PATH'."
  fi
  rm -f -- "$DESIRED_CONTROL_PATH" 2>/dev/null || true
  # A new master is a new multiplexing session: previous forward bookkeeping
  # is invalid and must never leak into the freshly created one.
  clear_forward_state
  log "Opening SSH ControlMaster to $SSH_TARGET ..."
  ssh "${SSH_OPTS[@]}" \
    -M -S "$DESIRED_CONTROL_PATH" \
    -o ControlPersist=yes \
    -o ExitOnForwardFailure=yes \
    -fN "$SSH_TARGET"
  master_running_at "$DESIRED_CONTROL_PATH" ||
    die "SSH authenticated but the ControlMaster did not remain available."
  write_session_metadata "$DESIRED_ENDPOINT" "$DESIRED_CONTROL_PATH"
  ACTIVE_CONTROL_PATH="$DESIRED_CONTROL_PATH"
}

stop_sibling_masters() {
  local match_endpoint="$1" exclude_control_path="$2"
  local dir sibling_endpoint sibling_control sibling_profile sibling_state

  [[ -d "$STATE_HOME" ]] || return 0
  for dir in "$STATE_HOME"/*; do
    [[ -d "$dir" && "$dir" != "$STATE_DIR" ]] || continue
    [[ -r "$dir/endpoint" && -r "$dir/control-path" ]] || continue

    IFS= read -r sibling_endpoint <"$dir/endpoint" || continue
    [[ "$sibling_endpoint" == "$match_endpoint" ]] || continue

    IFS= read -r sibling_control <"$dir/control-path" || continue
    [[ -n "$sibling_control" && "$sibling_control" != "$exclude_control_path" ]] || continue
    sibling_profile="${dir##*/}"
    if [[ -r "$dir/profile" ]]; then
      IFS= read -r sibling_profile <"$dir/profile" || true
    fi

    if ssh "${SSH_CONTROL_OPTS[@]}" -S "$sibling_control" -O check "$SSH_TARGET" >/dev/null 2>&1; then
      log "Stopping managed sibling SSH ControlMaster for profile ${sibling_profile} on the same endpoint ..."
      if ! ssh "${SSH_CONTROL_OPTS[@]}" -S "$sibling_control" -O exit "$SSH_TARGET" >/dev/null 2>&1; then
        warn "Could not stop managed sibling profile ${sibling_profile}; leaving its state untouched."
        return 1
      fi
      if ! wait_master_stopped_at "$sibling_control"; then
        warn "Managed sibling SSH ControlMaster for profile ${sibling_profile} did not terminate; leaving its state untouched."
        return 1
      fi
      rm -f -- "$sibling_control" 2>/dev/null || true
    fi

    sibling_state="$dir/forwards.tsv"
    if [[ -f "$sibling_state" ]]; then
      : >"$sibling_state"
      chmod 600 "$sibling_state" 2>/dev/null || true
    fi
    rm -f -- "$dir/endpoint" "$dir/control-path" "$dir/profile" 2>/dev/null || true
  done
}

# OpenSSH sends the remote command as a shell command string rather than an
# argv vector. Quote every remote Bash argument before crossing that boundary so
# empty values and whitespace-delimited port lists survive remote-shell parsing.
build_remote_bash_command() {
  local remote_command="bash -s --" arg quoted
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    remote_command+=" $quoted"
  done
  printf '%s\n' "$remote_command"
}

# Prints one remote TCP port per line. Project/config discovery is performed
# entirely on the Kaggle machine, then candidate ports are intersected with
# actual listeners to avoid forwarding unrelated Kaggle/Jupyter infrastructure.
# Runs through the ACTIVE managed master, never through a freshly computed path.
discover_remote_ports() {
  local active_control_path="$1" remote_command
  remote_command="$(build_remote_bash_command \
    "$KAGGLE_REMOTE_PROJECT_DIR" \
    "$KAGGLE_REMOTE_WORKING_DIR" \
    "$KAGGLE_FORWARD_PORTS" \
    "$KAGGLE_EXTRA_PORTS")"

  ssh "${SSH_OPTS[@]}" -S "$active_control_path" "$SSH_TARGET" "$remote_command" <<'REMOTE'
set -euo pipefail
project_hint="${1:-}"
working_root="${2:-/kaggle/working}"
explicit_ports="${3:-}"
extra_ports="${4:-}"

declare -A candidates=()
declare -A listeners=()

add_candidate() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  (( port >= 1 && port <= 65535 )) || return 0
  candidates["$port"]=1
}

is_project_root() {
  local root="${1:-}"
  [[ -n "$root" ]] &&
    [[ -r "$root/install/lib/load-config.sh" ]] &&
    [[ -r "$root/config/defaults.env" ]]
}

resolve_project_root() {
  local default_root loader root
  local -a matches=()

  if [[ -n "$project_hint" ]]; then
    if is_project_root "$project_hint"; then
      printf '%s\n' "$project_hint"
      return 0
    fi
    printf 'Configured KAGGLE_REMOTE_PROJECT_DIR is not a Kaggle Development Kit checkout: %s\n' "$project_hint" >&2
    return 20
  fi

  default_root="$working_root/kaggle-dev-environment"
  if is_project_root "$default_root"; then
    printf '%s\n' "$default_root"
    return 0
  fi

  [[ -d "$working_root" ]] || {
    printf 'Cannot auto-discover the Kaggle project: remote working directory does not exist: %s\n' "$working_root" >&2
    return 20
  }

  while IFS= read -r loader; do
    [[ -n "$loader" ]] || continue
    root="${loader%/install/lib/load-config.sh}"
    is_project_root "$root" && matches+=("$root")
  done < <(find "$working_root" -maxdepth 6 -type f -path '*/install/lib/load-config.sh' -print 2>/dev/null | sort)

  case "${#matches[@]}" in
    1)
      printf '%s\n' "${matches[0]}"
      ;;
    0)
      printf 'Cannot auto-discover Kaggle Development Kit under %s. Set KAGGLE_REMOTE_PROJECT_DIR to the REMOTE checkout path or set KAGGLE_FORWARD_PORTS explicitly.\n' "$working_root" >&2
      return 20
      ;;
    *)
      printf 'Multiple Kaggle Development Kit checkouts found under %s; refusing to guess. Set KAGGLE_REMOTE_PROJECT_DIR to one REMOTE checkout path:\n' "$working_root" >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 22
      ;;
  esac
}

if [[ -n "$explicit_ports" ]]; then
  for port in $explicit_ports; do
    add_candidate "$port"
  done
else
  project="$(resolve_project_root)" || exit $?
  loader="$project/install/lib/load-config.sh"
  # shellcheck disable=SC1090
  source "$loader"
  load_project_config "$project"

  while IFS= read -r name; do
    case "$name" in
      POSTGRES_PORT_*|REDIS_PORT_*|ELASTIC_PORT_*|QDRANT_PORT_*|QDRANT_GRPC_PORT_*)
        value="${!name:-}"
        add_candidate "$value"
        ;;
    esac
  done < <(compgen -v)
fi

for port in $extra_ports; do
  add_candidate "$port"
done

if ! command -v ss >/dev/null 2>&1; then
  printf 'Cannot discover listening ports on Kaggle: command `ss` is unavailable.\n' >&2
  exit 21
fi

while IFS= read -r endpoint; do
  [[ -n "$endpoint" ]] || continue
  port="${endpoint##*:}"
  if [[ "$port" =~ ^[0-9]+$ ]]; then
    listeners["$port"]=1
  fi
done < <(ss -H -lnt 2>/dev/null | awk '{print $4}')

for port in "${!candidates[@]}"; do
  if [[ -n "${listeners[$port]:-}" ]]; then
    printf '%s\n' "$port"
  fi
done | sort -n
REMOTE
}

local_port_for_remote() {
  local remote="$1" pair local_port mapped_remote
  for pair in $KAGGLE_PORT_MAPS; do
    local_port="${pair%%:*}"
    mapped_remote="${pair##*:}"
    if [[ "$mapped_remote" == "$remote" ]]; then
      printf '%s\n' "$local_port"
      return 0
    fi
  done
  printf '%s\n' "$remote"
}

tracked_remote() {
  local remote="$1"
  awk -F '\t' -v remote="$remote" '$2 == remote { found=1 } END { exit(found ? 0 : 1) }' "$STATE_FILE"
}

tracked_local_for_remote() {
  local remote="$1"
  awk -F '\t' -v remote="$remote" '$2 == remote { print $1; exit }' "$STATE_FILE"
}

record_forward() {
  local local_port="$1" remote_port="$2" tmp
  tmp="${STATE_FILE}.tmp.$$"
  awk -F '\t' -v remote="$remote_port" '$2 != remote' "$STATE_FILE" >"$tmp" || true
  printf '%s\t%s\n' "$local_port" "$remote_port" >>"$tmp"
  sort -n -k2,2 -k1,1 "$tmp" >"${tmp}.sorted"
  mv -f "${tmp}.sorted" "$STATE_FILE"
  rm -f -- "$tmp"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}

start_forwards() {
  local active_control_path="$1"
  local discovered="" remote_port local_port existing_local spec
  local failures=0 added=0 unchanged=0
  local -a ports=()

  if ! discovered="$(discover_remote_ports "$active_control_path")"; then
    warn "Remote port discovery failed; the SSH master remains running."
    return 1
  fi

  while IFS= read -r remote_port; do
    [[ -n "$remote_port" ]] && ports+=("$remote_port")
  done <<<"$discovered"

  if (( ${#ports[@]} == 0 )); then
    log "SSH is connected; no configured candidate service is currently listening on Kaggle."
    log "Start a service on Kaggle, then run '$PROGRAM start' again to add its forward."
    return 0
  fi

  for remote_port in "${ports[@]}"; do
    validate_port "$remote_port" || { warn "Ignoring invalid discovered port: $remote_port"; failures=1; continue; }

    if tracked_remote "$remote_port"; then
      existing_local="$(tracked_local_for_remote "$remote_port")"
      log "Keeping 127.0.0.1:${existing_local} -> Kaggle 127.0.0.1:${remote_port}"
      ((unchanged += 1))
      continue
    fi

    local_port="$(local_port_for_remote "$remote_port")"
    spec="127.0.0.1:${local_port}:127.0.0.1:${remote_port}"
    if ssh "${SSH_OPTS[@]}" -S "$active_control_path" -O forward -L "$spec" "$SSH_TARGET" >/dev/null; then
      record_forward "$local_port" "$remote_port"
      log "Added   127.0.0.1:${local_port} -> Kaggle 127.0.0.1:${remote_port}"
      ((added += 1))
    else
      warn "Could not bind local port ${local_port} for Kaggle port ${remote_port}. It may already be in use."
      warn "Override it with KAGGLE_PORT_MAPS, e.g. KAGGLE_PORT_MAPS=\"1${local_port}:${remote_port}\"."
      failures=1
    fi
  done

  log "Forward sync complete: added=$added unchanged=$unchanged tracked=$(awk 'NF {n++} END {print n+0}' "$STATE_FILE")"
  return "$failures"
}

# status is observational: it never creates or rewrites lifecycle state.
# Exit-code contract: 0 = a managed master is running, non-zero = none is.
start_cmd() {
  prepare_desired_connection
  load_stored_session

  if [[ -n "$STORED_CONTROL_PATH" ]] && master_running_at "$STORED_CONTROL_PATH"; then
    if [[ -z "$STORED_ENDPOINT" ]]; then
      die "A live SSH ControlMaster responds at '$STORED_CONTROL_PATH' but this profile's stored endpoint metadata is missing or unreadable.
Refusing to claim an ambiguously owned session. Run 'stop' (tears down the known owned path) or 'restart' before starting."
    fi
    if [[ "$STORED_ENDPOINT" != "$DESIRED_ENDPOINT" ]]; then
      die "Profile '$KAGGLE_CONNECT_PROFILE' already manages a live SSH session at:
  Stored: $STORED_ENDPOINT
Current configuration resolves to:
  Desired: $DESIRED_ENDPOINT

'start' is non-destructive and will not replace the live stored session.
Run 'restart' to deliberately replace it, or 'stop' to tear it down."
    fi
    if [[ "$STORED_CONTROL_PATH" != "$DESIRED_CONTROL_PATH" ]]; then
      log "Reusing live managed master at persisted path '$STORED_CONTROL_PATH'; current policy prefers '$DESIRED_CONTROL_PATH'. Run 'restart' to migrate it."
    fi
    ACTIVE_CONTROL_PATH="$STORED_CONTROL_PATH"
    prepare_profile_state_dir
    start_forwards "$ACTIVE_CONTROL_PATH"
    return 0
  fi

  if [[ -z "$STORED_CONTROL_PATH" ]] && master_running_at "$DESIRED_CONTROL_PATH"; then
    die "An untracked live SSH ControlMaster responds at '$DESIRED_CONTROL_PATH' with no stored ownership metadata; refusing to claim it.
Run 'stop' to tear down the known owned path, or choose another KAGGLE_CONNECT_PROFILE."
  fi

  cleanup_dead_stored_session || true
  start_new_desired_session
  start_forwards "$ACTIVE_CONTROL_PATH"
}

restart_cmd() {
  # Preflight the DESIRED session first: never destroy a healthy stored session
  # for a new configuration that is already known to be invalid locally.
  prepare_desired_connection
  load_stored_session

  local stored_alive=0 desired_path_alive=0
  if [[ -n "$STORED_CONTROL_PATH" ]] && master_running_at "$STORED_CONTROL_PATH"; then
    stored_alive=1
  fi
  if [[ "$DESIRED_CONTROL_PATH" != "$STORED_CONTROL_PATH" ]] && master_running_at "$DESIRED_CONTROL_PATH"; then
    desired_path_alive=1
  fi

  # Destructive-ordering gate: an occupied replacement path aborts restart
  # BEFORE the healthy stored session is stopped. The conflicting master has
  # no trusted ownership metadata for this profile, so it is never auto-stopped.
  if (( stored_alive && desired_path_alive )); then
    die "Desired ControlPath '$DESIRED_CONTROL_PATH' is already occupied by a live untracked SSH ControlMaster; preserving the current stored session.
Stop or remove that conflicting master explicitly, then run 'restart' again."
  fi

  if (( stored_alive )); then
    stop_master_at "$STORED_CONTROL_PATH" ||
      { warn "Stored SSH ControlMaster is still running; restart aborted without changing managed state."; return 1; }
    clear_forward_state
    clear_stored_metadata
  else
    cleanup_dead_stored_session || true
  fi

  # Missing ownership metadata does not make a live desired-path master
  # disposable: restart replaces it explicitly (verified stop) instead of
  # unlinking its socket underneath the still-running process.
  if [[ -z "$STORED_CONTROL_PATH" ]] && master_running_at "$DESIRED_CONTROL_PATH"; then
    log "Stopping legacy/untracked SSH ControlMaster at '$DESIRED_CONTROL_PATH' ..."
    stop_master_at "$DESIRED_CONTROL_PATH" ||
      { warn "Live untracked SSH ControlMaster could not be stopped; restart aborted."; return 1; }
    clear_forward_state
    clear_stored_metadata
  fi

  # Sibling cleanup targets the DESIRED endpoint: profiles managed on the old
  # endpoint are unrelated sessions now and must be preserved.
  stop_sibling_masters "$DESIRED_ENDPOINT" "$DESIRED_CONTROL_PATH"
  start_new_desired_session
  start_forwards "$ACTIVE_CONTROL_PATH"
}

stop_cmd() {
  require_command ssh
  load_stored_session

  local control="$STORED_CONTROL_PATH"
  if [[ -z "$control" ]]; then
    # Compatibility fallback for legacy layouts without persisted metadata:
    # probe the current profile's computed path WITHOUT resolving any endpoint.
    compute_desired_control_path
    control="$DESIRED_CONTROL_PATH"
    if ! master_running_at "$control"; then
      log "No managed SSH ControlMaster for profile '$KAGGLE_CONNECT_PROFILE'; nothing to stop."
      return 0
    fi
    log "Stopping legacy untracked SSH ControlMaster at '$control' ..."
    stop_master_at "$control" || return 1
    clear_forward_state
    return 0
  fi

  if master_running_at "$control"; then
    stop_master_at "$control" || return 1
  else
    log "Stored SSH ControlMaster is already stopped; cleaning stale managed state."
    rm -f -- "$control" 2>/dev/null || true
  fi
  clear_forward_state
  clear_stored_metadata
}

status_cmd() {
  require_command ssh
  load_stored_session

  local stored_alive=0 desired_ok=0 label remote_state discovered discovery_ok=0
  local -A listening=()

  if [[ -n "$STORED_CONTROL_PATH" ]] && master_running_at "$STORED_CONTROL_PATH"; then
    stored_alive=1
  fi

  compute_desired_control_path
  if (( STATUS_DESIRED_INVALID )); then
    # Best-effort reporting: the stored session stays authoritative even when
    # the current desired configuration is malformed.
    warn "Ignoring invalid KAGGLE_SSH_PORT '$KAGGLE_SSH_PORT' for desired-endpoint reporting."
    DESIRED_ENDPOINT=""
  elif DESIRED_ENDPOINT="$(make_endpoint_key)"; then
    desired_ok=1
  else
    DESIRED_ENDPOINT=""
    local err_details=""
    if [[ -r "$SSH_ERR_LOG" ]]; then
      err_details="$(<"$SSH_ERR_LOG")"
    fi
    local warn_msg="Could not resolve the desired SSH destination for reporting: $SSH_TARGET"
    if [[ -n "$err_details" ]]; then
      warn_msg+=" (Details: ${err_details})"
    fi
    warn "$warn_msg"
  fi

  if (( stored_alive )); then
    printf 'SSH ControlMaster: RUNNING\n'
    if [[ -z "$STORED_ENDPOINT" ]]; then
      label="UNKNOWN"
    elif (( desired_ok )) && [[ "$STORED_ENDPOINT" == "$DESIRED_ENDPOINT" ]]; then
      label="MATCHED"
    elif (( desired_ok )); then
      label="RETARGETED"
    else
      label="UNKNOWN"
    fi
    printf 'Lifecycle state: %s\n' "$label"
    [[ -n "$STORED_ENDPOINT" ]] && printf 'Stored endpoint:   %s\n' "$STORED_ENDPOINT"
    (( desired_ok )) && printf 'Desired endpoint:  %s\n' "$DESIRED_ENDPOINT"
    printf 'Target: %s\n' "$SSH_TARGET"
    printf 'Profile: %s\n' "$KAGGLE_CONNECT_PROFILE"

    # Remote listener probing only through the verified active STORED master
    # and only when ownership semantics are unambiguous.
    if [[ "$label" == "MATCHED" ]]; then
      if discovered="$(discover_remote_ports "$STORED_CONTROL_PATH" 2>/dev/null)"; then
        discovery_ok=1
        while IFS= read -r remote_port; do
          [[ -n "$remote_port" ]] && listening["$remote_port"]=1
        done <<<"$discovered"
      fi
    fi
  else
    printf 'SSH ControlMaster: STOPPED\n'
    if [[ -n "$STORED_ENDPOINT" || -n "$STORED_CONTROL_PATH" ]]; then
      printf 'Lifecycle state: STALE\n'
    else
      printf 'Lifecycle state: STOPPED\n'
    fi
    printf 'Target: %s\n' "$SSH_TARGET"
    return 1
  fi

  if [[ ! -s "$STATE_FILE" ]]; then
    printf 'Managed forwards: none\n'
    return 0
  fi

  printf 'Managed forwards:\n'
  while IFS=$'\t' read -r local_port remote_port; do
    [[ -n "$local_port" && -n "$remote_port" ]] || continue
    if [[ -n "${listening[$remote_port]:-}" ]]; then
      remote_state="LISTENING"
    elif (( discovery_ok )); then
      remote_state="NOT-LISTENING"
    else
      remote_state="UNKNOWN"
    fi
    printf '  127.0.0.1:%-5s -> Kaggle 127.0.0.1:%-5s [%s]\n' "$local_port" "$remote_port" "$remote_state"
  done <"$STATE_FILE"
}

case "$ACTION" in
  help|-h|--help)
    usage
    ;;
  start)
    start_cmd
    ;;
  restart)
    restart_cmd
    ;;
  stop)
    stop_cmd
    ;;
  status)
    status_cmd
    ;;
  *)
    usage >&2
    die "Unknown action: $ACTION"
    ;;
esac
