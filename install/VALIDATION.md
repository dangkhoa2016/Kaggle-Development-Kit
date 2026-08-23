# Validation report

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](VALIDATION.vi.md)

Validation date: 2026-08-22

## v1.0.0 release status

Engineering evidence is already complete: real Kaggle native Qdrant acceptance passed, the QNP/Qdrant baseline is validated, and the permission and release-hygiene regressions pass. Per the source-release rule, every source-changing rewrite must rebuild the public ZIP and pass the extracted-artifact gate before the `v1.0.0` tag/release is published.

## Real Kaggle Qdrant acceptance

Validated target:

```text
QNP release: 1.0.0
QNP commit: 464cb5dbc1117a8a8a6472d76a10c5e329021156
Qdrant: 1.18.3
REST acceptance endpoint: 127.0.0.1:16333
bind scope: loopback-only
gRPC: disabled
public mode: none
```

The real native Kaggle run completed with:

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

Independent evidence from that run confirmed that the pinned QNP source integrity was clean, Qdrant `1.18.3` was downloaded and executed natively, vector data survived process restart and a second installer run, the listener stayed on loopback, no public tunnel was created, doctor reported zero failures/warnings, and the sanitized acceptance evidence did not expose generated API keys.

## Acceptance permission regression

The acceptance fixture keeps QNP `PROCESS_MODE=service-user`. Its disposable root is mode `0711`, allowing the service identity to traverse to service-owned runtime paths without granting directory listing or write access; the root-owned `qdrant.env` remains mode `0600`.

```text
tests/test-qdrant-acceptance-permissions.sh PASS
```

This closes the earlier failure where a `mktemp -d` root at mode `0700` made a valid generated Qdrant configuration inaccessible to `qdrantuser`.

## Deterministic and integration coverage

The deterministic suite is covered by:

```text
tests/test-load-config.sh                   PASS
tests/test-qdrant-config.sh                 PASS
tests/test-qdrant-installer.sh              PASS
tests/test-qdrant-cli.sh                    PASS
tests/integration-qdrant-adapter.sh         PASS
tests/test-qdrant-acceptance-permissions.sh PASS
tests/test-qdrant-cold-restore.sh           PASS
tests/test-bootstrap-privilege.sh           PASS
tests/test-system-dir.sh                    PASS
tests/test-install-all-dispatch.sh          PASS
tests/test-setup-auto-system-dir.sh         PASS
tests/test-doctor-qnp-pin.sh                PASS
tests/test-release-hygiene.sh               PASS
```

`tests/integration-qdrant-adapter.sh` intentionally uses a local QNP-compatible process fixture for deterministic lifecycle/idempotency/persistence coverage. The separate `tests/acceptance-qdrant.sh` run above is the evidence for real native Qdrant itself.

## Qdrant cold-restore regression

Kaggle can preserve `/kaggle/working` while replacing the underlying VM, so persisted `.system/qdrant` can outlive the OS accounts. `install/install-all.sh bootstrap` now recreates the Qdrant service user from `.system/qdrant/service-user` metadata and repairs persisted ownership: writable areas (`storage/`, `snapshots/`, `logs/`, `tmp/`) regain `<user>:<user>`, and `config/qdrant.yaml` regains `root:<user>` with mode `0640`.

```text
tests/test-qdrant-cold-restore.sh PASS
```

The regression simulates a fresh runtime deterministically (stubbed account database, recorded `chown` calls) and verifies that no world-writable directory is introduced. A fresh-runtime Kaggle rerun of `bin/kdev qdrant start|health|status` remains part of the release gate before tagging.

## Release-hygiene validation

The public release boundary excludes `.git/`, `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, local environment files, logs, PIDs, sockets, private-key patterns, `secrets.env`, `runtime.env`, `.qdrant-base`, and existing ZIPs.

The release-hygiene fixture was also hardened so it does not traverse live `.system/` runtime state while preparing its isolated test tree. This prevents active PostgreSQL Unix sockets such as `.s.PGSQL.5433` from producing misleading `tar: socket ignored` warnings. The updated test passed on the live Kaggle checkout while PostgreSQL runtime state existed.

## Other validated project behavior

- Notebook Cell 2 supports exact multi-version Qdrant configuration, default version selection, REST/gRPC ports, auto-start policy, resource profile, QNP release, and full 40-character QNP source pinning.
- Qdrant instances are isolated under `.system/qdrant/instances/<version>/`.
- The adapter forces native, single-node, `127.0.0.1`, `PUBLIC_MODE=none`, and `START_TUNNEL=0`.
- `bin/kdev qdrant [VERSION] start|stop|restart|status|health|url|logs|version` routing is covered.
- PostgreSQL supports multiple requested majors with isolated data/log/run/service helpers and pgvector integration.
- Redis supports multiple exact `X.Y.Z` releases with isolated runtimes/instances.
- Elastic supports multiple exact `X.Y.Z` releases with isolated runtime/config/data/log/run trees.
- Bundled stripped and original SQLite tool sets have recorded checksums.

## Final artifact gate

The default public artifact name for this release is:

```text
kaggle-development-kit-v1.0.0.zip
kaggle-development-kit-v1.0.0.zip.sha256
```

Before tagging `v1.0.0`, build the ZIP, extract it into a clean directory, and require all of the following:

```bash
sha256sum -c MANIFEST.sha256
(cd install && sha256sum -c MANIFEST.sha256)
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash tests/test-qdrant-acceptance-permissions.sh
bash tests/test-load-config.sh
bash tests/test-qdrant-config.sh
bash tests/test-qdrant-installer.sh
bash tests/test-qdrant-cli.sh
bash tests/integration-qdrant-adapter.sh
bash tests/test-qdrant-cold-restore.sh
bash tests/test-bootstrap-privilege.sh
bash tests/test-system-dir.sh
bash tests/test-install-all-dispatch.sh
bash tests/test-setup-auto-system-dir.sh
bash tests/test-doctor-qnp-pin.sh
bash tests/test-release-hygiene.sh
(cd install/sqlite3 && sha256sum -c SHA256SUMS)
(cd install/sqlite3-original-build && sha256sum -c SHA256SUMS)
```

Also validate `notebooks/kaggle-dev-bootstrap.ipynb` with `nbformat.validate`, scan ZIP entries for forbidden runtime/private paths, and verify the generated `.zip.sha256` sidecar. The project should be tagged `v1.0.0` only after this extracted-artifact gate passes.
