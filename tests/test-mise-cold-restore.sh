#!/usr/bin/env bash
set -euo pipefail

# Regression: a persisted mise tree can survive a Kaggle VM/session transition
# while regular files under tool bin/ directories lose executable bits.
#
# Required behavior:
# 1. install-other.sh must repair executable permissions before deciding that a
#    configured tool is healthy.
# 2. A configured tool that is still unusable/missing after permission repair
#    must be force-reinstalled at the exact pin.
# 3. Verification must fail closed on a system-PATH fallback or a wrong version.
# 4. Health probes must disable mise auto-install so diagnostics cannot silently
#    mutate a broken persisted tree.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    FAILURES=$((FAILURES + 1))
}

SYS="$TMP/system"
MISE_ROOT="$SYS/mise"
FAKE_LOG="$TMP/force-install.log"
DEFAULTS="$TMP/defaults.env"

mkdir -p \
    "$MISE_ROOT/bin" \
    "$MISE_ROOT/data/installs/node/26.6.0/bin" \
    "$MISE_ROOT/data/installs/ruby/3.4.9/bin" \
    "$MISE_ROOT/data/installs/npm/12.0.2/package/bin" \
    "$MISE_ROOT/data/installs/yarn/1.22.22/bin"

cat > "$DEFAULTS" <<'EOF_DEFAULTS'
MISE_VERSION=2026.8.1
TOOL_NODE_VERSION=26.6.0
TOOL_RUBY_VERSION=3.4.9
TOOL_NPM_VERSION=12.0.2
TOOL_YARN_VERSION=1.22.22
MISE_ADD_BASHRC_HOOK=0
EOF_DEFAULTS

cat > "$MISE_ROOT/data/installs/node/26.6.0/bin/node" <<'EOF_NODE'
#!/usr/bin/env bash
printf 'v26.6.0\n'
EOF_NODE

cat > "$MISE_ROOT/data/installs/ruby/3.4.9/bin/ruby" <<'EOF_RUBY'
#!/usr/bin/env bash
printf 'ruby 3.4.9 (2026-01-01 revision test) [x86_64-linux]\n'
EOF_RUBY

cat > "$MISE_ROOT/data/installs/npm/12.0.2/package/bin/npm-cli.js" <<'EOF_NPM'
#!/usr/bin/env bash
printf '12.0.2\n'
EOF_NPM

cat > "$MISE_ROOT/data/installs/yarn/1.22.22/bin/yarn" <<'EOF_YARN'
#!/usr/bin/env bash
printf '1.22.22\n'
EOF_YARN

# Model the real persisted evidence: executable files became regular 0644 files.
chmod 0644 \
    "$MISE_ROOT/data/installs/node/26.6.0/bin/node" \
    "$MISE_ROOT/data/installs/ruby/3.4.9/bin/ruby" \
    "$MISE_ROOT/data/installs/npm/12.0.2/package/bin/npm-cli.js" \
    "$MISE_ROOT/data/installs/yarn/1.22.22/bin/yarn"

# Deliberately omit npm's package/bin/npm launcher. Permission repair alone is
# insufficient for this case; the exact npm pin must be force-reinstalled.
cat > "$MISE_ROOT/bin/mise" <<'EOF_MISE'
#!/usr/bin/env bash
set -euo pipefail

root="${KDEV_TEST_MISE_ROOT:?}"
force_log="${KDEV_TEST_FORCE_LOG:?}"

if [ "${1:-}" = "-y" ]; then
    shift
fi

case "${1:-}" in
    version|--version)
        printf '2026.8.1 linux-x64 (fixture)\n'
        ;;
    use)
        exit 0
        ;;
    settings)
        exit 0
        ;;
    install)
        shift
        if [ "${1:-}" = "--force" ]; then
            shift
            spec="${1:?missing exact tool spec}"
            printf '%s\n' "$spec" >> "$force_log"
            case "$spec" in
                node@26.6.0)
                    chmod 0755 "$root/data/installs/node/26.6.0/bin/node"
                    ;;
                ruby@3.4.9)
                    chmod 0755 "$root/data/installs/ruby/3.4.9/bin/ruby"
                    ;;
                npm@12.0.2)
                    chmod 0755 "$root/data/installs/npm/12.0.2/package/bin/npm-cli.js"
                    ln -sfn npm-cli.js "$root/data/installs/npm/12.0.2/package/bin/npm"
                    ;;
                yarn@1.22.22)
                    chmod 0755 "$root/data/installs/yarn/1.22.22/bin/yarn"
                    ;;
                *)
                    printf 'unexpected force-install: %s\n' "$spec" >&2
                    exit 92
                    ;;
            esac
        fi
        ;;
    which)
        tool="${2:?missing tool}"
        case "$tool" in
            node) path="$root/data/installs/node/26.6.0/bin/node" ;;
            ruby) path="$root/data/installs/ruby/3.4.9/bin/ruby" ;;
            npm)  path="$root/data/installs/npm/12.0.2/package/bin/npm" ;;
            yarn) path="$root/data/installs/yarn/1.22.22/bin/yarn" ;;
            *) exit 1 ;;
        esac
        [ -x "$path" ] || exit 1
        printf '%s\n' "$path"
        ;;
    exec)
        shift
        [ "${1:-}" = "--" ] && shift
        tool="${1:?missing tool}"
        shift
        [ "${1:-}" = "--version" ] || {
            printf 'fixture only supports --version\n' >&2
            exit 93
        }
        case "$tool" in
            node)
                target="$root/data/installs/node/26.6.0/bin/node"
                if [ -x "$target" ]; then exec "$target" --version; fi
                printf 'v20.19.0\n'
                ;;
            ruby)
                target="$root/data/installs/ruby/3.4.9/bin/ruby"
                [ -x "$target" ] || { printf 'Permission denied\n' >&2; exit 126; }
                exec "$target" --version
                ;;
            npm)
                target="$root/data/installs/npm/12.0.2/package/bin/npm"
                if [ -x "$target" ]; then exec "$target" --version; fi
                printf '10.8.2\n'
                ;;
            yarn)
                target="$root/data/installs/yarn/1.22.22/bin/yarn"
                [ -x "$target" ] || { printf 'Permission denied\n' >&2; exit 126; }
                exec "$target" --version
                ;;
            *) exit 1 ;;
        esac
        ;;
    *)
        printf 'unsupported fixture mise command: %s\n' "$*" >&2
        exit 94
        ;;
