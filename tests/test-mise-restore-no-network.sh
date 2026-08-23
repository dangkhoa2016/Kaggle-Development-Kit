#!/usr/bin/env bash
set -euo pipefail

# Healthy exact mise-managed tools must be reusable after cold restore without
# invoking `mise use` / `mise install`, both of which may perform install/network
# work. Missing or unhealthy tools remain owned by the existing recovery path.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"

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

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export KAGGLE_SYSTEM_DIR="$TMP/system"
export KAGGLE_DEV_DEFAULTS_FILE=/dev/null
export KAGGLE_DEV_CONFIG_FILE=/dev/null
export MISE_VERSION=2026.8.1
export TOOL_NODE_VERSION=26.6.0
export TOOL_RUBY_VERSION=3.4.9
export TOOL_NPM_VERSION=12.0.2
export TOOL_YARN_VERSION=1.22.22
export MISE_ADD_BASHRC_HOOK=0
export KDEV_TEST_CALLS_LOG="$TMP/mise-calls.log"
: > "$KDEV_TEST_CALLS_LOG"

# shellcheck disable=SC1090
source "$ROOT/install/install-other.sh"

mkdir -p "$MISE_HOME/bin" \
         "$MISE_HOME/data/installs/node/26.6.0/bin" \
         "$MISE_HOME/data/installs/ruby/3.4.9/bin" \
         "$MISE_HOME/data/installs/npm/12.0.2/bin" \
         "$MISE_HOME/data/installs/yarn/1.22.22/bin"

cat > "$MISE_HOME/data/installs/node/26.6.0/bin/node" <<'NODE'
#!/usr/bin/env bash
printf 'v26.6.0\n'
NODE
cat > "$MISE_HOME/data/installs/ruby/3.4.9/bin/ruby" <<'RUBY'
#!/usr/bin/env bash
printf 'ruby 3.4.9 (fixture)\n'
RUBY
cat > "$MISE_HOME/data/installs/npm/12.0.2/bin/npm" <<'NPM'
#!/usr/bin/env bash
printf '12.0.2\n'
NPM
cat > "$MISE_HOME/data/installs/yarn/1.22.22/bin/yarn" <<'YARN'
#!/usr/bin/env bash
printf '1.22.22\n'
YARN
chmod 0755 \
  "$MISE_HOME/data/installs/node/26.6.0/bin/node" \
  "$MISE_HOME/data/installs/ruby/3.4.9/bin/ruby" \
  "$MISE_HOME/data/installs/npm/12.0.2/bin/npm" \
  "$MISE_HOME/data/installs/yarn/1.22.22/bin/yarn"

cat > "$MISE_BIN" <<'MISE'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${KDEV_TEST_CALLS_LOG:?}"
cmd="${1:-}"
[ "$#" -eq 0 ] || shift
case "$cmd" in
  version)
    printf '2026.8.1 linux-x64 (fixture)\n'
    ;;
  activate)
    # write_env only needs a valid activation command. The production env file
    # already exports all managed directories before invoking activation.
    exit 0
    ;;
  which)
    tool="${1:?}"
    case "$tool" in
      node) printf '%s\n' "$ROOT/data/installs/node/26.6.0/bin/node" ;;
      ruby) printf '%s\n' "$ROOT/data/installs/ruby/3.4.9/bin/ruby" ;;
      npm)  printf '%s\n' "$ROOT/data/installs/npm/12.0.2/bin/npm" ;;
      yarn) printf '%s\n' "$ROOT/data/installs/yarn/1.22.22/bin/yarn" ;;
      *) exit 1 ;;
    esac
    ;;
  exec)
    [ "${1:-}" = -- ] || exit 2
    shift
    tool="${1:?}"; shift
    case "$tool" in
      node) exec "$ROOT/data/installs/node/26.6.0/bin/node" "$@" ;;
      ruby) exec "$ROOT/data/installs/ruby/3.4.9/bin/ruby" "$@" ;;
      npm)  exec "$ROOT/data/installs/npm/12.0.2/bin/npm" "$@" ;;
      yarn) exec "$ROOT/data/installs/yarn/1.22.22/bin/yarn" "$@" ;;
      *) exit 1 ;;
    esac
    ;;
  use|install)
    printf '%s\n' "$cmd $*" >> "$LOG"
    exit 97
    ;;
  settings)
    printf '%s\n' "settings $*" >> "$LOG"
    exit 97
    ;;
  *)
    printf 'unexpected mise command: %s %s\n' "$cmd" "$*" >&2
    exit 98
    ;;
esac
MISE
chmod 0755 "$MISE_BIN"

# The checked-in mise.toml only needs to exist for PROJECT_ROOT discovery in
# env.sh; this test replaces no repository source/config.
[ -f "$MISE_TOML" ] || fail "expected project mise.toml at $MISE_TOML"

rc=0
main >"$TMP/out.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "healthy restored mise toolchain did install/network work or failed validation (rc=$rc): $(cat "$TMP/out.log")"
[ ! -s "$KDEV_TEST_CALLS_LOG" ] || fail "healthy toolchain invoked install/config mutation path: $(cat "$KDEV_TEST_CALLS_LOG")"
grep -q 'exact mise-managed tools are already healthy' "$TMP/out.log" ||
  fail 'healthy toolchain did not report restore reuse fast path'

# The health aggregate must still become false when an exact payload is absent;
# this is what preserves targeted recovery instead of blind reuse.
rm -f "$MISE_HOME/data/installs/npm/12.0.2/bin/npm"
if all_tools_healthy; then
    fail 'missing npm payload was incorrectly classified as a healthy exact toolchain'
fi

echo 'PASS: healthy exact mise toolchain skips mise use/install while missing payload still requires recovery'
