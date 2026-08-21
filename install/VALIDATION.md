# Validation report

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](VALIDATION.vi.md)

Validation date: 2026-08-22

## Release-candidate status

This source tree is a **release candidate**, not a final tagged release. The Qdrant integration has passed deterministic configuration, pinning, CLI/doctor, local-process lifecycle, persistence, syntax, notebook, and release-hygiene tests in the build environment. The final release gate is a fresh native Qdrant 1.18.3 run on a Kaggle Notebook with outbound Internet access.

The current build sandbox cannot resolve `github.com`, so `tests/acceptance-qdrant.sh` exits with status `75` and an explicit `BLOCKED` result before downloading anything. This is an environment limitation, not a passing Qdrant acceptance result. Do not mark the Kaggle Qdrant adapter final-release validated until that exact test passes in a fresh Kaggle session.

## Qdrant integration validated in this build

- Notebook Cell 2 accepts exact multi-version Qdrant configuration, a default version, REST/gRPC ports, auto-start policy, resource profile, QNP release, and a full 40-character QNP source commit.
- The default target is Qdrant `1.18.3`, REST `6333`, gRPC `6334`, with gRPC disabled and Qdrant auto-start enabled.
- Automatic port allocation was exercised with Qdrant `1.18.2` + `1.18.3`; generated REST/gRPC ports did not collide with PostgreSQL, Redis, or Elastic ports.
- `install/install-qdrant.sh` pins QNP by exact release + full Git commit, checks QNP `VERSION`, runs QNP source-integrity verification when available, activates source atomically, and reuses a valid immutable cache on later installs.
- Each Qdrant version receives an isolated `.system/qdrant/instances/<version>/` tree and independent REST/gRPC metadata.
- The adapter forces native, single-node, `127.0.0.1` binding, `PUBLIC_MODE=none`, and `START_TUNNEL=0`.
- `bin/kdev qdrant [VERSION] start|stop|restart|status|health|url|logs|version` routing is covered by tests.
- `scripts/doctor.sh` checks the configured QNP pin, installed Qdrant binary, loopback configuration, endpoint metadata, and running/ready state without printing generated API keys.
- A local integration fixture launches a real HTTP process through the generated Qdrant service helper, writes a persistence sentinel, restarts the service, re-runs the installer, and confirms that the sentinel survives both operations.
- QNP pin/release mismatch, invalid exact versions, duplicate ports, and invalid configuration fail closed.

## Qdrant test commands passed here

```text
tests/test-load-config.sh              PASS
tests/test-qdrant-config.sh            PASS
tests/test-qdrant-installer.sh         PASS
tests/test-qdrant-cli.sh               PASS
tests/integration-qdrant-adapter.sh    PASS
```

`tests/integration-qdrant-adapter.sh` intentionally uses a local QNP-compatible fixture so it can validate the new adapter, process lifecycle, loopback endpoint, idempotent re-install, and persistence without claiming that the fixture is Qdrant itself.

## Existing real QNP/Qdrant evidence

The Qdrant Native Portable project used as the integration authority has previously run real Qdrant `1.18.3` successfully in external validation, including authenticated collection/vector operations and persistence/recreation tests. That prior evidence supports the selected QNP/Qdrant baseline, but it does **not** replace the new adapter's fresh Kaggle acceptance gate.

## Final Kaggle release gate

Run from the repository root in a fresh Kaggle Notebook with Internet enabled:

```bash
bash tests/acceptance-qdrant.sh
```

A successful run must end with:

```text
fresh_install=PASS
readyz=PASS
vector_upsert_read_search=PASS
restart_persistence=PASS
idempotent_second_install=PASS
doctor=PASS
PASS: real Qdrant 1.18.3 native acceptance
```

The test also verifies loopback-only binding, no QNP public tunnel artifact, and that generated API keys are not printed into the sanitized acceptance summary or doctor output.

## Other GitHub-first multi-version checks

- Public shell scripts pass `bash -n`, including generated service-controller templates.
- The notebook is valid nbformat/JSON and keeps Cell 1 as GitHub fetch/update and Cell 2 as user configuration.
- Cell 2 has been exercised with default and multi-version service configurations, including global port-collision detection.
- PostgreSQL supports multiple requested majors with separate data/log/run/service helpers.
- Redis supports multiple exact `X.Y.Z` releases with isolated runtime/instance directories.
- Elastic supports multiple exact `X.Y.Z` releases with isolated runtime/config/data/log/run directories.
- The public release builder excludes `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, environment-secret files, private-key patterns, logs, caches, and generated ZIPs.
- Bundled SQLite tool sets are checked against their recorded checksums.

## Clean release-candidate archive verification

An RC archive was built and then validated from a fresh extraction, not from the working tree:

- root `MANIFEST.sha256`: 59 entries verified;
- installer `MANIFEST.sha256`: 26 entries verified;
- 20 extracted shell files passed `bash -n`;
- the extracted notebook passed `nbformat.validate`;
- all deterministic Qdrant tests plus the local-process adapter integration test passed from the extracted archive;
- ZIP entry scanning found no `.git/`, `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, log/PID/socket files, private-key file patterns, `secrets.env`, `runtime.env`, or `.qdrant-base`.

This archive verification does not change the blocked status of the real native Kaggle acceptance gate.

## Recommended full pre-release smoke test

After the Qdrant acceptance gate passes, run:

```bash
bash scripts/doctor.sh
bin/kdev versions

bin/kdev postgres 18 start
bin/kdev postgres 18 psql -c 'SELECT version();'
bin/kdev redis 8.10.0 start
bin/kdev redis 8.10.0 cli PING
bin/kdev elastic 9.5.0 start elasticsearch
bin/kdev qdrant 1.18.3 health
curl -fsS http://127.0.0.1:6333/readyz
```

Then stop services that are not needed and confirm that no private/runtime state is staged for Git.
