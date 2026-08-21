#!/usr/bin/env bash
set -euo pipefail

# Install mise + Node.js + Ruby + npm + Yarn into .system/mise.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEM_DIR="${KAGGLE_SYSTEM_DIR:-$PROJECT_ROOT/.system}"
MISE_HOME="$SYSTEM_DIR/mise"
MISE_BIN="$MISE_HOME/bin/mise"
ENV_FILE="$MISE_HOME/env.sh"
MISE_TOML="$PROJECT_ROOT/mise.toml"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/load-config.sh
source "$SCRIPT_DIR/lib/load-config.sh"
load_project_config "$PROJECT_ROOT"

# Versions are pinned and can be overridden via .kaggle-dev.env or environment variables.
MISE_VERSION="${MISE_VERSION:-2026.8.1}"
TOOL_NODE_VERSION="${TOOL_NODE_VERSION:-${MISE_NODE_VERSION:-26.6.0}}"
TOOL_RUBY_VERSION="${TOOL_RUBY_VERSION:-${MISE_RUBY_VERSION:-3.4.9}}"
TOOL_NPM_VERSION="${TOOL_NPM_VERSION:-${MISE_NPM_VERSION:-12.0.2}}"
TOOL_YARN_VERSION="${TOOL_YARN_VERSION:-${MISE_YARN_VERSION:-1.22.22}}"
MISE_ADD_BASHRC_HOOK="${MISE_ADD_BASHRC_HOOK:-0}"
MISE_INSTALLER_SHA256="${MISE_INSTALLER_SHA256:-}"

