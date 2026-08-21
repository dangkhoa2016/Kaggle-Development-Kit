#!/usr/bin/env bash
# Shared configuration loader for the Kaggle development environment.
# This file is sourced by installers; it is not intended to be executed directly.

load_project_config() {
    local project_root="$1"
    local defaults_file="${KAGGLE_DEV_DEFAULTS_FILE:-$project_root/config/defaults.env}"
    local user_file="${KAGGLE_DEV_CONFIG_FILE:-$project_root/.kaggle-dev.env}"

    # defaults.env is repository-controlled; .kaggle-dev.env is user-controlled and gitignored.
    if [ -f "$defaults_file" ]; then
        # shellcheck disable=SC1090
        set -a; source "$defaults_file"; set +a
    fi
    if [ -f "$user_file" ]; then
        # shellcheck disable=SC1090
        set -a; source "$user_file"; set +a
    fi
}

version_env_key() {
    # 8.10.0 -> 8_10_0 ; 9.5.0-SNAPSHOT -> 9_5_0_SNAPSHOT
    printf '%s' "$1" | tr '.+-' '___' | tr -cd '[:alnum:]_'
}

value_for_version() {
    # value_for_version PREFIX VERSION FALLBACK
    # Example: PREFIX=REDIS_PORT, VERSION=8.10.0 -> REDIS_PORT_8_10_0
    local prefix="$1" version="$2" fallback="${3:-}" key variable value
    key="$(version_env_key "$version")"
    variable="${prefix}_${key}"
    value="${!variable:-}"
    printf '%s\n' "${value:-$fallback}"
}

list_contains() {
    local needle="$1" list="${2:-}" item
    for item in $list; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

validate_unique_ports() {
    # Usage: validate_unique_ports "label" "v1=port v2=port ..."
    local label="$1" pairs="$2" pair version port seen=""
    for pair in $pairs; do
        version="${pair%%=*}"
        port="${pair#*=}"
        validate_port "$label port for $version" "$port"
        if [[ " $seen " == *" $port "* ]]; then
            common_die "$label: port $port bị dùng bởi nhiều version/instance. Hãy cấu hình port khác nhau."
        fi
        seen="$seen $port"
    done
}
