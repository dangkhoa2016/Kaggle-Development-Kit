

#!/usr/bin/env bash

# Kaggle SSH bootstrap. This file is intentionally sourceable so its helpers can
# be tested without starting sshd or opening a real ngrok tunnel.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${KAGGLE_SSH_WORK_DIR:-$PROJECT_ROOT}"
STATE_DIR="${KAGGLE_SSH_STATE_DIR:-$WORK_DIR/.kaggle-ssh}"
BIN_DIR="${KAGGLE_SSH_BIN_DIR:-$STATE_DIR/bin}"
APT_CACHE_DIR="${KAGGLE_SSH_APT_CACHE_DIR:-$STATE_DIR/apt-cache}"
NGROK_BIN="${KAGGLE_SSH_NGROK_BIN:-$BIN_DIR/ngrok}"
HOST_KEY_DIR="${KAGGLE_SSH_HOST_KEY_DIR:-$STATE_DIR/host-keys}"
RUN_DIR="${KAGGLE_SSH_RUN_DIR:-$STATE_DIR/run}"
LOG_DIR="${KAGGLE_SSH_LOG_DIR:-$STATE_DIR/logs}"
AUTHORIZED_KEYS="${KAGGLE_SSH_AUTHORIZED_KEYS:-$STATE_DIR/authorized_keys}"
SSHD_CONFIG="${KAGGLE_SSH_SSHD_CONFIG:-$STATE_DIR/sshd_config}"
SSHD_PID_FILE="${KAGGLE_SSH_SSHD_PID_FILE:-$RUN_DIR/sshd.pid}"
NGROK_PID_FILE="${KAGGLE_SSH_NGROK_PID_FILE:-$RUN_DIR/ngrok.pid}"
SSHD_LOG="${KAGGLE_SSH_SSHD_LOG:-$LOG_DIR/sshd.log}"
NGROK_LOG="${KAGGLE_SSH_NGROK_LOG:-$LOG_DIR/ngrok.log}"
NGROK_CONFIG_FILE="${KAGGLE_SSH_NGROK_CONFIG:-/tmp/kaggle-ssh-ngrok-$(id -u).yml}"
NGROK_API_URL="${KAGGLE_SSH_NGROK_API_URL:-http://127.0.0.1:4040/api/tunnels}"
SSH_PORT="${KAGGLE_SSH_PORT:-2222}"
PROC_ROOT="${KAGGLE_SSH_PROC_ROOT:-/proc}"
PRIVSEP_DIR="${KAGGLE_SSH_PRIVSEP_DIR:-/run/sshd}"
CONNECTION_FILE="${KAGGLE_SSH_CONNECTION_FILE:-$STATE_DIR/connection.txt}"
KEEP_ALIVE_SCRIPT="${KAGGLE_SSH_KEEP_ALIVE_SCRIPT:-$STATE_DIR/keep-alive.sh}"
LOCAL_IDENTITY_FILE="${KAGGLE_SSH_LOCAL_IDENTITY_FILE:-~/.ssh/id_ed25519}"
SETUP_SCRIPT_PATH="${KAGGLE_SSH_SETUP_SCRIPT_PATH:-${BASH_SOURCE[0]}}"
PRIVATE_ENV_FILE="${KAGGLE_SSH_PRIVATE_ENV_FILE:-$STATE_DIR/private.env}"
HOST_KEY_ALIAS="${KAGGLE_SSH_HOST_KEY_ALIAS:-kaggle-notebook}"
INSTALL_ALL_SCRIPT="${KAGGLE_SETUP_INSTALL_ALL_SCRIPT:-$PROJECT_ROOT/install/install-all.sh}"
DOCTOR_SCRIPT="${KAGGLE_SETUP_DOCTOR_SCRIPT:-$PROJECT_ROOT/scripts/doctor.sh}"

log() {
  printf '[kaggle-ssh] %s\n' "$*"
}

die() {
  printf '[kaggle-ssh] ERROR: %s\n' "$*" >&2
  return 1
}

require_root() {
  [[ "$(id -u)" == '0' ]] || die 'Kaggle notebook must run this script as root.'
}

