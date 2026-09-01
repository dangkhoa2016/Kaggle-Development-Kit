# Kaggle Development Kit

[![CI](https://github.com/dangkhoa2016/Kaggle-Development-Kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/dangkhoa2016/Kaggle-Development-Kit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/dangkhoa2016/Kaggle-Development-Kit?display_name=tag&sort=semver)](https://github.com/dangkhoa2016/Kaggle-Development-Kit/releases/latest)
[![License: MIT](https://img.shields.io/github/license/dangkhoa2016/Kaggle-Development-Kit)](LICENSE)

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](README.vi.md)

A GitHub-first bootstrap project for turning a Kaggle Notebook session into a reusable Linux development environment. It can install and manage **SQLite, multiple PostgreSQL + pgvector versions, multiple exact Redis versions, multiple Elastic Stack versions, Qdrant, mise/Node/Ruby/npm/Yarn, OpenSSH, ngrok, and tmux** without Docker.

The recommended entry point is [`notebooks/kaggle-dev-bootstrap.ipynb`](notebooks/kaggle-dev-bootstrap.ipynb): Cell 1 fetches the repository from GitHub; Cell 2 is the user-editable version/port configuration.

## Validated baseline

The documented v1.0.0 baseline uses native Qdrant `1.18.3` through [Qdrant Native Portable (QNP)](https://github.com/dangkhoa2016/Qdrant-Native-Portable) `1.0.0` (authored by the same developer), pinned to commit `21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca`. This combination has been validated on Kaggle for fresh installation, `/readyz`, vector upsert/read/search, restart persistence, idempotent reinstall, doctor checks, loopback-only binding, no public tunnel, and secret-safe output. See [`install/VALIDATION.md`](install/VALIDATION.md) for the recorded baseline and reproducible checks.

## Public-repository design

The Git repository contains only source, documentation, checksums, and intentionally bundled SQLite tools. Runtime state is created locally under `.system/`; SSH/ngrok state is created under `.kaggle-ssh/`; notebook overrides are written to `.kaggle-dev.env`. All three are excluded from Git.

**Never publish a runtime snapshot** containing database data, logs, PIDs, `private.env`, `authorized_keys`, SSH host private keys, tokens, or tunnel connection state.

## Quick start on Kaggle

1. Create a Kaggle Notebook and enable Internet.
2. Upload/open `notebooks/kaggle-dev-bootstrap.ipynb`.
3. **Cell 1** clones the official repository by default. Set `KAGGLE_DEV_REPOSITORY_URL` only when you want to use a fork or alternate repository.
4. In **Cell 2**, edit versions, ports, installed components, and auto-start lists.
5. Run Cell 3 to install, then Cell 4 to validate.

Cell 1 validates repository health with Git itself rather than treating the presence of `.git/` as proof of a usable checkout. A healthy checkout is fetched and reset to the selected remote ref exactly. After a Kaggle cold restore, if Git metadata is missing or incomplete, Cell 1 reconstructs only the Git metadata in place while preserving `.system/`, `.kaggle-dev.env`, and other untracked persisted state. Invalid metadata is quarantined for forensic inspection after successful recovery; if reconstruction or fetch fails, recovery fails closed and restores the original invalid metadata when applicable.

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
QNP_SOURCE_COMMIT="21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca"
```

Version installation and process startup are separate concerns. You may install multiple versions while starting only one. Elastic defaults to **no auto-start** because running several full stacks at once is expensive in RAM and CPU.

Qdrant is integrated through a thin adapter over a **pinned Qdrant Native Portable (QNP) 1.0.0 source commit** from the same author's repository ([`dangkhoa2016/Qdrant-Native-Portable`](https://github.com/dangkhoa2016/Qdrant-Native-Portable)). QNP remains the authority for Qdrant-native setup, lifecycle, strict-mode defaults, and local storage layout; this repository adds Kaggle configuration, version isolation, port allocation, `kdev`, and release hygiene. Qdrant **1.18.3** is the validated v1.0.0 target. Other exact `X.Y.Z` versions are configurable but should be validated separately before being treated as supported baselines.

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

The database/toolchain installer does not require SSH credentials. To expose a Kaggle session through SSH/ngrok, add these as **Kaggle Secrets**:

- `SSH_PUBLIC_KEY`
- `NGROK_AUTHTOKEN`

Then run:

```bash
bash setup.sh
# or
bin/kdev ssh start
```

`setup.sh` binds sshd to loopback and uses public-key authentication. It writes runtime connection data only under `.kaggle-ssh/`.

### Connect from a local machine or cloud IDE

Run [`connect-kaggle.sh`](connect-kaggle.sh) on the **local development machine** (for example GitHub Codespaces, a local VS Code terminal, or another cloud IDE), not on Kaggle. It maintains one SSH ControlMaster and forwards only configured service ports that are actually listening on Kaggle.

With the standard `Host kaggle` entry generated from the SSH/ngrok connection information:

```bash
./connect-kaggle.sh start
./connect-kaggle.sh status
./connect-kaggle.sh stop
./connect-kaggle.sh restart
```

By default, candidate ports are discovered from the effective Kaggle Development Kit configuration (`config/defaults.env` plus `.kaggle-dev.env`). You can override or extend discovery:

```bash
KAGGLE_FORWARD_PORTS="6379 5433 6333" ./connect-kaggle.sh start
KAGGLE_EXTRA_PORTS="3000 8000 7860" ./connect-kaggle.sh start
KAGGLE_PORT_MAPS="15433:5433 16379:6379" ./connect-kaggle.sh start
```

All managed local forwards bind to `127.0.0.1` only. Re-running `start` is incremental and idempotent: newly-listening Kaggle services are added without duplicating existing forwards. `start` is also non-destructive: each profile keeps a stored record of the session it manages, and if that stored session is alive but the current SSH destination now resolves elsewhere, `start` refuses to retarget it and tells you to run `restart` instead.

`restart` is the explicit replacement operation: it stops the profile's stored managed session, verifies shutdown, then starts the currently resolved desired endpoint. It matches managed sibling ControlMasters by the resolved SSH destination (user, hostname and port), so different SSH aliases that reach the same Kaggle/ngrok endpoint are treated as the same endpoint, while an alias retargeted to another ngrok session is not. Authentication details such as the local identity-file path are not used as endpoint identity. If a managed ControlMaster cannot be stopped cleanly — including a same-endpoint sibling that refuses to terminate — `connect-kaggle.sh` preserves its control socket and state and fails safely instead of discarding management metadata or starting a new session on top of it; restart also waits for a sibling that is merely slow to exit before taking over its local ports. A stale stored record whose control master has died is recovered automatically by `start`/`restart`. Because `stop` targets only the profile's stored control path, it works even after the identity file moves or the SSH configuration can no longer be resolved, and `status` reports the stored versus desired endpoints without mutating any state. Changing the ControlPath policy never makes `start` replace a live master: it keeps using the socket at its recorded location, and `restart` performs the migration to the newly generated path. Unrelated local processes are never terminated; if an unrelated process owns a requested local port, the bind fails safely and you can override it with `KAGGLE_PORT_MAPS` or free that port explicitly.

Generated ControlMaster sockets do not sit directly in a shared temp directory: when `$XDG_RUNTIME_DIR` is set they live under `$XDG_RUNTIME_DIR/kaggle-connect/<profile-hash>.sock`, otherwise under `${TMPDIR:-/tmp}/kaggle-connect-<uid>/<profile-hash>.sock`. The generated `kaggle-connect` directory is created with safe permissions (mode `0700`), an existing symlink at that path is rejected, and a widened mode is tightened back to `0700`. Set `KAGGLE_CONNECT_CONTROL_DIR` to choose a different private base directory, or `KAGGLE_CONNECT_CONTROL_PATH` to place the socket yourself if your environment manages its own socket directory.

## Restore / repeat sessions

The repository is intentionally separate from runtime state. After restoring a previously saved `/kaggle/working` output, run:

```bash
bash install/install-all.sh bootstrap
bin/kdev doctor
```

For a clean Kaggle session, run the notebook again. Cell 1 fetches source; Cell 2 recreates the local config; Cell 3 recreates missing runtimes. If persisted PostgreSQL data survives while empty cluster directories do not, the Cell 3 `install-all.sh install` path repairs those required directories before PostgreSQL is started. Redis cold restore is handled in both `install/install-redis.sh` and the `install-all.sh install` path: persisted `data/`, `logs/`, and `run/` trees are recursively reassigned to the current Redis service user before validation startup, while `redis.conf`, `redis-user.conf`, and `port` remain root-owned. `install-all.sh bootstrap` applies the same Redis writable-state ownership contract. The mise toolchain is also cold-restore aware: the installer repairs executable bits only under persisted tool `bin/`/`sbin/` paths, probes each managed exact pin with mise auto-install disabled, and force-reinstalls only a tool that remains missing, non-executable, or version-mismatched. Validation fails closed unless the managed Node, Ruby, npm, and Yarn versions match the configured pins.

## Integrity and release artifacts

Refresh checksums:

```bash
bash scripts/refresh-manifest.sh
sha256sum -c MANIFEST.sha256
(cd install && sha256sum -c MANIFEST.sha256)
```

Build and verify the v1.0.0 source-only public release artifacts:

```bash
OUT_DIR="$PWD/release"
bash scripts/build-release-zips.sh "$OUT_DIR"
(cd "$OUT_DIR" && sha256sum -c kaggle-development-kit-v1.0.0.zip.sha256)
```

The builder writes both `kaggle-development-kit-v1.0.0.zip` and its `.zip.sha256` sidecar. It deliberately excludes `.git/`, `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, local environment files, logs, PIDs, sockets, private-key patterns, runtime secrets, and existing ZIP files.

## Security boundary

Safe to publish: `setup.sh`, `connect-kaggle.sh`, `install/`, `scripts/`, `bin/`, `config/defaults.env`, `notebooks/`, `mise.toml`, documentation/licenses/checksums, and bundled SQLite binaries with their notices.

Keep private/runtime-only: `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, `.env*`, private keys, tokens, logs, PIDs, databases/dumps, tunnel endpoints, and `private.env`.

This project is optimized for a single-user **development** notebook, not a production multi-user database host. See [`SECURITY.md`](SECURITY.md).

## License

Project code, configuration, and documentation are under the MIT License unless otherwise noted. Third-party components keep their own licenses; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and [`licenses/`](licenses/).
