# Installer architecture

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](README.vi.md)

All installers automatically load `config/defaults.env` followed by the local, gitignored `.kaggle-dev.env`.

- `install-all.sh`: orchestrates SQLite, PostgreSQL, Redis, Elastic, Qdrant, and mise tools.
- `install-postgres.sh`: multi-major PostgreSQL runtime from PGDG, isolated data/log/run directories, optional pgvector.
- `install-redis.sh`: multiple exact Redis releases compiled from official source into versioned runtimes and instances.
- `install-elastic.sh`: multiple exact Elastic Stack versions, isolated runtime/config/data/log/run trees, official SHA-512 verification.
- `install-qdrant.sh`: multiple exact Qdrant releases through one QNP 1.0.0 source checkout pinned by full Git commit, with isolated instance roots and loopback-only local endpoints.
- `install-other.sh`: mise and pinned Node/Ruby/npm/Yarn versions.
- `lib/common.sh`: privilege, package extraction, permissions, and atomic runtime replacement helpers.
- `lib/load-config.sh`: common configuration/version-key/list helpers.

Recommended use:

```bash
bash install/install-all.sh install
bash scripts/doctor.sh
bin/kdev versions
```

Restore an existing `.system` tree:

```bash
bash install/install-all.sh bootstrap
```

Bootstrap is cold-restore safe: after a Kaggle VM/runtime reset it recreates the missing service users (including the Qdrant service user recorded in `.system/qdrant/service-user`) and repairs persisted Qdrant ownership — `storage/`, `snapshots/`, `logs/`, `tmp/` regain `<user>:<user>`, while `config/qdrant.yaml` regains `root:<user>` and keeps its restrictive `0640` mode. Every privileged repair routes through the shared root/sudo abstraction and bootstrap fails when a required repair cannot be restored. Like every installer in this repository it honors `KAGGLE_SYSTEM_DIR`, so the whole runtime tree can live on persistent storage.

### PostgreSQL

```bash
POSTGRES_VERSIONS="16 18" \
POSTGRES_PORT_16=5432 \
POSTGRES_PORT_18=5433 \
bash install/install-postgres.sh
```

Only versions in `POSTGRES_AUTO_START_VERSIONS` remain running after validation. `POSTGRES_INSTALL_PGVECTOR=1` installs matching pgvector packages for each requested major.

### Redis

```bash
REDIS_VERSIONS="7.4.10 8.10.0" \
REDIS_PORT_7_4_10=6380 \
REDIS_PORT_8_10_0=6379 \
bash install/install-redis.sh
```

Redis uses exact upstream source releases. Each version gets its own runtime and persistence directory. Optional `REDIS_SHA256_<VERSION_KEY>` variables can pin a source tarball digest.

### Elastic Stack

```bash
ELASTIC_VERSIONS="9.4.2 9.5.0" \
ELASTIC_COMPONENTS="elasticsearch kibana logstash" \
ELASTIC_AUTO_START_VERSIONS="" \
bash install/install-elastic.sh
```

Each version is isolated. Elasticsearch/Kibana/Logstash for one instance intentionally share the same version. Tar archives are verified using the SHA-512 sidecar published with the artifact. Elastic defaults to no auto-start.

### Qdrant

```bash
QDRANT_VERSIONS="1.18.3" \
QDRANT_PORT_1_18_3=6333 \
QDRANT_GRPC_PORT_1_18_3=6334 \
QDRANT_ENABLE_GRPC=0 \
QDRANT_AUTO_START_VERSIONS="1.18.3" \
bash install/install-qdrant.sh
```

The adapter pins QNP `1.0.0` (from the author's [`dangkhoa2016/Qdrant-Native-Portable`](https://github.com/dangkhoa2016/Qdrant-Native-Portable) repository) at commit `464cb5dbc1117a8a8a6472d76a10c5e329021156`, uses native single-node mode, binds Qdrant to `127.0.0.1`, and disables QNP public access. Each exact Qdrant version gets a separate `.system/qdrant/instances/<version>/` tree. Qdrant **1.18.3** is the validated baseline: real Kaggle acceptance already passed for this target, and any source-changing rewrite must rebuild the public ZIP and re-run the extracted-artifact gate before the `v1.0.0` tag is published.

See the root README and `notebooks/kaggle-dev-bootstrap.ipynb` for the preferred public workflow.
