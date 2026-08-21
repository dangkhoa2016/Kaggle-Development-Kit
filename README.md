# Kaggle Development Environment

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](README.vi.md)

A GitHub-first bootstrap project for turning a Kaggle Notebook session into a reusable Linux development environment. It can install and manage **SQLite, multiple PostgreSQL + pgvector versions, multiple exact Redis versions, multiple Elastic Stack versions, Qdrant, mise/Node/Ruby/npm/Yarn, OpenSSH, ngrok, and tmux** without Docker.

The recommended entry point is [`notebooks/kaggle-dev-bootstrap.ipynb`](notebooks/kaggle-dev-bootstrap.ipynb): Cell 1 fetches the repository from GitHub; Cell 2 is the user-editable version/port configuration.

## Public-repository design

The Git repository contains only source, documentation, checksums, and intentionally bundled SQLite tools. Runtime state is created locally under `.system/`; SSH/ngrok state is created under `.kaggle-ssh/`; notebook overrides are written to `.kaggle-dev.env`. All three are excluded from Git.

**Never publish a runtime snapshot** containing database data, logs, PIDs, `private.env`, `authorized_keys`, SSH host private keys, tokens, or tunnel connection state.

## Quick start on Kaggle

1. Create a Kaggle Notebook and enable Internet.
2. Upload/open `notebooks/kaggle-dev-bootstrap.ipynb`.
3. In **Cell 1**, set your GitHub repository URL (or environment variable `KAGGLE_DEV_REPOSITORY_URL`).
4. In **Cell 2**, edit versions, ports, installed components, and auto-start lists.
5. Run Cell 3 to install, then Cell 4 to validate.

Cell 1 updates an existing checkout with `git fetch` + `git reset --hard FETCH_HEAD`, but intentionally keeps untracked local files such as `.kaggle-dev.env`.

## Configuration model

Repository defaults live in [`config/defaults.env`](config/defaults.env). The notebook writes a local override file `.kaggle-dev.env` (mode `0600`, gitignored). Installers load these values automatically.

Important variables:

```bash
POSTGRES_VERSIONS="16 17 18"
POSTGRES_DEFAULT_VERSION="18"
POSTGRES_PORT_16=5432
POSTGRES_PORT_17=5434
POSTGRES_PORT_18=5433
POSTGRES_AUTO_START_VERSIONS="18"

REDIS_VERSIONS="7.4.10 8.10.0"
REDIS_DEFAULT_VERSION="8.10.0"
REDIS_PORT_7_4_10=6380
REDIS_PORT_8_10_0=6379
REDIS_AUTO_START_VERSIONS="8.10.0"

ELASTIC_VERSIONS="9.4.2 9.5.0"
ELASTIC_DEFAULT_VERSION="9.5.0"
ELASTIC_COMPONENTS="elasticsearch kibana logstash"
ELASTIC_PORT_9_4_2_ELASTICSEARCH=9201
ELASTIC_PORT_9_5_0_ELASTICSEARCH=9200
ELASTIC_AUTO_START_VERSIONS=""

QDRANT_VERSIONS="1.18.3"
QDRANT_DEFAULT_VERSION="1.18.3"
QDRANT_PORT_1_18_3=6333
QDRANT_GRPC_PORT_1_18_3=6334
QDRANT_ENABLE_GRPC=0
QDRANT_AUTO_START_VERSIONS="1.18.3"

# Qdrant Native Portable source authority
QNP_RELEASE="1.0.0"
QNP_SOURCE_COMMIT="464cb5dbc1117a8a8a6472d76a10c5e329021156"
```

Version installation and process startup are separate concerns. You may install multiple versions while starting only one. Elastic defaults to **no auto-start** because running several full stacks at once is expensive in RAM and CPU.

Qdrant is integrated through a thin adapter over a **pinned Qdrant Native Portable (QNP) 1.0.0 source commit**. QNP remains the authority for Qdrant-native setup, lifecycle, strict-mode defaults, and local storage layout; this repository adds Kaggle configuration, version isolation, port allocation, `kdev`, and release hygiene. Qdrant **1.18.3** is the only release-candidate target covered by the real acceptance gate. Other exact `X.Y.Z` versions are configurable but must be tested separately. Final Kaggle validation remains gated by `tests/acceptance-qdrant.sh`.

