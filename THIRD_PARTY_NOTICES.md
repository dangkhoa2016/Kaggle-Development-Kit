# Third-Party Notices

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](THIRD_PARTY_NOTICES.vi.md)

This document describes third-party components bundled by this repository or downloaded by its installers. It does not replace upstream license texts and is not legal advice.

## Scope of this repository's MIT license

The root `LICENSE` applies to the Bash/Python code, notebook, documentation, and configuration authored for this repository. It does **not** re-license third-party software.

## SQLite 3.53.4

The repository bundles two Linux x86-64 tool sets:

- `install/sqlite3/`: stripped build
- `install/sqlite3-original-build/`: non-stripped build

The executables are `sqlite3`, `sqldiff`, `sqlite3_analyzer`, and `sqlite3_rsync`. SQLite core is published by the SQLite Project as public domain software.

Pinned source metadata:

- Version: SQLite 3.53.4
- Source archive: `sqlite-src-3530400.zip`
- Source page: `https://sqlite.org/download.html`
- Source URL: `https://www.sqlite.org/2026/sqlite-src-3530400.zip`
- SHA3-256: `b834d474b9b393d85a9e3ee4cc11f1329e007e9376a424ee740796f5c4bda3a8`
- Rebuild helper: `scripts/rebuild-sqlite-tools.sh`

See `licenses/SQLite-PUBLIC-DOMAIN.txt`.

### GNU Readline

The bundled `sqlite3` executables dynamically link to `libreadline.so.8`. GNU Readline is GPL-3.0-or-later. The repository includes `licenses/GPL-3.0-or-later.txt` and records the corresponding SQLite source/rebuild procedure. The Readline shared library itself is not bundled.

### Tcl, zlib, glibc, and system libraries

`sqlite3_analyzer` dynamically links to Tcl 8.6; some binaries use zlib, glibc, libm, and terminal/system libraries. These shared libraries are supplied by the Kaggle/Linux host and retain their own licenses.

## PostgreSQL and pgvector

The installer downloads PostgreSQL and `postgresql-<major>-pgvector` packages at runtime from the PostgreSQL Global Development Group APT repository. They are not bundled in this repository. PostgreSQL and pgvector use the PostgreSQL License; see `licenses/PostgreSQL.txt` and the license files shipped by the actual packages.

## Redis

The repository does not bundle Redis binaries or Redis source. `install/install-redis.sh` downloads the exact requested upstream release tarball from `download.redis.io/releases/` at runtime, optionally verifies a maintainer-provided SHA-256 pin, compiles it in a staging directory, and copies only the runtime tools into `.system/redis/versions/<version>/`.

Redis licensing has changed across releases. Users must check the license shipped with the **exact Redis version** they select and comply with those terms, especially before redistribution or offering Redis as a service.

## Elastic Stack

The repository does not bundle Elasticsearch, Kibana, or Logstash. `install/install-elastic.sh` downloads the requested official Elastic default-distribution archives from `artifacts.elastic.co`, verifies the published SHA-512 sidecar, and installs them into `.system/elastic/versions/<version>/` at runtime.

Elastic's default distributions are published under Elastic License 2.0 (ELv2). Elastic source code has additional licensing choices depending on the file/version. Check the upstream license for the exact component/version and intended use. This repository does not redistribute those archives.

## Qdrant and Qdrant Native Portable

The repository does not bundle Qdrant binaries or a QNP source checkout. `install/install-qdrant.sh` fetches QNP `1.0.0` (from the author's open-source repository [`dangkhoa2016/Qdrant-Native-Portable`](https://github.com/dangkhoa2016/Qdrant-Native-Portable)) at the exact Git commit `464cb5dbc1117a8a8a6472d76a10c5e329021156` at runtime. That QNP release is MIT-licensed. The pinned QNP source then downloads the selected official Qdrant release binary into the gitignored `.system/` runtime tree.

Qdrant **v1.18.3** is the Qdrant release validated for the v1.0.0 baseline. It is licensed under the Apache License 2.0 in upstream `qdrant/qdrant`. Other selectable Qdrant versions retain the license shipped by their exact upstream release and should be reviewed independently. Neither QNP nor Qdrant is redistributed in this repository's public source ZIP.

## mise, Node.js, npm, Yarn, and Ruby

The installer downloads mise at runtime, and mise then downloads the configured language/tool versions. None of these runtimes are bundled by this repository. Each upstream project keeps its own license.

## No legal warranty

This is a technical inventory, not a substitute for reviewing upstream terms. Any use, modification, deployment, or redistribution must comply with the licenses of the exact third-party versions used and applicable law.
