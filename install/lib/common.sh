#!/usr/bin/env bash
# Shared installer helpers. This file is sourced; it is not executed directly.

# Kaggle/containers may set umask 077; the installer requires runtime/service users
# to traverse these directories (755). Set a suitable umask up front so directories
# and files created during installation have the required permissions.
umask 022

common_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

common_log() {
    printf '==> %s\n' "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || common_die "Missing required command: $1"
}

init_privilege() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=()
    else
        command -v sudo >/dev/null 2>&1 || common_die "Run as root or as a user with sudo privileges."
        sudo -n true >/dev/null 2>&1 || sudo true || common_die "Unable to confirm sudo privileges."
        SUDO=(sudo)
    fi
}

run_root() {
    # Keep the abstraction safe for helpers that can also be called directly
    # (for example during cold-restore repair) without an explicit init call.
    if ! declare -p SUDO >/dev/null 2>&1; then
        init_privilege
    fi
    "${SUDO[@]}" "$@"
}

run_as_user() {
    local user="$1"
    shift

    if [ "$(id -un)" = "$user" ]; then
        "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "$user" -- "$@"
        else
            local quoted=""
            printf -v quoted '%q ' "$@"
            su -s /bin/bash "$user" -c "$quoted"
        fi
    else
        sudo -u "$user" -- "$@"
    fi
}

ensure_system_user() {
    local user="$1" home="$2" shell="${3:-/usr/sbin/nologin}"
    if id "$user" >/dev/null 2>&1; then
        return
    fi

    common_log "Creating system user '$user'..."
    require_command useradd
    if command -v getent >/dev/null 2>&1 && getent group "$user" >/dev/null 2>&1; then
        run_root useradd --system --gid "$user" --home-dir "$home" --no-create-home --shell "$shell" "$user"
    else
        run_root useradd --system --user-group --home-dir "$home" --no-create-home --shell "$shell" "$user"
    fi
}

validate_port() {
    local name="$1" value="$2"
    case "$value" in
        ''|*[!0-9]*) common_die "$name must be an integer from 1 to 65535 (current value: '$value')." ;;
    esac
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        common_die "$name must be in the range 1..65535 (current value: '$value')."
    fi
}

make_project_staging_dir() {
    local system_dir="$1" prefix="$2"
    mkdir -p "$system_dir/.staging"
    chmod 755 "$system_dir/.staging"
    mktemp -d "$system_dir/.staging/${prefix}.XXXXXX"
}

apt_download_packages() {
    local destination="$1"
    shift
    [ "$#" -gt 0 ] || common_die "apt_download_packages: no packages were provided."

    require_command apt-get
    run_root mkdir -p "$destination/partial"
    run_root apt-get \
        -o "Dir::Cache::archives=$destination" \
        -o 'APT::Keep-Downloaded-Packages=true' \
        --download-only --reinstall --no-install-recommends -y install "$@"
    run_root chmod -R a+rX "$destination"

    compgen -G "$destination/*.deb" >/dev/null || common_die "APT did not download any .deb files into $destination"
}

extract_deb_directory() {
    local deb_dir="$1" destination="$2" deb
    require_command dpkg-deb
    mkdir -p "$destination"
    shopt -s nullglob
    local debs=("$deb_dir"/*.deb)
    shopt -u nullglob
    [ "${#debs[@]}" -gt 0 ] || common_die "No .deb files found in $deb_dir"

    for deb in "${debs[@]}"; do
        dpkg-deb -x "$deb" "$destination"
    done
}

write_deb_manifest() {
    local deb_dir="$1" output="$2" deb
    : > "$output"
    shopt -s nullglob
    local debs=("$deb_dir"/*.deb)
    shopt -u nullglob
    for deb in "${debs[@]}"; do
        printf '%s\t%s\t%s\n' \
            "$(dpkg-deb -f "$deb" Package)" \
            "$(dpkg-deb -f "$deb" Version)" \
            "$(basename "$deb")" >> "$output"
    done
    sort -u -o "$output" "$output"
}

normalize_runtime_permissions() {
    local runtime="$1"
    find "$runtime" -type d -exec chmod 755 {} +
    find "$runtime" -type f -exec chmod 644 {} +
    find "$runtime" -type f \( -path '*/bin/*' -o -path '*/sbin/*' \) -exec chmod 755 {} +
    find "$runtime" -type f -name '*.so*' -exec chmod 644 {} +
    find "$runtime" -type d -exec chmod go-w {} +
    find "$runtime" -type f -exec chmod go-w {} +
}

atomic_replace_directory() {
    local new_dir="$1" target_dir="$2"
    local parent backup
    parent="$(dirname "$target_dir")"
    backup="$parent/.old-$(basename "$target_dir").$$"

    run_root mkdir -p "$parent"
    run_root rm -rf "$backup"
    if [ -e "$target_dir" ]; then
        run_root mv "$target_dir" "$backup"
    fi

    if run_root mv "$new_dir" "$target_dir"; then
        run_root rm -rf "$backup"
    else
        run_root rm -rf "$target_dir"
        [ ! -e "$backup" ] || run_root mv "$backup" "$target_dir"
        common_die "Unable to replace the runtime at $target_dir; the previous runtime has been restored."
    fi
}

ensure_system_scripts_executable() {
    local system_dir="$1" script
    [ -d "$system_dir" ] || return 0
    common_log "Ensuring every .sh script in $system_dir is executable..."
    while IFS= read -r -d '' script; do
        # Runtime control scripts are root-owned by installer design. During a
        # cold restore the caller may be non-root, so both ownership and mode
        # repairs must go through the shared privilege abstraction.
        run_root chown root:root "$script"
        run_root chmod 755 "$script"
    done < <(run_root find "$system_dir" -type f -name '*.sh' -print0)
}
