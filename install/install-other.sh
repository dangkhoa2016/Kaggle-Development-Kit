#!/usr/bin/env bash
set -euo pipefail

# Cài mise + Node.js + Ruby + npm + Yarn vào .system/mise.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEM_DIR="$PROJECT_ROOT/.system"
MISE_HOME="$SYSTEM_DIR/mise"
MISE_BIN="$MISE_HOME/bin/mise"
ENV_FILE="$MISE_HOME/env.sh"
MISE_TOML="$PROJECT_ROOT/mise.toml"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/load-config.sh
source "$SCRIPT_DIR/lib/load-config.sh"
load_project_config "$PROJECT_ROOT"

# Phiên bản được pin; có thể override bằng .kaggle-dev.env hoặc env var.
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
    command -v "$1" >/dev/null 2>&1 || die "Thiếu lệnh bắt buộc: $1"
}

installed_mise_version() {
    [ -x "$MISE_BIN" ] || return 0
    "$MISE_BIN" version 2>/dev/null | head -n1 | awk '{ sub(/^v/, "", $1); print $1 }'
}

install_mise() {
    local current installer actual_sha
    current="$(installed_mise_version)"
    if [ "$current" = "$MISE_VERSION" ]; then
        log "Đã có mise $MISE_VERSION tại $MISE_BIN."
        return
    fi

    require_command curl
    require_command sha256sum
    installer="$(mktemp)"
    trap 'rm -f "$installer"' RETURN
    log "Tải installer chính thức và cài mise $MISE_VERSION..."
    curl -fsSL https://mise.run -o "$installer"

    if [ -n "$MISE_INSTALLER_SHA256" ]; then
        actual_sha="$(sha256sum "$installer" | awk '{print $1}')"
        [ "$actual_sha" = "$MISE_INSTALLER_SHA256" ] \
            || die "SHA256 của mise installer không khớp."
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
        || die "Cài mise thất bại hoặc version không đúng: $(installed_mise_version)"
}

write_env() {
    mkdir -p "$MISE_HOME"
    cat > "$ENV_FILE" <<'ENV_SCRIPT'
#!/usr/bin/env bash

MISE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export MISE_ROOT

# Chỉ export MISE_PROJECT_ROOT khi thư mục đó thực sự là project root (có mise.toml).
# Sau khi .system được di chuyển ra ngoài project root, "../.." không còn đúng;
# để nguyên MISE_PROJECT_ROOT sẽ khiến mise dò sai config. Khi đó bỏ export để
# mise tự tìm mise.toml theo cwd.
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
    echo "Không tìm thấy mise tại $MISE_ROOT/bin/mise" >&2
    return 1 2>/dev/null || exit 1
fi

eval "$("$MISE_ROOT/bin/mise" activate bash)"
ENV_SCRIPT
    chmod 755 "$ENV_FILE"
}

configure_and_install_tools() {
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    cd "$PROJECT_ROOT"

    # Dùng chính CLI của mise để cập nhật [tools], nên các section khác trong
    # mise.toml (tasks/env/settings...) được giữ nguyên.
    mise -y use --pin --path "$MISE_TOML" \
        "node@$TOOL_NODE_VERSION" \
        "ruby@$TOOL_RUBY_VERSION" \
        "npm@$TOOL_NPM_VERSION" \
        "yarn@$TOOL_YARN_VERSION"

    # Không để việc thiếu setting này làm hỏng toàn bộ bộ cài trên mise mới/cũ.
    mise settings set ruby.compile false >/dev/null 2>&1 \
        || log "Cảnh báo: mise không hỗ trợ setting ruby.compile=false; tiếp tục cài."

    mise install
}

update_bashrc_hook() {
    local begin='# BEGIN KAGGLE PROJECT MISE' end='# END KAGGLE PROJECT MISE'
    local bashrc="$HOME/.bashrc" tmp

    [ "$MISE_ADD_BASHRC_HOOK" = "1" ] || {
        log "Không sửa ~/.bashrc (bật bằng MISE_ADD_BASHRC_HOOK=1)."
        return
    }

    touch "$bashrc" 2>/dev/null || {
        log "Không thể ghi $bashrc; hãy source $ENV_FILE thủ công."
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
    log "Đã cập nhật block mise trong ~/.bashrc."
}

verify() {
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    cd "$PROJECT_ROOT"

    echo
    printf '%-10s %s\n' mise "$(mise version | head -1)"
    printf '%-10s %s\n' node "$(mise exec -- node --version)"
    printf '%-10s %s\n' ruby "$(mise exec -- ruby --version | head -1)"
    printf '%-10s %s\n' npm "$(mise exec -- npm --version)"
    printf '%-10s %s\n' yarn "$(mise exec -- yarn --version)"
    echo
    echo "Kích hoạt trong shell hiện tại: source $ENV_FILE"
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