## Multi-version layout

```text
.system/
├── pg/
│   ├── runtime/usr/lib/postgresql/<major>/...
│   ├── pg_data_<major>/
│   ├── pg_log_<major>/
│   └── pg_run_<major>/
├── redis/
│   ├── versions/<exact-version>/bin/...
│   └── instances/<exact-version>/{data,logs,run,redis.conf}
├── elastic/
│   └── versions/<exact-version>/
│       ├── runtime/{elasticsearch,kibana,logstash}/
│       ├── config/
│       ├── data/
│       ├── logs/
│       └── run/
└── qdrant/
    ├── qnp/<qnp-release>-<commit12>/
    └── instances/<exact-version>/
        ├── qdrant-<exact-version>/qdrant
        ├── config/qdrant.yaml
        ├── storage/
        ├── snapshots/
        ├── logs/
        └── run/
```

PostgreSQL uses official PGDG packages. Redis exact releases are compiled from official source tarballs. Elastic components are downloaded as official tar archives and verified with the published SHA-512 sidecar before extraction. Qdrant is downloaded at runtime by the pinned QNP source from the official `qdrant/qdrant` GitHub release. Qdrant is bound to `127.0.0.1`; public tunnel/proxy mode is deliberately disabled by the development-kit adapter.

## Unified CLI

Use [`bin/kdev`](bin/kdev) instead of memorizing generated helper names:

```bash
bin/kdev versions
bin/kdev doctor

bin/kdev postgres 18 status
bin/kdev postgres 18 psql
bin/kdev postgres 18 enable-pgvector my_database

bin/kdev redis 8.10.0 status
bin/kdev redis 8.10.0 cli PING

bin/kdev elastic 9.5.0 start elasticsearch
bin/kdev elastic 9.5.0 status all
bin/kdev elastic 9.5.0 stop all

bin/kdev qdrant 1.18.3 status
bin/kdev qdrant 1.18.3 health
bin/kdev qdrant 1.18.3 url
bin/kdev qdrant 1.18.3 logs -n 100
```

Install individual groups:

```bash
bin/kdev install postgres
bin/kdev install redis
bin/kdev install elastic
bin/kdev install qdrant
bin/kdev install tools
bin/kdev install all
```

## SSH + VS Code Remote-SSH

The database/toolchain installer does not require SSH credentials. To expose the Kaggle session through SSH/ngrok, add these as **Kaggle Secrets**:

- `SSH_PUBLIC_KEY`
- `NGROK_AUTHTOKEN`

Then run:

```bash
bash setup.sh
# or
bin/kdev ssh start
```

`setup.sh` binds sshd to loopback and uses public-key authentication. It writes runtime connection data only under `.kaggle-ssh/`.

## Restore / repeat sessions

The repository is intentionally separate from runtime state. After restoring a previously saved `/kaggle/working` output, run:

```bash
bash install/install-all.sh bootstrap
bin/kdev doctor
```

If you start from a clean Kaggle session, run the notebook again. Cell 1 fetches source; Cell 2 recreates the local config; Cell 3 recreates missing runtimes.

## Integrity and release

Refresh checksums:

```bash
bash scripts/refresh-manifest.sh
sha256sum -c MANIFEST.sha256
(cd install && sha256sum -c MANIFEST.sha256)
```

Build a source-only public release ZIP:

```bash
bash scripts/build-release-zips.sh
```

The release script deliberately excludes `.git/`, `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, and existing ZIP files.

## Security boundary

Safe to publish: `setup.sh`, `install/`, `scripts/`, `bin/`, `config/defaults.env`, `notebooks/`, `mise.toml`, documentation/licenses/checksums, and bundled SQLite binaries with their notices.

Keep private/runtime-only: `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, `.env*`, private keys, tokens, logs, PIDs, databases/dumps, tunnel endpoints, and `private.env`.

This project is optimized for a single-user **development** notebook, not a production multi-user database host. See [`SECURITY.md`](SECURITY.md).

## Architecture review

See [`docs/SOURCE-REVIEW.vi.md`](docs/SOURCE-REVIEW.vi.md) for the source/runtime separation review, multi-version design rationale, and public-release checklist.

## License

Project code/configuration/documentation are under the MIT License unless otherwise noted. Third-party components keep their own licenses; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and [`licenses/`](licenses/).
