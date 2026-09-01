# Contributing to Kaggle Development Kit

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](CONTRIBUTING.vi.md)

Thank you for considering a contribution to Kaggle Development Kit. The project is intentionally conservative about persistence, local-only service exposure, restore behavior, and release integrity. Changes should preserve those guarantees unless the pull request explicitly proposes and documents a policy change.

## Before opening a change

1. Search existing issues and pull requests for related work.
2. Keep each change focused on one coherent problem or feature.
3. Do not include runtime state, database data, logs, credentials, tunnel endpoints, private keys, generated PID/socket files, or `.kaggle-dev.env`.
4. For behavior changes, include regression coverage whenever practical.
5. Update English and Vietnamese documentation together when user-facing behavior changes.

## Development workflow

Create a topic branch from the latest `main`, make the smallest coherent change, and use clear commit messages that describe intent rather than debugging history.

The repository uses SHA-256 manifests for tracked release content. After changing tracked files, refresh the manifests:

```bash
bash scripts/refresh-manifest.sh
sha256sum -c MANIFEST.sha256
(cd install && sha256sum -c MANIFEST.sha256)
```

Run shell syntax checks for tracked shell scripts:

```bash
git ls-files '*.sh' | while IFS= read -r file; do
  bash -n "$file" || exit 1
done
```

Run tests relevant to your change. Before requesting review, the GitHub Actions `CI` workflow should pass; it validates manifests, shell syntax, deterministic regression tests, SQLite checksums, and notebook JSON.

## Project invariants

Unless a change explicitly revises a documented contract, contributions should preserve these defaults:

- database and service endpoints remain loopback-only by default;
- SSH access uses public-key authentication and explicit forwarding;
- persisted state is not silently discarded during cold restore;
- recovery paths fail closed when ownership, metadata, or source identity cannot be validated;
- exact configured runtime pins are validated rather than silently substituted;
- public release artifacts exclude private and runtime state.

See [`../SECURITY.md`](../SECURITY.md), [`../README.md`](../README.md), and [`../install/VALIDATION.md`](../install/VALIDATION.md) for the current public contracts.

## Pull requests

A good pull request should explain:

- what problem is being solved;
- why the chosen approach is appropriate;
- which tests or validation were run;
- whether restore, security, compatibility, or release behavior changes;
- whether documentation and manifests were updated.

Keep unrelated refactors out of the same pull request unless they are required for the change.

## Security issues

Do not report suspected vulnerabilities, exposed credentials, or sensitive runtime artifacts in a public issue. Follow the private reporting guidance in [`../SECURITY.md`](../SECURITY.md).