validate_public_key() {
  local public_key="${1:-}"
  local key_file

  [[ -n "$public_key" ]] || return 1
  [[ "$public_key" != *$'\n'* && "$public_key" != *$'\r'* ]] || return 1
  [[ "$public_key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || return 1
  command -v ssh-keygen >/dev/null 2>&1 || return 1

  key_file="$(mktemp)" || return 1
  chmod 600 "$key_file"
  printf '%s\n' "$public_key" >"$key_file"
  if ssh-keygen -l -f "$key_file" >/dev/null 2>&1; then
    rm -f "$key_file"
    return 0
  fi

  rm -f "$key_file"
  return 1
}

ngrok_arch() {
  case "${1:-}" in
    x86_64 | amd64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *) return 1 ;;
  esac
}

ngrok_url_for_arch() {
  local arch
  arch="$(ngrok_arch "${1:-}")" || return 1
  printf 'https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-%s.tgz\n' "$arch"
}

ensure_directories() {
  umask 077
  mkdir -p \
    "$STATE_DIR" \
    "$BIN_DIR" \
    "$APT_CACHE_DIR/partial" \
    "$HOST_KEY_DIR" \
    "$RUN_DIR" \
    "$LOG_DIR"
  chmod 700 "$STATE_DIR" "$BIN_DIR" "$APT_CACHE_DIR" "$HOST_KEY_DIR" "$RUN_DIR" "$LOG_DIR"
}

ensure_openssh() {
  local -a cached_debs=()

  if command -v sshd >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
    return 0
  fi

  mkdir -p "$APT_CACHE_DIR/partial"
  shopt -s nullglob
  cached_debs=("$APT_CACHE_DIR"/*.deb)
  shopt -u nullglob

  if (( ${#cached_debs[@]} > 0 )) && command -v dpkg >/dev/null 2>&1; then
    log 'Restoring OpenSSH from the persistent package cache...'
    dpkg -i -- "${cached_debs[@]}" >/dev/null 2>&1 || true
  fi

  if command -v sshd >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || die 'OpenSSH is unavailable and apt-get was not found.'
  log 'Installing OpenSSH server; downloaded packages will be cached persistently...'
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get \
    -o "Dir::Cache::archives=$APT_CACHE_DIR" \
    -o 'Binary::apt::APT::Keep-Downloaded-Packages=true' \
    install -y -qq --no-install-recommends openssh-server

  command -v sshd >/dev/null 2>&1 || die 'OpenSSH installation completed but sshd is still unavailable.'
  command -v ssh-keygen >/dev/null 2>&1 || die 'OpenSSH installation completed but ssh-keygen is unavailable.'
}

ensure_tmux() {
  command -v tmux >/dev/null 2>&1 || die 'tmux is expected to be preinstalled by Kaggle but was not found.'
}

ensure_ngrok() {
  local archive_dir archive url candidate

  if [[ -x "$NGROK_BIN" ]] && "$NGROK_BIN" version >/dev/null 2>&1; then
    return 0
  fi

  command -v curl >/dev/null 2>&1 || die 'curl is expected to be preinstalled by Kaggle but was not found.'
  command -v tar >/dev/null 2>&1 || die 'tar is expected to be preinstalled by Kaggle but was not found.'

  url="$(ngrok_url_for_arch "$(uname -m)")" || die "Unsupported CPU architecture: $(uname -m)"
  archive_dir="$(mktemp -d)"
  archive="$archive_dir/ngrok.tgz"
  candidate="$archive_dir/ngrok"
  trap 'rm -rf "${archive_dir:-}"' RETURN

  log 'Downloading the persistent ngrok v3 binary...'
  curl -fL --retry 3 --connect-timeout 20 "$url" -o "$archive"
  tar -xzf "$archive" -C "$archive_dir" ngrok
  chmod 755 "$candidate"
  "$candidate" version >/dev/null 2>&1 || die 'The downloaded ngrok binary failed its version check.'

  mkdir -p "$BIN_DIR"
  mv -f "$candidate" "$NGROK_BIN"
  chmod 755 "$NGROK_BIN"
  rm -rf "$archive_dir"
  trap - RETURN
}

write_authorized_keys() {
  local public_key="${1:-}"
  local temporary_file

  if ! validate_public_key "$public_key"; then
    die 'SSH_PUBLIC_KEY is not one valid, option-free OpenSSH public key.'
    return 1
  fi
  temporary_file="${AUTHORIZED_KEYS}.tmp.$$"
  umask 077
  printf '%s\n' "$public_key" >"$temporary_file"
  chmod 600 "$temporary_file"
  mv -f "$temporary_file" "$AUTHORIZED_KEYS"
}

generate_host_keys() {
  local key_path

  mkdir -p "$HOST_KEY_DIR"
  chmod 700 "$HOST_KEY_DIR"

  key_path="$HOST_KEY_DIR/ssh_host_ed25519_key"
  if [[ ! -s "$key_path" || ! -s "$key_path.pub" ]] || ! ssh-keygen -l -f "$key_path.pub" >/dev/null 2>&1; then
    rm -f "$key_path" "$key_path.pub"
    ssh-keygen -q -t ed25519 -N '' -f "$key_path"
  fi

  key_path="$HOST_KEY_DIR/ssh_host_rsa_key"
  if [[ ! -s "$key_path" || ! -s "$key_path.pub" ]] || ! ssh-keygen -l -f "$key_path.pub" >/dev/null 2>&1; then
    rm -f "$key_path" "$key_path.pub"
    ssh-keygen -q -t rsa -b 4096 -N '' -f "$key_path"
  fi

  chmod 600 "$HOST_KEY_DIR/ssh_host_ed25519_key" "$HOST_KEY_DIR/ssh_host_rsa_key"
  chmod 644 "$HOST_KEY_DIR/ssh_host_ed25519_key.pub" "$HOST_KEY_DIR/ssh_host_rsa_key.pub"
}

write_sshd_config() {
  local temporary_file="${SSHD_CONFIG}.tmp.$$"

  umask 077
  cat >"$temporary_file" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
AddressFamily inet
Protocol 2

HostKey $HOST_KEY_DIR/ssh_host_ed25519_key
HostKey $HOST_KEY_DIR/ssh_host_rsa_key
PidFile $RUN_DIR/sshd.internal.pid
AuthorizedKeysFile $AUTHORIZED_KEYS

PermitRootLogin prohibit-password
AllowUsers root
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
StrictModes yes
MaxAuthTries 3

AllowTcpForwarding local
AllowStreamLocalForwarding yes
GatewayPorts no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no

ClientAliveInterval 30
ClientAliveCountMax 6
TCPKeepAlive yes
UseDNS no
PrintMotd no
LogLevel VERBOSE
Subsystem sftp internal-sftp
EOF
  chmod 600 "$temporary_file"
  mv -f "$temporary_file" "$SSHD_CONFIG"
}

managed_pid_is_alive() {
  local pid_file="${1:-}"
  local marker="${2:-}"
  local pid cmdline

  [[ -n "$pid_file" && -n "$marker" && -r "$pid_file" ]] || return 1
  read -r pid <"$pid_file" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ -r "$PROC_ROOT/$pid/cmdline" ]] || return 1
  cmdline="$(tr '\0' ' ' <"$PROC_ROOT/$pid/cmdline")"
  [[ "$cmdline" == *"$marker"* ]]
}

pid_file_process_exists() {
  local pid_file="${1:-}"
  local pid
  [[ -r "$pid_file" ]] || return 1
  read -r pid <"$pid_file" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

stop_managed_process() {
  local pid_file="${1:-}"
  local marker="${2:-}"
  local pid attempt

  if [[ ! -r "$pid_file" ]]; then
    return 0
  fi
  read -r pid <"$pid_file" || {
    rm -f "$pid_file"
    return 0
  }

  if ! managed_pid_is_alive "$pid_file" "$marker"; then
    rm -f "$pid_file"
    return 0
  fi

  kill -TERM "$pid" 2>/dev/null || true
  for attempt in {1..30}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  rm -f "$pid_file"
}

parse_ngrok_tcp_url() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
    tunnels = payload.get("tunnels", [])
    url = next(
        item.get("public_url", "")
        for item in tunnels
        if item.get("proto") == "tcp" and str(item.get("public_url", "")).startswith("tcp://")
    )
except (ValueError, TypeError, StopIteration, AttributeError):
    raise SystemExit(1)

print(url)
' 2>/dev/null
}

configure_ngrok() {
  local auth_token="${1:-}"

  if [[ -z "$auth_token" ]]; then
    die 'NGROK_AUTHTOKEN is empty.'
    return 1
  fi
  rm -f "$NGROK_CONFIG_FILE"
  umask 077
  if ! "$NGROK_BIN" config add-authtoken "$auth_token" --config="$NGROK_CONFIG_FILE" >/dev/null; then
    die 'ngrok rejected NGROK_AUTHTOKEN.'
    return 1
  fi
  if [[ ! -s "$NGROK_CONFIG_FILE" ]]; then
    die 'ngrok did not create its temporary configuration file.'
    return 1
  fi
  chmod 600 "$NGROK_CONFIG_FILE"
}

wait_for_pid() {
  local pid="${1:-}"
  local attempt
  for attempt in {1..20}; do
    kill -0 "$pid" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

close_setup_lock_fd() {
  if [[ "${SETUP_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    eval "exec ${SETUP_LOCK_FD}>&-"
  fi
}

start_sshd() {
  local sshd_bin pid
  sshd_bin="${KAGGLE_SSH_SSHD_BIN:-$(command -v sshd || true)}"
  if [[ -z "$sshd_bin" || ! -x "$sshd_bin" ]]; then
    die 'sshd executable was not found.'
    return 1
  fi

  if ! mkdir -p "$PRIVSEP_DIR" "$RUN_DIR" "$LOG_DIR"; then
    die 'Could not create sshd runtime directories.'
    return 1
  fi
  if ! "$sshd_bin" -t -f "$SSHD_CONFIG"; then
    die 'Generated sshd configuration is invalid.'
    return 1
  fi
  : >"$SSHD_LOG"
  (
    close_setup_lock_fd
    exec nohup "$sshd_bin" -D -e -f "$SSHD_CONFIG"
  ) >>"$SSHD_LOG" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" >"${SSHD_PID_FILE}.tmp"
  mv -f "${SSHD_PID_FILE}.tmp" "$SSHD_PID_FILE"
  if ! wait_for_pid "$pid"; then
    tail -n 30 "$SSHD_LOG" >&2 || true
    rm -f "$SSHD_PID_FILE"
    die 'sshd exited during startup.'
    return 1
  fi
}

start_ngrok() {
  local pid
  if [[ ! -x "$NGROK_BIN" ]]; then
    die 'ngrok executable was not found.'
    return 1
  fi

  if ! mkdir -p "$RUN_DIR" "$LOG_DIR"; then
    die 'Could not create ngrok runtime directories.'
    return 1
  fi
  : >"$NGROK_LOG"
  (
    close_setup_lock_fd
    exec nohup "$NGROK_BIN" \
      tcp "127.0.0.1:$SSH_PORT" \
      "--config=$NGROK_CONFIG_FILE" \
      --log=stdout \
      --log-format=json
  ) >>"$NGROK_LOG" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" >"${NGROK_PID_FILE}.tmp"
  mv -f "${NGROK_PID_FILE}.tmp" "$NGROK_PID_FILE"
  if ! wait_for_pid "$pid"; then
    tail -n 30 "$NGROK_LOG" >&2 || true
    rm -f "$NGROK_PID_FILE"
    die 'ngrok exited during startup.'
    return 1
  fi
}

discover_tcp_endpoint() {
  local attempt response endpoint
  local attempts="${KAGGLE_SSH_DISCOVERY_ATTEMPTS:-40}"
  local delay="${KAGGLE_SSH_DISCOVERY_DELAY:-0.5}"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if ! pid_file_process_exists "$NGROK_PID_FILE"; then
      return 1
    fi
    if managed_pid_is_alive "$NGROK_PID_FILE" "$NGROK_BIN"; then
      response="$(curl -fsS --max-time 2 "$NGROK_API_URL" 2>/dev/null || true)"
      if [[ -n "$response" ]]; then
        endpoint="$(printf '%s' "$response" | parse_ngrok_tcp_url || true)"
        if [[ "$endpoint" == tcp://*:* ]]; then
          printf '%s\n' "$endpoint"
          return 0
        fi
      fi
    fi
    sleep "$delay"
  done
  return 1
}

read_private_env_secret() {
  local secret_name="${1:-}"
  [[ -n "$secret_name" && -r "$PRIVATE_ENV_FILE" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$PRIVATE_ENV_FILE" "$secret_name" <<'PY_PRIVATE' 2>/dev/null
import base64
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
name = sys.argv[2] + "_B64"
try:
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() == name:
            sys.stdout.write(base64.b64decode(value.strip()).decode("utf-8"))
            raise SystemExit(0)
except Exception:
    pass
raise SystemExit(1)
PY_PRIVATE
}

write_private_env() {
  local public_key="${1:-}" auth_token="${2:-}" temporary_file
  [[ -n "$public_key" && -n "$auth_token" ]] || die 'Both SSH public key and ngrok token are required to save the private bundle.'
  command -v python3 >/dev/null 2>&1 || die 'python3 is required to save the private secret bundle.'
  temporary_file="${PRIVATE_ENV_FILE}.tmp.$$"
  umask 077
  python3 - "$public_key" "$auth_token" >"$temporary_file" <<'PY_SAVE'
import base64
import sys

print("# PRIVATE: generated by setup.sh --save-secrets")
print("# Keep this file out of public Git repositories and public ZIP releases.")
print("SSH_PUBLIC_KEY_B64=" + base64.b64encode(sys.argv[1].encode()).decode())
print("NGROK_AUTHTOKEN_B64=" + base64.b64encode(sys.argv[2].encode()).decode())
PY_SAVE
  chmod 600 "$temporary_file"
  mv -f "$temporary_file" "$PRIVATE_ENV_FILE"
  log "Saved portable private secrets to $PRIVATE_ENV_FILE (mode 600)."
}

resolve_secret() {
  local secret_name="${1:-}" value=""
  [[ -n "$secret_name" ]] || return 1
  value="${!secret_name:-}"
  [[ -n "$value" ]] || value="$(read_private_env_secret "$secret_name" || true)"
  if [[ -z "$value" && "$secret_name" == "SSH_PUBLIC_KEY" && -r "$AUTHORIZED_KEYS" ]]; then
    value="$(head -n 1 "$AUTHORIZED_KEYS" 2>/dev/null || true)"
  fi
  [[ -n "$value" ]] || value="$(read_kaggle_secret "$secret_name" || true)"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

read_kaggle_secret() {
  local secret_name="${1:-}"
  [[ -n "$secret_name" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$secret_name" <<'PY' 2>/dev/null
import sys

try:
    from kaggle_secrets import UserSecretsClient
    value = UserSecretsClient().get_secret(sys.argv[1])
except Exception:
    raise SystemExit(1)

if not value:
    raise SystemExit(1)
sys.stdout.write(value)
PY
}

endpoint_host_port() {
  local endpoint="${1:-}"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$endpoint" <<'PY' 2>/dev/null
import sys
from urllib.parse import urlsplit

try:
    parsed = urlsplit(sys.argv[1])
    if parsed.scheme != "tcp" or not parsed.hostname or parsed.port is None:
        raise ValueError
except (ValueError, TypeError):
    raise SystemExit(1)

print(parsed.hostname)
print(parsed.port)
PY
}

host_key_fingerprint() {
  local public_key_file="$HOST_KEY_DIR/ssh_host_ed25519_key.pub"
  [[ -r "$public_key_file" ]] || return 1
  ssh-keygen -lf "$public_key_file" -E sha256 2>/dev/null | awk '{print $2}'
}

write_connection_info() {
  local endpoint="${1:-}"
  local -a parts=()
  local host port temporary_file ssh_identity_quoted

  mapfile -t parts < <(endpoint_host_port "$endpoint") || true
  if (( ${#parts[@]} != 2 )); then
    die "Invalid ngrok TCP endpoint: $endpoint"
    return 1
  fi
  host="${parts[0]}"
  port="${parts[1]}"
  if [[ ! "$port" =~ ^[1-9][0-9]*$ ]]; then
    die "Invalid ngrok TCP port: $port"
    return 1
  fi
  printf -v ssh_identity_quoted '%q' "$LOCAL_IDENTITY_FILE"

  temporary_file="${CONNECTION_FILE}.tmp.$$"
  umask 077
  local fingerprint
  fingerprint="$(host_key_fingerprint || true)"
  cat >"$temporary_file" <<EOF
Kaggle SSH connection
Ngrok URL: $endpoint
Host: $host
Port: $port
User: root
Host key alias: $HOST_KEY_ALIAS
ED25519 fingerprint: ${fingerprint:-unavailable}

SSH command:
ssh -i $ssh_identity_quoted -p $port -o HostKeyAlias=$HOST_KEY_ALIAS -o ServerAliveInterval=30 -o ServerAliveCountMax=10 root@$host

VS Code Remote-SSH (~/.ssh/config):
Host kaggle
    HostName $host
    User root
    Port $port
    IdentityFile $LOCAL_IDENTITY_FILE
    IdentitiesOnly yes
    HostKeyAlias $HOST_KEY_ALIAS
    ServerAliveInterval 30
    ServerAliveCountMax 10
    TCPKeepAlive yes
    StrictHostKeyChecking accept-new
EOF
  chmod 600 "$temporary_file"
  mv -f "$temporary_file" "$CONNECTION_FILE"
}

write_keep_alive() {
  local temporary_file="${KEEP_ALIVE_SCRIPT}.tmp.$$"

  umask 077
  {
    printf '#!/usr/bin/env bash\n\n'
    printf 'set -u\n\n'
    printf 'SSHD_PID_FILE=%q\n' "$SSHD_PID_FILE"
    printf 'NGROK_PID_FILE=%q\n' "$NGROK_PID_FILE"
    printf 'SSHD_MARKER=%q\n' "$SSHD_CONFIG"
    printf 'NGROK_MARKER=%q\n' "$NGROK_BIN"
    printf 'SSHD_LOG=%q\n' "$SSHD_LOG"
    printf 'NGROK_LOG=%q\n' "$NGROK_LOG"
    printf 'CONNECTION_FILE=%q\n' "$CONNECTION_FILE"
    cat <<'EOF'
PROC_ROOT="${KAGGLE_SSH_PROC_ROOT:-/proc}"
INTERVAL="${KAGGLE_SSH_KEEP_ALIVE_INTERVAL:-45}"

process_matches() {
  local pid_file="$1" marker="$2" pid cmdline
  [[ -r "$pid_file" ]] || return 1
  read -r pid <"$pid_file" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ -r "$PROC_ROOT/$pid/cmdline" ]] || return 1
  cmdline="$(tr '\0' ' ' <"$PROC_ROOT/$pid/cmdline")"
  [[ "$cmdline" == *"$marker"* ]]
}

show_log_tail() {
  local label="$1" file="$2"
  if [[ -s "$file" ]]; then
    printf '\n--- Last %s log lines ---\n' "$label" >&2
    tail -n 20 "$file" >&2 || true
  fi
}

trap 'printf "\nKeep-alive stopped. SSH/ngrok continue running in the background.\n"; exit 0' INT TERM

while true; do
  if ! process_matches "$SSHD_PID_FILE" "$SSHD_MARKER"; then
    printf '[%s] ERROR: sshd is not running. Run setup.sh again.\n' "$(date '+%Y-%m-%d %H:%M:%S')" >&2
    show_log_tail sshd "$SSHD_LOG"
    exit 1
  fi
  if ! process_matches "$NGROK_PID_FILE" "$NGROK_MARKER"; then
    printf '[%s] ERROR: ngrok is not running. Run setup.sh again.\n' "$(date '+%Y-%m-%d %H:%M:%S')" >&2
    show_log_tail ngrok "$NGROK_LOG"
    exit 1
  fi

  endpoint="$(sed -n 's/^Ngrok URL: //p' "$CONNECTION_FILE" 2>/dev/null | head -n 1)"
  printf '[%s] OK: sshd and ngrok are running%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "${endpoint:+ — $endpoint}"

  [[ "${KAGGLE_SSH_KEEP_ALIVE_ONCE:-0}" == '1' ]] && exit 0
  sleep "$INTERVAL"
done
EOF
  } >"$temporary_file"
  chmod 700 "$temporary_file"
  mv -f "$temporary_file" "$KEEP_ALIVE_SCRIPT"
}

prepare_development_environment() {
  local mode="${1:-auto}"
  [[ -f "$INSTALL_ALL_SCRIPT" ]] || { log "Development installer not found; skipping toolchain setup."; return 0; }

  case "$mode" in
    off)
      log 'Skipping development toolchain setup.'
      ;;
    install)
      log 'Installing development toolchain and local databases...'
      bash "$INSTALL_ALL_SCRIPT" install
      ;;
    bootstrap)
      log 'Bootstrapping the restored development toolchain...'
      bash "$INSTALL_ALL_SCRIPT" bootstrap
      ;;
    auto)
      if [[ -d "$PROJECT_ROOT/.system" ]]; then
        log 'Detected .system; bootstrapping restored runtime state...'
        bash "$INSTALL_ALL_SCRIPT" bootstrap
        if [[ "${KAGGLE_SETUP_AUTO_REPAIR:-1}" == "1" ]] && [[ -f "$DOCTOR_SCRIPT" ]] && ! bash "$DOCTOR_SCRIPT" >/dev/null; then
          log 'Doctor detected a broken restored runtime; refreshing PostgreSQL/Redis runtime packages while preserving data...'
          POSTGRES_FORCE_RUNTIME_REFRESH=1 REDIS_FORCE_RUNTIME_REFRESH=1 bash "$INSTALL_ALL_SCRIPT" install
        fi
      else
        log 'No .system found; performing the first full development install...'
        bash "$INSTALL_ALL_SCRIPT" install
      fi
      ;;
    *) die "Unknown toolchain mode: $mode" ;;
  esac
}

run_doctor() {
  [[ -f "$DOCTOR_SCRIPT" ]] || die "Doctor script not found: $DOCTOR_SCRIPT"
  bash "$DOCTOR_SCRIPT"
}

cleanup_ngrok_config() {
  if [[ -n "${NGROK_CONFIG_FILE:-}" && -f "$NGROK_CONFIG_FILE" ]]; then
    rm -f -- "$NGROK_CONFIG_FILE"
  fi
}

print_summary() {
  printf '\n============================================================\n'
  printf 'Kaggle SSH is ready\n'
  printf '============================================================\n\n'
  cat "$CONNECTION_FILE"
  printf '\nPersistent tmux shell after connecting:\n'
  printf 'tmux new-session -A -s work\n'
  printf '\nLive logs:\n'
  printf 'tail -f %s\n' "$SSHD_LOG"
  printf 'tail -f %s\n' "$NGROK_LOG"
  printf '\nSaved connection details:\n%s\n' "$CONNECTION_FILE"
  printf '\nService controls:\n'
  printf 'bash %s --status\n' "$SETUP_SCRIPT_PATH"
  printf 'bash %s --doctor\n' "$SETUP_SCRIPT_PATH"
  printf 'bash %s --stop\n' "$SETUP_SCRIPT_PATH"
  printf 'bash %s                  # restart SSH/ngrok and get a new endpoint\n' "$SETUP_SCRIPT_PATH"
  printf 'bash %s --full           # install/bootstrap dev tools + start SSH/ngrok\n' "$SETUP_SCRIPT_PATH"
  printf '\nRun keep-alive in ANOTHER Kaggle cell:\n'
  printf '!bash %s\n' "$KEEP_ALIVE_SCRIPT"
}

acquire_setup_lock() {
  command -v flock >/dev/null 2>&1 || die 'flock is required but was not found in the Kaggle image.'
  exec {SETUP_LOCK_FD}>"$RUN_DIR/setup.lock"
  flock -n "$SETUP_LOCK_FD" || die 'Another setup.sh process is already running.'
}

stop_services() {
  stop_managed_process "$NGROK_PID_FILE" "$NGROK_BIN"
  stop_managed_process "$SSHD_PID_FILE" "$SSHD_CONFIG"
}

status_services() {
  local status=0
  if managed_pid_is_alive "$SSHD_PID_FILE" "$SSHD_CONFIG"; then
    log "sshd is running (PID $(cat "$SSHD_PID_FILE"))."
  else
    log 'sshd is not running.'
    status=1
  fi
  if managed_pid_is_alive "$NGROK_PID_FILE" "$NGROK_BIN"; then
    log "ngrok is running (PID $(cat "$NGROK_PID_FILE"))."
  else
    log 'ngrok is not running.'
    status=1
  fi
  [[ -r "$CONNECTION_FILE" ]] && cat "$CONNECTION_FILE"
  return "$status"
}

safe_log_tail() {
  local file label
  for label in sshd ngrok; do
    if [[ "$label" == 'sshd' ]]; then file="$SSHD_LOG"; else file="$NGROK_LOG"; fi
    if [[ -s "$file" ]]; then
      printf '\n--- %s log tail ---\n' "$label" >&2
      tail -n 30 "$file" >&2 || true
    fi
  done
}

on_error() {
  local line="${1:-unknown}" status="${2:-1}"
  cleanup_ngrok_config || true
  printf '[kaggle-ssh] Setup failed near line %s (exit %s).\n' "$line" "$status" >&2
  safe_log_tail
}

main() {
  local action="${1:-start}"
  local ssh_public_key ngrok_token endpoint toolchain_mode="off"

  umask 077
  require_root
  ensure_directories
  acquire_setup_lock

  case "$action" in
    --stop)
      cleanup_ngrok_config
      stop_services
      log 'Managed sshd and ngrok processes stopped.'
      return 0
      ;;
    --status)
      status_services
      return
      ;;
    --doctor)
      run_doctor
      return
      ;;
    --save-secrets)
      ssh_public_key="$(resolve_secret SSH_PUBLIC_KEY || true)"
      ngrok_token="$(resolve_secret NGROK_AUTHTOKEN || true)"
      [[ -n "$ssh_public_key" && -n "$ngrok_token" ]] || die 'Could not resolve both SSH_PUBLIC_KEY and NGROK_AUTHTOKEN from environment, private.env, or Kaggle Secrets.'
      validate_public_key "$ssh_public_key" || die 'SSH_PUBLIC_KEY is malformed.'
      write_private_env "$ssh_public_key" "$ngrok_token"
      ngrok_token=''
      unset SSH_PUBLIC_KEY NGROK_AUTHTOKEN || true
      return 0
      ;;
    --full)
      toolchain_mode="auto"
      ;;
    --install-tools)
      toolchain_mode="install"
      ;;
    --bootstrap-tools)
      toolchain_mode="bootstrap"
      ;;
    start | '') ;;
    *) die "Unknown argument: $action (supported: --full, --install-tools, --bootstrap-tools, --doctor, --save-secrets, --status, --stop)" ;;
  esac

  ssh_public_key="$(resolve_secret SSH_PUBLIC_KEY || true)"
  ngrok_token="$(resolve_secret NGROK_AUTHTOKEN || true)"
  if [[ -z "$ssh_public_key" || -z "$ngrok_token" ]]; then
    die "Required credentials are missing. Provide SSH_PUBLIC_KEY and NGROK_AUTHTOKEN via environment variables, Kaggle Secrets, or $PRIVATE_ENV_FILE."
  fi

  ensure_openssh
  validate_public_key "$ssh_public_key" || die 'SSH_PUBLIC_KEY is malformed. Paste exactly one OpenSSH public key without authorized_keys options.'
  ensure_tmux
  ensure_ngrok
  write_authorized_keys "$ssh_public_key"
  generate_host_keys
  write_sshd_config

  if [[ "$toolchain_mode" != "off" ]]; then
    prepare_development_environment "$toolchain_mode"
  fi

  stop_services
  configure_ngrok "$ngrok_token"
  ngrok_token=''
  unset SSH_PUBLIC_KEY NGROK_AUTHTOKEN || true

  if ! start_sshd; then
    cleanup_ngrok_config
    safe_log_tail
    die 'Could not start sshd.'
  fi
  if ! start_ngrok; then
    cleanup_ngrok_config
    stop_managed_process "$SSHD_PID_FILE" "$SSHD_CONFIG"
    safe_log_tail
    die 'Could not start ngrok.'
  fi

  endpoint="$(discover_tcp_endpoint || true)"
  if [[ -z "$endpoint" ]]; then
    cleanup_ngrok_config
    stop_services
    safe_log_tail
    die 'ngrok did not publish a TCP endpoint. Check the token, account TCP eligibility, and ngrok log.'
  fi

  # ngrok has already loaded its credentials by this point; remove the temporary
  # config so the auth token is not left on disk for the lifetime of the session.
  cleanup_ngrok_config

  write_connection_info "$endpoint"
  write_keep_alive
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
  trap 'on_error "$LINENO" "$?"' ERR
  main "$@"
fi

