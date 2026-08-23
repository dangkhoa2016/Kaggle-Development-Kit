# Main changes

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](CHANGES.vi.md)

## 2026-08-22 — Qdrant Native Portable integration / v1.0.0 finalization

- Added `install/install-qdrant.sh` as a thin adapter over Qdrant Native Portable (QNP) 1.0.0 pinned to commit `464cb5dbc1117a8a8a6472d76a10c5e329021156`.
- Added exact multi-version Qdrant configuration, isolated `.system/qdrant/instances/<version>/` state, REST/gRPC port validation, and loopback-only endpoints.
- Added `bin/kdev qdrant ...`, Qdrant/QNP reporting in `bin/kdev versions`, and Qdrant-aware `scripts/doctor.sh` checks.
- Added Qdrant to notebook Cell 2 and global automatic port allocation/collision detection.
- QNP public tunnel/proxy mode is disabled by the adapter; Qdrant is local-development-only in this kit.
- Real native Kaggle acceptance passed for Qdrant `1.18.3`: fresh install, `/readyz`, vector upsert/read/search, restart persistence, idempotent second install, doctor, loopback-only binding, no public tunnel, and secret-safe summary checks.
- Added a regression for acceptance-root traversal in `service-user` mode while keeping `qdrant.env` private.
- Bootstrap is now cold-restore safe: after a Kaggle VM reset it recreates the Qdrant service user from `.system/qdrant/service-user` metadata and repairs persisted instance/config ownership while preserving the restrictive `0640` config mode.
- Added `tests/test-qdrant-cold-restore.sh` covering that boundary deterministically, plus lightweight GitHub Actions CI for manifest, syntax, deterministic-suite, SQLite-checksum and notebook checks.
- Hardened the release-hygiene fixture so live `.system/` runtime sockets are not traversed during source-copy setup.
- The v1.0.0 public artifact is named `kaggle-development-kit-v1.0.0.zip`; final tagging remains gated on clean extracted-artifact verification.
- Qdrant `1.18.3` is the validated v1.0.0 target. Other exact versions remain configurable but require separate validation.

## 2026-08-12 — GitHub-first multi-version architecture

- Added `notebooks/kaggle-dev-bootstrap.ipynb`: Cell 1 clones/updates the GitHub repo; Cell 2 is the single user-editable version/port/tool configuration cell.
- Added `config/defaults.env`, `.kaggle-dev.env.example`, and `install/lib/load-config.sh`.
- PostgreSQL now accepts multiple requested major versions with one isolated cluster/helper per major and a configurable default/auto-start set.
- Redis now supports multiple exact upstream `X.Y.Z` releases side-by-side by compiling official source tarballs into versioned runtimes.
- Added a multi-version Elastic Stack installer for Elasticsearch/Kibana/Logstash with isolated state and no Elastic auto-start by default.
- Added globally validated per-version service ports and notebook-side automatic allocation for omitted port mappings.
- Added `bin/kdev` as the unified CLI for version discovery, install, service control, psql/redis-cli, Elastic component control, doctor, and SSH.
- Hardened the public release boundary: generated runtime state, secrets, SSH identity, logs, caches, and local `.kaggle-dev.env` are excluded.
- Public release tooling now creates only a public-source archive; private runtime snapshots are intentionally not produced by the public release script.

- Added a shared root/sudo abstraction; root no longer depends on the `sudo` binary.
- Separated the PostgreSQL/Redis runtime from data, log and PID.
- Packages are downloaded into `.system/.staging/`, verified, then runtime is swapped atomically.
- No PostgreSQL backup to `/tmp`; no automatic deletion of a cluster with a wrong `PG_VERSION`.
- Only downloads the requested PostgreSQL versions and the existing versions that must be kept.
- PostgreSQL JIT became optional via `POSTGRES_INCLUDE_JIT=1`.
- The runtime no longer belongs to the service user; only data/log/run belong to `postgres` or `redis`.
- Removed `eval` when selecting port/version; added a version whitelist and port validation.
- PostgreSQL/Redis ports are applied correctly when the installer is re-run.
- Helpers verify the cluster/PID, avoiding control of another service using the same port.
- Redis runs from exact pinned upstream releases: the official source tarball for each configured `X.Y.Z` is downloaded and compiled into `.system/redis/versions/<version>`.
- Each Redis version gets its own instance directory under `.system/redis/instances/<version>`, so multiple pinned releases can coexist side by side.
- Redis runs under a system user; the daemon no longer runs under root.
- mise is pinned by version; the installer can verify the downloaded installer with `MISE_INSTALLER_SHA256` when a checksum pin is configured.
- `mise use --pin --path` updates tool versions while keeping the other sections of `mise.toml`.
- `~/.bashrc` is not modified by default; only with `MISE_ADD_BASHRC_HOOK=1`.
- SQLite binaries are stripped, greatly reducing size, and have `SHA256SUMS`.
- README updated to describe the portability limits and local trust authentication accurately.

## pgvector and SQLite original build additions

- PostgreSQL downloads the `postgresql-<version>-pgvector` package by default.
- Runs `CREATE EXTENSION IF NOT EXISTS vector` in `postgres` and `template1`.
- Added the `.system/enable-pgvector<version>.sh <database>` helper.
- Can be disabled with `POSTGRES_INSTALL_PGVECTOR=0` or only the auto-enable with `POSTGRES_AUTO_ENABLE_PGVECTOR=0`.
- Restored the four original non-stripped SQLite binaries into `install/sqlite3-original-build/`.
- Added separate `BUILD-INFO.txt` and `SHA256SUMS` for the SQLite original set.

## Public GitHub repository standardization

- Added `README.md` at the project root so GitHub displays the main instructions.
- Added the MIT `LICENSE` for the Bash code, documentation and configuration created by the project.
- Added `THIRD_PARTY_NOTICES.md` and the `licenses/` directory to separate third-party licenses.
- Documented the SQLite public domain and the GNU Readline GPLv3-or-later dependency of the `sqlite3` executable.
- Added `scripts/rebuild-sqlite-tools.sh` to download the SQLite 3.53.4 source, verify SHA3-256 and rebuild both binary sets.
- Added `.gitignore` for `.system/`, database, log, PID, socket, secret, cache and build workspace.
- Added `SECURITY.md` with the scope of use and guidance not to publish sensitive data.
- Added the root `MANIFEST.sha256` and updated the manifest in `install/`.

## 2026-08-09 — Kaggle Remote Development hardening

- Added a public-safe `setup.sh` for OpenSSH + ngrok + VS Code Remote-SSH with no hard-coded secrets.
- Added `setup.sh --full`, `--doctor`, `--save-secrets`, `--status`, and `--stop`.
- Added portable private state via `.kaggle-ssh/private.env` (base64, mode 0600).
- Added persistent SSH identity support with `HostKeyAlias` and ED25519 fingerprint output.
- Temporary ngrok token config is removed after the tunnel becomes ready.
- Added `scripts/doctor.sh`, `scripts/refresh-manifest.sh`, and `scripts/build-release-zips.sh`.
- Added `POSTGRES_FORCE_RUNTIME_REFRESH=1` and `REDIS_FORCE_RUNTIME_REFRESH=1` to refresh runtimes after base-image changes while preserving data.
