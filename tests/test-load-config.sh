#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
value="$(bash -c 'source "$1/install/lib/load-config.sh"; version_env_key "1.18.3-test+foo"' _ "$ROOT")"
[ "$value" = '1_18_3_test_foo' ] || { echo "unexpected key: $value" >&2; exit 1; }
echo 'PASS: portable version_env_key'