esac
EOF_MISE
chmod 0755 "$MISE_ROOT/bin/mise"

cat > "$MISE_ROOT/env.sh" <<EOF_ENV
#!/usr/bin/env bash
export MISE_ROOT="$MISE_ROOT"
export MISE_DATA_DIR="$MISE_ROOT/data"
export MISE_CONFIG_DIR="$MISE_ROOT/config"
export MISE_GLOBAL_CONFIG_FILE="$MISE_ROOT/config/config.toml"
export MISE_CACHE_DIR="$MISE_ROOT/cache"
export MISE_STATE_DIR="$MISE_ROOT/state"
export MISE_TMP_DIR="$MISE_ROOT/tmp"
export PATH="$MISE_ROOT/bin:\$PATH"
EOF_ENV
chmod 0755 "$MISE_ROOT/env.sh"

export KAGGLE_SYSTEM_DIR="$SYS"
export KAGGLE_DEV_DEFAULTS_FILE="$DEFAULTS"
export KDEV_TEST_MISE_ROOT="$MISE_ROOT"
export KDEV_TEST_FORCE_LOG="$FAKE_LOG"
: > "$FAKE_LOG"

# Source production code without executing main.
# shellcheck source=/dev/null
source "$ROOT/install/install-other.sh"

# ---------------------------------------------------------------------------
# Scenario 1: configure_and_install_tools() must repair the real cold-restore
# symptom and force-reinstall only a pin that remains structurally unusable.
# ---------------------------------------------------------------------------
if ! configure_and_install_tools >"$TMP/configure.log" 2>&1; then
    fail "configure_and_install_tools failed during cold-restore repair (log: $TMP/configure.log)"
fi

for target in \
    "$MISE_ROOT/data/installs/node/26.6.0/bin/node" \
    "$MISE_ROOT/data/installs/ruby/3.4.9/bin/ruby" \
    "$MISE_ROOT/data/installs/npm/12.0.2/package/bin/npm-cli.js" \
    "$MISE_ROOT/data/installs/yarn/1.22.22/bin/yarn"
do
    [ -x "$target" ] || fail "persisted executable was not repaired: $target"
done

[ -x "$MISE_ROOT/data/installs/npm/12.0.2/package/bin/npm" ] || \
    fail "npm launcher was not recovered by exact-pin reinstall"

grep -qx 'npm@12.0.2' "$FAKE_LOG" || \
    fail "broken npm structure did not trigger exact-pin force reinstall"

if grep -Eq '^(node@26\.6\.0|ruby@3\.4\.9|yarn@1\.22\.22)$' "$FAKE_LOG"; then
    fail "healthy tools were force-reinstalled unnecessarily: $(tr '\n' ' ' < "$FAKE_LOG")"
fi

# ---------------------------------------------------------------------------
# Scenario 2: verify() must fail closed instead of accepting a PATH fallback.
# Re-break Node after successful repair. The fixture returns system Node 20.19.0
# when the managed Node pin is not executable.
# ---------------------------------------------------------------------------
chmod 0644 "$MISE_ROOT/data/installs/node/26.6.0/bin/node"

verify_rc=0
(
    verify
) >"$TMP/verify-broken.log" 2>&1 || verify_rc=$?

if [ "$verify_rc" -eq 0 ]; then
    fail "verify() returned success although managed node@26.6.0 was non-executable and fallback was v20.19.0"
fi

# Restore and prove strict verification succeeds for all exact pins.
chmod 0755 "$MISE_ROOT/data/installs/node/26.6.0/bin/node"
if ! verify >"$TMP/verify-good.log" 2>&1; then
    fail "verify() rejected a healthy exact pinned toolchain (log: $TMP/verify-good.log)"
fi

if [ "$FAILURES" -ne 0 ]; then
    printf 'FAIL: %d mise cold-restore regression assertion(s) failed\n' "$FAILURES" >&2
    exit 1
fi

echo 'PASS: mise cold restore repairs executable state, reinstalls only unhealthy exact pins, and verifies fail-closed'
