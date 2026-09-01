#!/usr/bin/env bash
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEM_DIR="${KAGGLE_SYSTEM_DIR:-$PROJECT_ROOT/.system}"
SSH_STATE_DIR="${KAGGLE_SSH_STATE_DIR:-$PROJECT_ROOT/.kaggle-ssh}"
FAILURES=0; WARNINGS=0
source "$PROJECT_ROOT/install/lib/common.sh"
source "$PROJECT_ROOT/install/lib/load-config.sh"
load_project_config "$PROJECT_ROOT"

ok(){ printf '  ✅ %-24s %s\n' "$1" "$2"; }
warn(){ printf '  ⚠️  %-24s %s\n' "$1" "$2"; WARNINGS=$((WARNINGS+1)); }
fail(){ printf '  ❌ %-24s %s\n' "$1" "$2"; FAILURES=$((FAILURES+1)); }
info(){ printf '  ℹ️  %-24s %s\n' "$1" "$2"; }
version_line(){ "$@" 2>/dev/null | head -1 || true; }
check_command(){ command -v "$1" >/dev/null 2>&1 && ok "$1" "$(command -v "$1")" || warn "$1" 'not found'; }

mise_tool_version() {
  local tool="$1" output first
  output="$(
    cd "$PROJECT_ROOT" || exit 1
    MISE_AUTO_INSTALL=0 MISE_EXEC_AUTO_INSTALL=0 \
      mise exec -- "$tool" --version 2>/dev/null
  )" || return 1
  first="${output%%$'\n'*}"
  case "$tool" in
    node) first="${first#v}" ;;
    ruby)
      set -- $first
      [ "${1:-}" = ruby ] && [ -n "${2:-}" ] || return 1
      first="$2"
      ;;
  esac
  printf '%s\n' "$first"
}

check_mise_tool() {
  local tool="$1" expected="$2" actual path
  path="$(
    cd "$PROJECT_ROOT" || exit 1
    MISE_AUTO_INSTALL=0 MISE_EXEC_AUTO_INSTALL=0 \
      mise which "$tool" 2>/dev/null
  )" || {
    fail "mise $tool" "expected $expected; managed executable is unavailable"
    return
  }
  case "$path" in
    "$SYSTEM_DIR"/mise/data/installs/*) ;;
    *)
      fail "mise $tool" "expected managed $expected; resolved outside project state: $path"
      return
      ;;
  esac
  [ -x "$path" ] || {
    fail "mise $tool" "expected $expected; managed path is not executable: $path"
    return
  }
  actual="$(mise_tool_version "$tool")" || {
    fail "mise $tool" "expected $expected; execution failed"
    return
  }
  if [ "$actual" = "$expected" ]; then
    ok "mise $tool" "$actual ($path)"
  else
    fail "mise $tool" "version mismatch: expected=$expected actual=$actual ($path)"
  fi
}

printf 'Kaggle Development Environment Doctor\nProject: %s\n\n' "$PROJECT_ROOT"

printf 'Repository / public-safety\n'
[ -f "$PROJECT_ROOT/.gitignore" ] && ok '.gitignore' 'present' || fail '.gitignore' 'missing'
for sensitive in "$PROJECT_ROOT/.kaggle-ssh/private.env" "$PROJECT_ROOT/.kaggle-ssh/authorized_keys"; do
  [ ! -e "$sensitive" ] || warn 'private runtime state' "$(realpath --relative-to="$PROJECT_ROOT" "$sensitive") exists; never commit it"
done
if find "$PROJECT_ROOT" -path "$PROJECT_ROOT/.git" -prune -o -type f -name 'ssh_host_*_key' -print -quit 2>/dev/null | grep -q .; then
  warn 'SSH private host key' 'found under project tree; .kaggle-ssh must stay ignored'
else
  ok 'SSH private host key' 'none in source tree'
fi
[ -f "$PROJECT_ROOT/.kaggle-dev.env" ] && info '.kaggle-dev.env' 'local config present + expected to be gitignored' || info '.kaggle-dev.env' 'not created yet; repository defaults apply'

printf '\nPlatform\n'
arch="$(uname -m 2>/dev/null || echo unknown)"
case "$arch" in x86_64|amd64) ok Architecture "$arch" ;; *) warn Architecture "$arch (bundled SQLite binaries target Linux x86-64)" ;; esac
for cmd in bash python3 git curl tar flock tmux ssh-keygen; do check_command "$cmd"; done

printf '\nConfigured versions\n'
info PostgreSQL "${POSTGRES_VERSIONS:-18}; default=${POSTGRES_DEFAULT_VERSION:-18}; auto-start=${POSTGRES_AUTO_START_VERSIONS:-}"
info Redis "${REDIS_VERSIONS:-8.10.0}; default=${REDIS_DEFAULT_VERSION:-8.10.0}; auto-start=${REDIS_AUTO_START_VERSIONS:-}"
info Elastic "${ELASTIC_VERSIONS:-9.5.0}; default=${ELASTIC_DEFAULT_VERSION:-9.5.0}; auto-start=${ELASTIC_AUTO_START_VERSIONS:-none}"
info 'Elastic components' "${ELASTIC_COMPONENTS:-elasticsearch kibana logstash}"
info Qdrant "${QDRANT_VERSIONS:-1.18.3}; default=${QDRANT_DEFAULT_VERSION:-1.18.3}; auto-start=${QDRANT_AUTO_START_VERSIONS:-none}"
info QNP "release=${QNP_RELEASE:-1.0.0}; commit=${QNP_SOURCE_COMMIT:-21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca}"

printf '\nSSH / tunnel\n'
[ -f "$PROJECT_ROOT/setup.sh" ] && ok setup.sh 'present' || fail setup.sh 'missing'
if command -v sshd >/dev/null 2>&1; then ok 'OpenSSH server' "$(command -v sshd)"; else info 'OpenSSH server' 'setup.sh installs on first use'; fi
[ -x "$SSH_STATE_DIR/bin/ngrok" ] && ok ngrok "$(version_line "$SSH_STATE_DIR/bin/ngrok" version)" || info ngrok 'not cached yet'

printf '\nDevelopment runtimes\n'
if [ ! -d "$SYSTEM_DIR" ]; then info .system 'not installed yet'; else ok .system 'present'; fi
sqlite="$SYSTEM_DIR/sqlite3/sqlite3"
[ -x "$sqlite" ] && ok SQLite "$(version_line "$sqlite" --version)" || info SQLite 'not installed'

pg_found=0
shopt -s nullglob
for psql in "$SYSTEM_DIR"/pg/runtime/usr/lib/postgresql/*/bin/psql; do
  pg_found=1; ver="$(basename "$(dirname "$(dirname "$psql")")")"
  ok "PostgreSQL $ver" "$(version_line "$psql" --version)"
  [ -f "$SYSTEM_DIR/pg/runtime/usr/share/postgresql/$ver/extension/vector.control" ] && ok "pgvector $ver" 'extension files present' || warn "pgvector $ver" 'not installed'
