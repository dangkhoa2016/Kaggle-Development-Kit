# Main changes

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](CHANGES.vi.md)

## 2026-08-22 — Qdrant Native Portable integration

- Added `install/install-qdrant.sh` as a thin adapter over Qdrant Native Portable (QNP) 1.0.0 pinned to commit `21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca`.
- Added exact multi-version Qdrant configuration, isolated `.system/qdrant/instances/<version>/` state, REST/gRPC port validation, and loopback-only endpoints.
- Added `bin/kdev qdrant ...`, Qdrant/QNP reporting in `bin/kdev versions`, and Qdrant-aware `scripts/doctor.sh` checks.
- Added Qdrant to notebook Cell 2 and global automatic port allocation/collision detection.
- QNP public tunnel/proxy mode is disabled by the adapter; Qdrant is local-development-only in this kit.
- Real native Kaggle acceptance passed for Qdrant `1.18.3`: fresh install, `/readyz`, vector upsert/read/search, restart persistence, idempotent second install, doctor, loopback-only binding, no public tunnel, and secret-safe summary checks.
- Added a regression for acceptance-root traversal in `service-user` mode while keeping `qdrant.env` private.
- Bootstrap is cold-restore safe: after a Kaggle VM reset it recreates the Qdrant service user from `.system/qdrant/service-user` metadata and repairs persisted instance/config ownership while preserving the restrictive `0640` config mode.
- Added `tests/test-qdrant-cold-restore.sh` for that boundary, plus GitHub Actions checks for manifests, shell syntax, deterministic tests, SQLite checksums, and notebook JSON.
- Hardened the release-hygiene fixture so live `.system/` runtime sockets are not traversed during source-copy setup.
- The v1.0.0 public source artifact is named `kaggle-development-kit-v1.0.0.zip`.
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
- Public release tooling creates only a public-source archive; private runtime snapshots are intentionally not produced by the public release script.
- Added a shared root/sudo abstraction; root no longer depends on the `sudo` binary.
- Separated PostgreSQL/Redis runtime files from data, logs, and PID state.
- Packages are downloaded into `.system/.staging/`, verified, then runtime is swapped atomically.
- PostgreSQL is not backed up to `/tmp`, and a cluster with an unexpected `PG_VERSION` is not deleted automatically.
- Only requested PostgreSQL versions and existing versions that must be preserved are downloaded.
- PostgreSQL JIT is optional via `POSTGRES_INCLUDE_JIT=1`.
- Runtime files are not owned by the service user; only data/log/run paths are.
- Removed `eval` from port/version selection and added version/port validation.
- PostgreSQL/Redis ports are applied correctly when installers are re-run.
- Cold-restored PostgreSQL clusters are preflight-repaired before the PostgreSQL installer runs, so missing empty paths such as `pg_notify` cannot abort first startup before restore repair executes.
- Helpers verify cluster/PID identity to avoid controlling another service on the same port.
- Redis uses exact pinned upstream releases and isolated per-version runtime/instance trees.
- Redis runs under a system user rather than root.
- Redis cold restore recursively repairs persisted `data/`, `logs/`, and `run/` ownership in the standalone installer before validation startup while keeping managed instance metadata root-owned.
- Added `tests/test-redis-cold-restore.sh` and CI coverage for stale nested Redis writable-state ownership.
- mise is pinned by version; `MISE_INSTALLER_SHA256` can verify the downloaded installer when configured.
- `mise use --pin --path` updates tool versions while preserving other `mise.toml` sections.
- mise cold restore repairs lost executable bits under persisted tool `bin/`/`sbin/` paths, force-reinstalls only an exact pin that remains unhealthy, and verifies managed-path provenance plus exact versions with auto-install disabled.
- `scripts/doctor.sh` now fails closed when managed Node/Ruby/npm/Yarn are unavailable, resolve outside project mise state, or differ from configured pins.
- `~/.bashrc` is not modified by default; enable that behavior with `MISE_ADD_BASHRC_HOOK=1`.
- SQLite binaries are stripped to reduce size and include `SHA256SUMS`.
- Documentation describes portability limits and local trust authentication.

## pgvector and SQLite original build additions

- PostgreSQL downloads the `postgresql-<version>-pgvector` package by default.
- Runs `CREATE EXTENSION IF NOT EXISTS vector` in `postgres` and `template1`.
- Added the `.system/enable-pgvector<version>.sh <database>` helper.
- Can be disabled with `POSTGRES_INSTALL_PGVECTOR=0`, or auto-enable alone with `POSTGRES_AUTO_ENABLE_PGVECTOR=0`.
- Restored the four original non-stripped SQLite binaries into `install/sqlite3-original-build/`.
- Added separate `BUILD-INFO.txt` and `SHA256SUMS` for the SQLite original set.

## Public GitHub repository standardization

- Added the project-root README.
- Added the MIT `LICENSE` for project-authored Bash code, documentation, and configuration.
- Added `THIRD_PARTY_NOTICES.md` and the `licenses/` directory to separate third-party licenses.
- Documented SQLite public-domain status and the GNU Readline GPLv3-or-later dependency of the bundled `sqlite3` executable.
- Added `scripts/rebuild-sqlite-tools.sh` to download SQLite 3.53.4 source, verify SHA3-256, and rebuild both binary sets.
- Added `.gitignore` coverage for runtime state, databases, logs, PIDs, sockets, secrets, caches, and build workspaces.
- Added `SECURITY.md` with the intended security boundary and publication guidance.
- Added root and installer checksum manifests.

## 2026-08-09 — Kaggle Remote Development hardening

- Added a public-safe `setup.sh` for OpenSSH + ngrok + VS Code Remote-SSH with no hard-coded secrets.
- Added `setup.sh --full`, `--doctor`, `--save-secrets`, `--status`, and `--stop`.
- Added portable private state via `.kaggle-ssh/private.env` (base64, mode 0600).
- Added persistent SSH identity support with `HostKeyAlias` and ED25519 fingerprint output.
- Temporary ngrok token config is removed after the tunnel becomes ready.
- Added `scripts/doctor.sh`, `scripts/refresh-manifest.sh`, and `scripts/build-release-zips.sh`.
- Added `POSTGRES_FORCE_RUNTIME_REFRESH=1` and `REDIS_FORCE_RUNTIME_REFRESH=1` to refresh runtimes after base-image changes while preserving data.
