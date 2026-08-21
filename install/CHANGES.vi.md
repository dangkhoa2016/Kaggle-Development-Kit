# Các thay đổi chính

> 🌐 Language / Ngôn ngữ: [English](CHANGES.md) | **Tiếng Việt**

## 2026-08-22 — Tích hợp Qdrant Native Portable

- Thêm `install/install-qdrant.sh` làm adapter mỏng trên Qdrant Native Portable (QNP) 1.0.0, pin tại commit `464cb5dbc1117a8a8a6472d76a10c5e329021156`.
- Thêm cấu hình Qdrant exact multi-version, state cô lập trong `.system/qdrant/instances/<version>/`, validate REST/gRPC port và endpoint chỉ bind loopback.
- Thêm `bin/kdev qdrant ...`, hiển thị Qdrant/QNP trong `bin/kdev versions`, và kiểm tra Qdrant trong `scripts/doctor.sh`.
- Thêm Qdrant vào Cell 2 của notebook và cơ chế tự cấp/phát hiện trùng port toàn cục.
- Adapter tắt public tunnel/proxy của QNP; Qdrant trong kit này chỉ phục vụ local development.
- Release candidate chỉ target Qdrant 1.18.3. Final Kaggle validation vẫn yêu cầu `tests/acceptance-qdrant.sh` pass; exact version khác vẫn có thể cấu hình nhưng chưa được xem là validated cho tới khi test riêng.

## 2026-08-12 — Kiến trúc GitHub-first multi-version

- Thêm `notebooks/kaggle-dev-bootstrap.ipynb`: Cell 1 clone/update GitHub repo; Cell 2 là nơi duy nhất người dùng cần sửa version/port/tool configuration.
- Thêm `config/defaults.env`, `.kaggle-dev.env.example` và `install/lib/load-config.sh`.
- PostgreSQL hỗ trợ nhiều major version cùng lúc, mỗi major có cluster/helper riêng và có default/auto-start set cấu hình được.
- Redis hỗ trợ nhiều exact release `X.Y.Z` song song bằng cách compile official source tarball vào runtime theo version.
- Thêm installer Elastic Stack multi-version cho Elasticsearch/Kibana/Logstash với state tách riêng và mặc định không auto-start Elastic.
- Thêm port theo từng version, kiểm tra collision toàn cục và tự cấp port trong notebook khi thiếu mapping.
- Thêm `bin/kdev` làm unified CLI cho version discovery, install, service control, psql/redis-cli, Elastic component, doctor và SSH.
- Siết public release boundary: runtime state, secrets, SSH identity, log, cache và `.kaggle-dev.env` local đều bị loại trừ.
- Release tooling public chỉ tạo public-source archive; script public không còn tạo private runtime snapshot.


- Thêm abstraction root/sudo dùng chung; root không còn phụ thuộc binary `sudo`.
- Tách runtime PostgreSQL/Redis khỏi data, log và PID.
- Tải package vào `.system/.staging/`, kiểm tra rồi atomic swap runtime.
- Không backup PostgreSQL vào `/tmp`; không tự xóa cluster sai `PG_VERSION`.
- Chỉ tải PostgreSQL version được yêu cầu và các version đã tồn tại cần giữ lại.
- PostgreSQL JIT chuyển thành tùy chọn `POSTGRES_INCLUDE_JIT=1`.
- Runtime không còn thuộc service user; chỉ data/log/run thuộc `postgres` hoặc `redis`.
- Loại bỏ `eval` khi chọn port/version; thêm whitelist version và validate port.
- Port PostgreSQL/Redis được áp dụng đúng khi chạy lại installer.
- Helper xác minh cluster/PID, tránh điều khiển nhầm service khác cùng port.
- Redis mặc định dùng distro repository; repository chính thức là tùy chọn.
- Redis installer chỉ tải runtime khi `.system/redis/runtime` chưa tồn tại; đổi
  `REDIS_REPOSITORY` cần dời runtime cũ trước khi chạy lại (xem `install/README.vi.md`).
- Redis chạy dưới system user, không chạy daemon dưới root.
- mise được pin version; installer chính thức xác minh checksum release.
- `mise use --pin --path` cập nhật tool version mà giữ các section khác của `mise.toml`.
- Không sửa `~/.bashrc` mặc định; chỉ sửa khi `MISE_ADD_BASHRC_HOOK=1`.
- SQLite binaries được strip, giảm mạnh kích thước và có `SHA256SUMS`.
- README được sửa để mô tả đúng giới hạn portability và local trust authentication.

## Bổ sung pgvector và SQLite original build

- PostgreSQL mặc định tải package `postgresql-<version>-pgvector`.
- Tự chạy `CREATE EXTENSION IF NOT EXISTS vector` trong `postgres` và `template1`.
- Thêm helper `.system/enable-pgvector<version>.sh <database>`.
- Có thể tắt bằng `POSTGRES_INSTALL_PGVECTOR=0` hoặc chỉ tắt auto-enable bằng `POSTGRES_AUTO_ENABLE_PGVECTOR=0`.
- Khôi phục bốn SQLite binary gốc chưa strip vào `install/sqlite3-original-build/`.
- Thêm `BUILD-INFO.txt` và `SHA256SUMS` riêng cho bộ SQLite original.

## Chuẩn hóa public GitHub repository

- Thêm `README.md` ở project root để GitHub hiển thị hướng dẫn chính.
- Thêm MIT `LICENSE` cho mã Bash, tài liệu và cấu hình do project tạo ra.
- Thêm `THIRD_PARTY_NOTICES.md` và thư mục `licenses/` để tách giấy phép bên thứ ba.
- Ghi rõ SQLite public domain và phụ thuộc GNU Readline GPLv3-or-later của executable `sqlite3`.
- Thêm `scripts/rebuild-sqlite-tools.sh` để tải source SQLite 3.53.4, xác minh SHA3-256 và tái dựng hai bộ binary.
- Thêm `.gitignore` cho `.system/`, database, log, PID, socket, secret, cache và build workspace.
- Thêm `SECURITY.md` với phạm vi sử dụng và hướng dẫn không public dữ liệu nhạy cảm.
- Thêm root `MANIFEST.sha256` và cập nhật manifest trong `install/`.

## 2026-08-09 — Kaggle Remote Development hardening

- Public `setup.sh` cho OpenSSH + ngrok + VS Code Remote-SSH; không hard-code secret.
- Thêm `setup.sh --full`, `--doctor`, `--save-secrets`, `--status`, `--stop`.
- Thêm portable private state `.kaggle-ssh/private.env` (base64, mode 0600).
- Thêm persistent SSH host identity với `HostKeyAlias` và ED25519 fingerprint.
- Temporary ngrok config chứa token được xóa sau khi tunnel sẵn sàng.
- Thêm `scripts/doctor.sh`, `scripts/refresh-manifest.sh`, `scripts/build-release-zips.sh`.
- Thêm `POSTGRES_FORCE_RUNTIME_REFRESH=1` và `REDIS_FORCE_RUNTIME_REFRESH=1` để
  refresh runtime khi base image thay đổi mà vẫn giữ data.
