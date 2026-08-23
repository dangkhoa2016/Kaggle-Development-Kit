#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
    pwd
)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

VERSION=9.5.0

export KAGGLE_SYSTEM_DIR="$TMP/.system"

export ELASTIC_VERSIONS="$VERSION"
export ELASTIC_DEFAULT_VERSION="$VERSION"
export ELASTIC_COMPONENTS="elasticsearch"
export ELASTIC_AUTO_START_VERSIONS=""
export ELASTIC_HEAP_SIZE="512m"

# Avoid requiring a real "elastic" system account in deterministic CI.
export ELASTIC_SERVICE_USER="$(id -un)"

# Source production functions without running main().
# shellcheck disable=SC1091
source "$PROJECT_ROOT/install/install-elastic.sh"

# The service user's primary group need not have the same name on every CI host.
ELASTIC_SERVICE_GROUP="$(id -gn "$ELASTIC_SERVICE_USER")"

ESROOT="$KAGGLE_SYSTEM_DIR/elastic/versions/$VERSION"

RUNTIME_CONFIG="$ESROOT/runtime/elasticsearch/config"
CUSTOM_CONFIG="$ESROOT/config/elasticsearch"

mkdir -p \
    "$RUNTIME_CONFIG/jvm.options.d"

echo '===== FIXTURE: UPSTREAM ELASTICSEARCH CONFIG ====='

cat > "$RUNTIME_CONFIG/elasticsearch.yml" <<'CFG'
cluster.name: upstream-default
node.name: upstream-default-node
CFG

cat > "$RUNTIME_CONFIG/jvm.options" <<'CFG'
# upstream jvm.options sentinel
-Xms1g
-Xmx1g
CFG

cat > "$RUNTIME_CONFIG/log4j2.properties" <<'CFG'
# upstream log4j2.properties sentinel
status = error
CFG

cat > "$RUNTIME_CONFIG/role_mapping.yml" <<'CFG'
# upstream role_mapping.yml sentinel
CFG

cat > "$RUNTIME_CONFIG/roles.yml" <<'CFG'
# upstream roles.yml sentinel
CFG

cat > "$RUNTIME_CONFIG/users" <<'CFG'
# upstream users sentinel
CFG

cat > "$RUNTIME_CONFIG/users_roles" <<'CFG'
# upstream users_roles sentinel
CFG

cat > "$RUNTIME_CONFIG/elasticsearch-plugins.example.yml" <<'CFG'
# upstream elasticsearch-plugins.example.yml sentinel
CFG

echo 'UPSTREAM_CONFIG_FIXTURE=PASS'

echo
echo '===== EXECUTE PRODUCTION write_version_config() ====='

write_version_config "$VERSION"

echo 'WRITE_VERSION_CONFIG_RETURNED=PASS'

echo
echo '===== ASSERT UPSTREAM CONFIG BASELINE SEEDED ====='

required_files=(
    log4j2.properties
    jvm.options
    role_mapping.yml
    roles.yml
    users
    users_roles
    elasticsearch-plugins.example.yml
)

for file in "${required_files[@]}"; do
    if [ ! -f "$CUSTOM_CONFIG/$file" ]; then
        echo "FAIL: missing seeded upstream Elasticsearch config: $file" >&2
        exit 1
    fi

    if ! cmp -s \
        "$RUNTIME_CONFIG/$file" \
        "$CUSTOM_CONFIG/$file"
    then
        echo "FAIL: seeded Elasticsearch config differs from upstream: $file" >&2
        exit 1
    fi

    echo "SEEDED=$file"
done

echo 'ELASTIC_UPSTREAM_CONFIG_BASELINE=PASS'

echo
echo '===== ASSERT KDK elasticsearch.yml OVERRIDE ====='

test -f "$CUSTOM_CONFIG/elasticsearch.yml"

grep -Fq \
    'cluster.name: kaggle-dev-9.5.0' \
    "$CUSTOM_CONFIG/elasticsearch.yml"

grep -Fq \
    'node.name: kaggle-dev-9.5.0-1' \
    "$CUSTOM_CONFIG/elasticsearch.yml"

grep -Fq \
    'network.host: 127.0.0.1' \
    "$CUSTOM_CONFIG/elasticsearch.yml"

grep -Fq \
    'http.port: 9200' \
    "$CUSTOM_CONFIG/elasticsearch.yml"

if grep -Fq \
    'cluster.name: upstream-default' \
    "$CUSTOM_CONFIG/elasticsearch.yml"
then
    echo \
      'FAIL: upstream elasticsearch.yml was not replaced by the KDK-managed config.' \
      >&2
    exit 1
fi

echo 'ELASTIC_KDK_YML_OVERRIDE=PASS'

echo
echo '===== ASSERT KDK JVM OVERRIDE LAYER ====='

test -f \
    "$CUSTOM_CONFIG/jvm.options"

test -f \
    "$CUSTOM_CONFIG/jvm.options.d/kaggle.options"

grep -Fq -- \
    '-Xms512m' \
    "$CUSTOM_CONFIG/jvm.options.d/kaggle.options"

grep -Fq -- \
    '-Xmx512m' \
    "$CUSTOM_CONFIG/jvm.options.d/kaggle.options"

echo 'ELASTIC_KDK_JVM_OVERRIDE=PASS'

echo
echo '===== ASSERT UPSTREAM RUNTIME CONFIG UNCHANGED ====='

grep -Fq \
    'cluster.name: upstream-default' \
    "$RUNTIME_CONFIG/elasticsearch.yml"

grep -Fq \
    'upstream jvm.options sentinel' \
    "$RUNTIME_CONFIG/jvm.options"

grep -Fq \
    'upstream log4j2.properties sentinel' \
    "$RUNTIME_CONFIG/log4j2.properties"

echo 'ELASTIC_RUNTIME_CONFIG_UNCHANGED=PASS'

echo
echo 'ELASTIC_CONFIG_SEEDING_REGRESSION=PASS'