done
[ "$pg_found" -eq 1 ] || info PostgreSQL 'not installed'

redis_found=0
for server in "$SYSTEM_DIR"/redis/versions/*/bin/redis-server; do
  redis_found=1; ver="$(basename "$(dirname "$(dirname "$server")")")"
  ok "Redis $ver" "$(version_line "$server" --version)"
done
# legacy runtime compatibility
if [ "$redis_found" -eq 0 ] && [ -x "$SYSTEM_DIR/redis/runtime/usr/bin/redis-server" ]; then
  redis_found=1; ok Redis "legacy layout: $(version_line "$SYSTEM_DIR/redis/runtime/usr/bin/redis-server" --version)"
fi
[ "$redis_found" -eq 1 ] || info Redis 'not installed'

elastic_found=0
for root in "$SYSTEM_DIR"/elastic/versions/*; do
  [ -d "$root" ] || continue; elastic_found=1; ver="$(basename "$root")"; components="$(cat "$root/components" 2>/dev/null || true)"
  ok "Elastic $ver" "components=${components:-unknown}"
  for component in $components; do
    [ -x "$root/runtime/$component/bin/$component" ] && ok "  $component" 'runtime present' || fail "  $component" 'runtime missing'
  done
done
if [ "$elastic_found" -eq 0 ] && [ -f "$SYSTEM_DIR/elastic/version" ]; then info Elastic "legacy single-version layout: $(cat "$SYSTEM_DIR/elastic/version")"; elastic_found=1; fi
[ "$elastic_found" -eq 1 ] || info Elastic 'not installed'

qdrant_found=0
qnp_source_name="$(cat "$SYSTEM_DIR/qdrant/qnp-source-name" 2>/dev/null || true)"
qnp_source="$SYSTEM_DIR/qdrant/qnp/$qnp_source_name"
if [ -n "$qnp_source_name" ] && [ -f "$qnp_source/VERSION" ]; then
  qnp_release_actual="$(tr -d '[:space:]' < "$qnp_source/VERSION")"
  qnp_commit_meta="$(sed -n 's/^commit=//p' "$qnp_source/.qnp-source-meta" 2>/dev/null | head -1)"
  qnp_head_actual=""
  qnp_git_root="$(git -C "$qnp_source" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$qnp_git_root" ]; then
    qnp_source_real="$(realpath -m "$qnp_source")"
    qnp_git_root_real="$(realpath -m "$qnp_git_root")"
    if [ "$qnp_git_root_real" = "$qnp_source_real" ]; then
      qnp_head_actual="$(git -C "$qnp_source" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
    fi
  fi
  if [ "$qnp_release_actual" != "${QNP_RELEASE:-1.0.0}" ]; then
    fail QNP "release mismatch: expected=${QNP_RELEASE:-1.0.0} actual=$qnp_release_actual"
  elif [ -z "$qnp_commit_meta" ]; then
    fail QNP 'source cache lacks .qnp-source-meta commit; pin unverifiable'
  elif [ "$qnp_commit_meta" != "${QNP_SOURCE_COMMIT:-21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca}" ]; then
    fail QNP "pin mismatch: expected=${QNP_SOURCE_COMMIT:-21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca} metadata=$qnp_commit_meta"
  elif [ -z "$qnp_head_actual" ]; then
    warn QNP "release=$qnp_release_actual; metadata commit=$qnp_commit_meta matches expected pin, but checkout HEAD is unavailable; source tree identity cannot be independently verified"
  elif [ "$qnp_head_actual" != "${QNP_SOURCE_COMMIT:-21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca}" ]; then
    fail QNP "pin mismatch: expected=${QNP_SOURCE_COMMIT:-21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca} checkout HEAD=$qnp_head_actual"
  else
    ok QNP "release=$qnp_release_actual; commit=$qnp_commit_meta"
  fi
else
  info QNP 'source cache not installed'
fi
for root in "$SYSTEM_DIR"/qdrant/instances/*; do
  [ -d "$root" ] || continue
  qdrant_found=1; ver="$(basename "$root")"; bin="$root/qdrant-$ver/qdrant"
  rest="$(cat "$root/kdev-rest-port" 2>/dev/null || true)"
  config="$root/config/qdrant.yaml"
  if [ -x "$bin" ]; then ok "Qdrant $ver" "$(version_line "$bin" --version)"; else fail "Qdrant $ver" 'binary missing'; fi
  if [ -n "$rest" ] && grep -Eq '^[[:space:]]*host:[[:space:]]*127\.0\.0\.1[[:space:]]*$' "$config" 2>/dev/null; then
    ok "Qdrant $ver endpoint" "127.0.0.1:$rest (loopback)"
  else
    fail "Qdrant $ver endpoint" 'missing port metadata or non-loopback config'
  fi
  if [ -f "$root/run/qdrant.pid" ]; then
    pid="$(cat "$root/run/qdrant.pid" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      if curl -fsS --max-time 2 "http://127.0.0.1:$rest/readyz" >/dev/null 2>&1; then
        ok "Qdrant $ver health" "ready on 127.0.0.1:$rest"
      else
        warn "Qdrant $ver health" 'process running but /readyz is not ready'
      fi
    else
      info "Qdrant $ver status" 'stopped (stale pid metadata)'
    fi
  else
    info "Qdrant $ver status" 'stopped'
  fi
done
[ "$qdrant_found" -eq 1 ] || info Qdrant 'not installed'
[ ! -d "$SYSTEM_DIR/qdrant" ] || { [ -x "$SYSTEM_DIR/qdrant-service.sh" ] && ok 'Qdrant service helper' 'present + executable' || fail 'Qdrant service helper' 'missing'; }
shopt -u nullglob

if [ -f "$SYSTEM_DIR/mise/env.sh" ]; then
  # Source the project-scoped mise environment in this doctor process. Disable
  # auto-install for all health probes: diagnostics must never heal/mutate a
  # missing tool while deciding whether the persisted runtime is healthy.
  # shellcheck disable=SC1090
  if source "$SYSTEM_DIR/mise/env.sh" >/dev/null 2>&1 && command -v mise >/dev/null 2>&1; then
    out="$(mise --version 2>/dev/null | head -1 || true)"
    if [ -n "$out" ]; then
      ok mise "$out"
      check_mise_tool node "${TOOL_NODE_VERSION:-${MISE_NODE_VERSION:-26.6.0}}"
      check_mise_tool ruby "${TOOL_RUBY_VERSION:-${MISE_RUBY_VERSION:-3.4.9}}"
      check_mise_tool npm "${TOOL_NPM_VERSION:-${MISE_NPM_VERSION:-12.0.2}}"
      check_mise_tool yarn "${TOOL_YARN_VERSION:-${MISE_YARN_VERSION:-1.22.22}}"
    else
      fail mise 'env exists but mise did not start'
    fi
  else
    fail mise 'env exists but could not be activated'
  fi
else info mise/toolchain 'not installed'; fi

printf '\nControl CLI\n'
[ -x "$PROJECT_ROOT/bin/kdev" ] && ok bin/kdev 'present + executable' || fail bin/kdev 'missing'

printf '\nSummary\n  Failures: %d\n  Warnings: %d\n' "$FAILURES" "$WARNINGS"
if ((FAILURES>0)); then echo '  Result: BROKEN'; exit 1; fi
echo "  Result: OK$([ "$WARNINGS" -gt 0 ] && printf ' (with warnings)' || true)"