log() { printf '[install-other] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

repair_restored_tool_permissions() {
    # Kaggle cold restore can preserve the mise install tree while executable
    # bits on regular files under bin/sbin are lost. Repair only executable
    # locations; do not make the whole tool tree writable/executable.
    local installs="$MISE_HOME/data/installs" file

    [ -d "$installs" ] || return 0
    while IFS= read -r -d '' file; do
        [ -x "$file" ] || run_root chmod 0755 "$file"
    done < <(
        find "$installs" -type f \
            \( -path '*/bin/*' -o -path '*/sbin/*' \) -print0
    )
}

managed_tool_path() {
    local tool="$1" path

    path="$(
        MISE_AUTO_INSTALL=0 MISE_EXEC_AUTO_INSTALL=0 \
            "$MISE_BIN" which "$tool" 2>/dev/null
    )" || return 1
    [ -n "$path" ] || return 1
    case "$path" in
        "$MISE_HOME"/data/installs/*) ;;
        *) return 1 ;;
    esac
    [ -x "$path" ] || return 1
    printf '%s\n' "$path"
}

detected_tool_version() {
    local tool="$1" output first

    output="$(
        MISE_AUTO_INSTALL=0 MISE_EXEC_AUTO_INSTALL=0 \
            "$MISE_BIN" exec -- "$tool" --version 2>/dev/null
    )" || return 1
    first="${output%%$'\n'*}"

    case "$tool" in
        node)
            first="${first#v}"
            ;;
        ruby)
            set -- $first
            [ "${1:-}" = "ruby" ] && [ -n "${2:-}" ] || return 1
            first="$2"
            ;;
    esac

    printf '%s\n' "$first"
}

tool_is_healthy() {
    local tool="$1" expected="$2" actual

    managed_tool_path "$tool" >/dev/null || return 1
    actual="$(detected_tool_version "$tool")" || return 1
    [ "$actual" = "$expected" ]
}

ensure_tool_healthy() {
    local tool="$1" expected="$2" actual

    if tool_is_healthy "$tool" "$expected"; then
        return 0
    fi

    log "Restored $tool@$expected is missing, non-executable, or version-mismatched; force-reinstalling the exact pin..."
    "$MISE_BIN" install --force "$tool@$expected"
    repair_restored_tool_permissions

    if ! tool_is_healthy "$tool" "$expected"; then
        actual="$(detected_tool_version "$tool" 2>/dev/null || true)"
        die "$tool exact-pin recovery failed: expected $expected, detected ${actual:-unavailable}"
    fi
}

verify_exact_tool() {
    local tool="$1" expected="$2" actual path

    path="$(managed_tool_path "$tool")" ||
        die "$tool@$expected is not resolved to an executable under $MISE_HOME/data/installs"
    actual="$(detected_tool_version "$tool")" ||
        die "$tool@$expected could not execute through mise"
    [ "$actual" = "$expected" ] ||
        die "$tool version mismatch: expected $expected, detected $actual ($path)"
    printf '%s\n' "$actual"
}

installed_mise_version() {
    [ -x "$MISE_BIN" ] || return 0
    "$MISE_BIN" version 2>/dev/null | head -n1 | awk '{ sub(/^v/, "", $1); print $1 }'
}

install_mise() {
    local current installer actual_sha
    current="$(installed_mise_version)"
    if [ "$current" = "$MISE_VERSION" ]; then
        log "mise $MISE_VERSION is already installed at $MISE_BIN."
        return
    fi

    require_command curl
    require_command sha256sum
    installer="$(mktemp)"
    trap 'rm -f "$installer"' RETURN
    log "Downloading the official installer and installing mise $MISE_VERSION..."
    curl -fsSL https://mise.run -o "$installer"

    if [ -n "$MISE_INSTALLER_SHA256" ]; then
        actual_sha="$(sha256sum "$installer" | awk '{print $1}')"
        [ "$actual_sha" = "$MISE_INSTALLER_SHA256" ] \
            || die "mise installer SHA256 mismatch."
    fi

    mkdir -p "$MISE_HOME/bin"
    MISE_VERSION="$MISE_VERSION" \
    MISE_INSTALL_PATH="$MISE_BIN" \
    MISE_INSTALL_SKIP_IF_EXISTS=1 \
    MISE_INSTALL_HELP=0 \
        sh "$installer"

    rm -f "$installer"
    trap - RETURN
    [ "$(installed_mise_version)" = "$MISE_VERSION" ] \
        || die "mise installation failed or returned the wrong version: $(installed_mise_version)"
}

write_env() {
    mkdir -p "$MISE_HOME"
    cat > "$ENV_FILE" <<'ENV_SCRIPT'
#!/usr/bin/env bash

MISE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export MISE_ROOT

# Export MISE_PROJECT_ROOT only when that directory is the actual project root (contains mise.toml).
# After .system is moved outside the project root, "../.." is no longer correct;
# keeping MISE_PROJECT_ROOT would make mise discover the wrong config. In that case, omit the export so
# mise can discover mise.toml from the current working directory.
MISE_PROJECT_ROOT="$(cd "$MISE_ROOT/../.." 2>/dev/null && pwd)"
if [ -f "$MISE_PROJECT_ROOT/mise.toml" ] \
    || [ -f "$MISE_PROJECT_ROOT/.mise.toml" ] \
    || [ -f "$MISE_PROJECT_ROOT/mise.lock.toml" ]; then
    export MISE_PROJECT_ROOT
else
    unset MISE_PROJECT_ROOT
fi

export PATH="$MISE_ROOT/bin:$PATH"
export MISE_DATA_DIR="$MISE_ROOT/data"
export MISE_CONFIG_DIR="$MISE_ROOT/config"
export MISE_GLOBAL_CONFIG_FILE="$MISE_ROOT/config/config.toml"
export MISE_CACHE_DIR="$MISE_ROOT/cache"
export MISE_STATE_DIR="$MISE_ROOT/state"
export MISE_TMP_DIR="$MISE_ROOT/tmp"

mkdir -p \
    "$MISE_DATA_DIR" \
    "$MISE_CONFIG_DIR" \
    "$MISE_CACHE_DIR" \
    "$MISE_STATE_DIR" \
    "$MISE_TMP_DIR"

if [ ! -x "$MISE_ROOT/bin/mise" ]; then
    echo "mise was not found at $MISE_ROOT/bin/mise" >&2
    return 1 2>/dev/null || exit 1
fi

eval "$("$MISE_ROOT/bin/mise" activate bash)"
ENV_SCRIPT
    chmod 755 "$ENV_FILE"
}

all_tools_healthy() {
    tool_is_healthy node "$TOOL_NODE_VERSION" \
        && tool_is_healthy ruby "$TOOL_RUBY_VERSION" \
        && tool_is_healthy npm "$TOOL_NPM_VERSION" \
        && tool_is_healthy yarn "$TOOL_YARN_VERSION"
}

configure_and_install_tools() {
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    cd "$PROJECT_ROOT"

    # A restored /kaggle/working tree may retain tool payloads whose executable
    # bits were stripped. Repair those first, then prove every exact configured
    # tool works with auto-install disabled before invoking any install-capable
    # mise command. This is the healthy cold-restore no-network fast path.
    repair_restored_tool_permissions
    if all_tools_healthy; then
        log "All exact mise-managed tools are already healthy; skipping mise use/install."
        return 0
    fi

    # Recovery path: update [tools] while preserving other mise.toml sections.
    # `mise use` may install missing tools; that is intentional only after the
    # offline health probe above has proved recovery is required.
    mise -y use --pin --path "$MISE_TOML" \
        "node@$TOOL_NODE_VERSION" \
        "ruby@$TOOL_RUBY_VERSION" \
        "npm@$TOOL_NPM_VERSION" \
        "yarn@$TOOL_YARN_VERSION"

    # Do not let an unavailable setting break the entire installer on newer/older mise versions.
    mise settings set ruby.compile false >/dev/null 2>&1 \
        || log "Warning: mise does not support ruby.compile=false; continuing installation."

    repair_restored_tool_permissions
    mise install

    # Permission repair cannot recover missing launchers/symlinks. Probe each
    # exact configured tool with auto-install disabled and force-reinstall only
    # a pin that is still unhealthy.
    ensure_tool_healthy node "$TOOL_NODE_VERSION"
    ensure_tool_healthy ruby "$TOOL_RUBY_VERSION"
    ensure_tool_healthy npm "$TOOL_NPM_VERSION"
    ensure_tool_healthy yarn "$TOOL_YARN_VERSION"
}

update_bashrc_hook() {
    local begin='# BEGIN KAGGLE PROJECT MISE' end='# END KAGGLE PROJECT MISE'
    local bashrc="$HOME/.bashrc" tmp

    [ "$MISE_ADD_BASHRC_HOOK" = "1" ] || {
        log "Leaving ~/.bashrc unchanged (enable with MISE_ADD_BASHRC_HOOK=1)."
        return
    }

    touch "$bashrc" 2>/dev/null || {
        log "Unable to write $bashrc; source $ENV_FILE manually."
        return
    }
    tmp="$(mktemp)"
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$bashrc" > "$tmp"
    cat >> "$tmp" <<EOF

$begin
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
$end
EOF
    cat "$tmp" > "$bashrc"
    rm -f "$tmp"
    log "Updated the mise block in ~/.bashrc."
}

verify() {
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    cd "$PROJECT_ROOT"

    local node_version ruby_version npm_version yarn_version

    node_version="$(verify_exact_tool node "$TOOL_NODE_VERSION")" || return 1
    ruby_version="$(verify_exact_tool ruby "$TOOL_RUBY_VERSION")" || return 1
    npm_version="$(verify_exact_tool npm "$TOOL_NPM_VERSION")" || return 1
    yarn_version="$(verify_exact_tool yarn "$TOOL_YARN_VERSION")" || return 1

    echo
    printf '%-10s %s\n' mise "$("$MISE_BIN" version | head -1)"
    printf '%-10s v%s\n' node "$node_version"
    printf '%-10s %s\n' ruby "$ruby_version"
    printf '%-10s %s\n' npm "$npm_version"
    printf '%-10s %s\n' yarn "$yarn_version"
    echo
    echo "Activate in the current shell: source $ENV_FILE"
}

main() {
    mkdir -p "$SYSTEM_DIR" "$MISE_HOME"
    chmod 755 "$SYSTEM_DIR" "$MISE_HOME"
    install_mise
    write_env
    configure_and_install_tools
    update_bashrc_hook
    ensure_system_scripts_executable "$SYSTEM_DIR"
    verify
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
