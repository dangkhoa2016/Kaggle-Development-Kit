# Validation

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](VALIDATION.vi.md)

Recorded baseline: **2026-08-22**

This document records a reproducible validation baseline for the public repository. Untested future versions are not implied to be supported.

## Validated Qdrant baseline

```text
QNP release: 1.0.0
QNP commit: 21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca
Qdrant: 1.18.3
REST acceptance endpoint: 127.0.0.1:16333
bind scope: loopback-only
gRPC: disabled
public mode: none
```

A native Kaggle acceptance run recorded:

```text
fresh_install=PASS
readyz=PASS
vector_upsert_read_search=PASS
restart_persistence=PASS
idempotent_second_install=PASS
doctor=PASS
secrets_in_summary=NO
PASS: real Qdrant 1.18.3 native acceptance
```

The acceptance run verified that the pinned QNP source was used, Qdrant `1.18.3` executed natively, vector data survived restart and a second installer run, the listener stayed on loopback, no public tunnel was created, and sanitized output did not expose generated API keys.

## Permission and cold-restore coverage

The Qdrant acceptance fixture uses QNP `PROCESS_MODE=service-user`. Its disposable root is traversable by the service identity without granting directory listing or write access, while `qdrant.env` remains root-owned and mode `0600`.

Relevant checks:

```text
tests/test-qdrant-acceptance-permissions.sh
tests/test-qdrant-cold-restore.sh
tests/test-bootstrap-privilege.sh
tests/test-redis-cold-restore.sh
tests/test-mise-cold-restore.sh
tests/test-doctor-mise-toolchain.sh
```

On Kaggle, persisted `/kaggle/working` state can outlive the underlying VM accounts. `install/install-all.sh bootstrap` recreates the recorded Qdrant service user when needed and restores ownership for persisted writable paths. `config/qdrant.yaml` remains `root:<user>` with mode `0640`. PostgreSQL cold-restore coverage also proves that `install/install-all.sh install` recreates required empty cluster directories before the PostgreSQL component installer is invoked, preventing a restored cluster from failing first startup because paths such as `pg_notify` disappeared. Redis deterministic cold-restore coverage exercises the real standalone `install-redis.sh` instance-configuration path and verifies that stale nested ownership under `data/`, `logs/`, and `run/` is repaired before validation while `redis.conf`, `redis-user.conf`, and `port` remain root-owned and no world-writable state is introduced. mise cold-restore coverage models persisted managed binaries that became mode `0644`: executable state under tool `bin/`/`sbin/` paths is repaired first, structurally incomplete or mismatched exact pins are force-reinstalled individually, and both installer verification and doctor checks disable auto-install while requiring managed-path provenance plus exact Node/Ruby/npm/Yarn versions.

## Deterministic and integration checks

The repository includes:

```text
tests/test-load-config.sh
tests/test-qdrant-config.sh
tests/test-qdrant-installer.sh
tests/test-qdrant-cli.sh
tests/integration-qdrant-adapter.sh
tests/test-qdrant-acceptance-permissions.sh
tests/test-qdrant-cold-restore.sh
tests/test-bootstrap-privilege.sh
tests/test-redis-cold-restore.sh
tests/test-mise-cold-restore.sh
tests/test-system-dir.sh
tests/test-install-all-dispatch.sh
tests/test-setup-auto-system-dir.sh
tests/test-doctor-qnp-pin.sh
tests/test-doctor-mise-toolchain.sh
tests/test-release-hygiene.sh
```

`tests/integration-qdrant-adapter.sh` uses a local QNP-compatible process fixture for deterministic lifecycle, idempotency, and persistence coverage. `tests/acceptance-qdrant.sh` exercises native Qdrant.

## Release-hygiene checks

Public release tooling excludes runtime and sensitive paths such as:

- `.git/`
- `.system/`
- `.kaggle-ssh/`
- `.kaggle-dev.env`
- `.env*`
- logs, PIDs, sockets, private-key patterns
- `secrets.env`
- `runtime.env`
- `.qdrant-base`
- existing ZIP files

The deterministic release-hygiene test is:

```bash
bash tests/test-release-hygiene.sh
```

## Reproducing repository validation

From a clean checkout:

```bash
sha256sum -c MANIFEST.sha256
(cd install && sha256sum -c MANIFEST.sha256)

find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n

bash tests/test-load-config.sh
bash tests/test-qdrant-config.sh
bash tests/test-qdrant-installer.sh
bash tests/test-qdrant-cli.sh
bash tests/integration-qdrant-adapter.sh
bash tests/test-qdrant-acceptance-permissions.sh
bash tests/test-qdrant-cold-restore.sh
bash tests/test-bootstrap-privilege.sh
bash tests/test-redis-cold-restore.sh
bash tests/test-system-dir.sh
bash tests/test-install-all-dispatch.sh
bash tests/test-setup-auto-system-dir.sh
bash tests/test-doctor-qnp-pin.sh
bash tests/test-release-hygiene.sh

(cd install/sqlite3 && sha256sum -c SHA256SUMS)
(cd install/sqlite3-original-build && sha256sum -c SHA256SUMS)

python3 -m json.tool notebooks/kaggle-dev-bootstrap.ipynb > /dev/null
```

To validate the public source archive as well:

```bash
OUT_DIR="$PWD/release"
bash scripts/build-release-zips.sh "$OUT_DIR"
(cd "$OUT_DIR" && sha256sum -c kaggle-development-kit-v1.0.0.zip.sha256)
```

Extract the ZIP into a clean directory and repeat the checksum, shell-syntax, deterministic test, SQLite checksum, and notebook JSON checks there.

## Validated behavior summary

- Notebook Cell 2 supports exact multi-version Qdrant configuration, default version selection, REST/gRPC ports, auto-start policy, resource profile, QNP release, and a full 40-character QNP source pin.
- Qdrant instances are isolated under `.system/qdrant/instances/<version>/`.
- The adapter uses native single-node mode, `127.0.0.1`, `PUBLIC_MODE=none`, and `START_TUNNEL=0`.
- `bin/kdev qdrant [VERSION] start|stop|restart|status|health|url|logs|version` routing is covered.
- PostgreSQL supports multiple requested majors with isolated data/log/run/service helpers and pgvector integration; persisted clusters are preflight-repaired for missing canonical empty directories before installer startup.
- Redis supports multiple exact `X.Y.Z` releases with isolated runtimes and instances; persisted writable `data/logs/run` ownership is repaired recursively before validation startup without transferring managed instance metadata away from root.
- Elastic supports multiple exact `X.Y.Z` releases with isolated runtime/config/data/log/run trees.
- mise-managed Node/Ruby/npm/Yarn cold restore repairs scoped executable state, explicitly reinstalls only unhealthy exact pins, and fails validation on system-PATH fallback or configured-version mismatch.
- Bundled stripped and original SQLite tool sets include recorded checksums.

The recorded baseline applies to the versions listed above. Other selectable versions should be validated independently before they are treated as supported.
