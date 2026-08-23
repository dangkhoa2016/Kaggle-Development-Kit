# Các thay đổi chính

> 🌐 Language / Ngôn ngữ: [English](CHANGES.md) | **Tiếng Việt**

## 2026-08-22 — Tích hợp Qdrant Native Portable

- Thêm `install/install-qdrant.sh` làm adapter mỏng trên Qdrant Native Portable (QNP) 1.0.0, pin tại commit `066084be23d23a5be11ca8e5df28d5da9eef1cc4`.
- Thêm cấu hình Qdrant exact multi-version, state cô lập trong `.system/qdrant/instances/<version>/`, validate REST/gRPC port và endpoint chỉ bind loopback.
- Thêm `bin/kdev qdrant ...`, hiển thị Qdrant/QNP trong `bin/kdev versions`, và kiểm tra Qdrant trong `scripts/doctor.sh`.
- Thêm Qdrant vào Cell 2 của notebook và cơ chế tự cấp/phát hiện trùng port toàn cục.
- Adapter tắt public tunnel/proxy của QNP; Qdrant trong kit này chỉ phục vụ local development.
- Real native Kaggle acceptance đã pass cho Qdrant `1.18.3`: fresh install, `/readyz`, vector upsert/read/search, persistence sau restart, idempotent second install, doctor, loopback-only binding, không public tunnel và secret-safe summary checks.
- Thêm regression cho acceptance-root traversal ở `service-user` mode trong khi vẫn giữ `qdrant.env` private.
- Bootstrap an toàn với cold restore: sau khi Kaggle reset VM, nó tái tạo Qdrant service user từ metadata `.system/qdrant/service-user` và sửa lại ownership instance/config đã lưu trong khi vẫn giữ mode chặt `0640` của config.
- Thêm `tests/test-qdrant-cold-restore.sh` cho boundary đó, cùng GitHub Actions checks cho manifest, shell syntax, deterministic tests, SQLite checksum và notebook JSON.
- Harden release-hygiene fixture để không traverse live `.system/` runtime socket khi chuẩn bị source copy.
- Public source artifact v1.0.0 có tên `kaggle-development-kit-v1.0.0.zip`.
- Qdrant `1.18.3` là target đã được xác minh cho v1.0.0. Exact version khác vẫn có thể cấu hình nhưng cần validation riêng.

## 2026-08-12 — Kiến trúc GitHub-first multi-version

- Thêm `notebooks/kaggle-dev-bootstrap.ipynb`: Cell 1 clone/update GitHub repo; Cell 2 là nơi duy nhất người dùng cần sửa version/port/tool configuration.
- Thêm `config/defaults.env`, `.kaggle-dev.env.example` và `install/lib/load-config.sh`.
- PostgreSQL hỗ trợ nhiều major version cùng lúc, mỗi major có cluster/helper riêng và có default/auto-start set cấu hình được.
- Redis hỗ trợ nhiều exact release `X.Y.Z` song song bằng cách compile official source tarball vào runtime theo version.
- Thêm installer Elastic Stack multi-version cho Elasticsearch/Kibana/Logstash với state tách riêng và mặc định không auto-start Elastic.
- Thêm port theo từng version, kiểm tra collision toàn cục và tự cấp port trong notebook khi thiếu mapping.
- Thêm `bin/kdev` làm unified CLI cho version discovery, install, service control, psql/redis-cli, Elastic component, doctor và SSH.
- Siết public release boundary: runtime state, secrets, SSH identity, log, cache và `.kaggle-dev.env` local đều bị loại trừ.
- Release tooling public chỉ tạo public-source archive; script public không tạo private runtime snapshot.
- Thêm abstraction root/sudo dùng chung; root không còn phụ thuộc binary `sudo`.
- Tách runtime PostgreSQL/Redis khỏi data, log và PID.
- Tải package vào `.system/.staging/`, kiểm tra rồi atomic swap runtime.
- Không backup PostgreSQL vào `/tmp` và không tự xóa cluster có `PG_VERSION` không đúng mong đợi.
- Chỉ tải PostgreSQL version được yêu cầu và các version đã tồn tại cần giữ lại.
- PostgreSQL JIT là tùy chọn qua `POSTGRES_INCLUDE_JIT=1`.
- Runtime không thuộc service user; chỉ data/log/run thuộc service user.
- Loại bỏ `eval` khi chọn port/version; thêm validation cho version và port.
- Port PostgreSQL/Redis được áp dụng đúng khi chạy lại installer.
- Cluster PostgreSQL sau cold restore được preflight-repair trước khi PostgreSQL installer chạy, nên các path rỗng bị mất như `pg_notify` không thể làm lần start đầu tiên fail trước khi restore repair được thực thi.
- Helper xác minh cluster/PID để tránh điều khiển nhầm service khác cùng port.
- Redis dùng exact upstream release đã pin, với runtime/instance cô lập theo version.
- Redis chạy dưới system user thay vì root.
- Cold restore của Redis sửa đệ quy ownership `data/`, `logs/` và `run/` đã lưu ngay trong standalone installer trước validation startup, đồng thời giữ metadata instance được quản lý thuộc root.
- Thêm `tests/test-redis-cold-restore.sh` và CI coverage cho ownership stale nằm sâu trong Redis writable state.
- mise được pin version; `MISE_INSTALLER_SHA256` có thể dùng để xác minh installer tải về.
- `mise use --pin --path` cập nhật tool version mà giữ các section khác của `mise.toml`.
- Cold restore của mise sửa execute bit bị mất dưới `bin/`/`sbin/` của tool đã lưu, chỉ force-reinstall exact pin còn unhealthy, và verify managed-path provenance cùng exact version khi auto-install bị tắt.
- `scripts/doctor.sh` giờ fail-closed nếu Node/Ruby/npm/Yarn managed không chạy, resolve ra ngoài project mise state hoặc khác pin đã cấu hình.
- Không sửa `~/.bashrc` mặc định; chỉ bật hành vi đó bằng `MISE_ADD_BASHRC_HOOK=1`.
- SQLite binaries được strip để giảm kích thước và có `SHA256SUMS`.
- Tài liệu mô tả giới hạn portability và local trust authentication.

## Bổ sung pgvector và SQLite original build

- PostgreSQL mặc định tải package `postgresql-<version>-pgvector`.
- Chạy `CREATE EXTENSION IF NOT EXISTS vector` trong `postgres` và `template1`.
- Thêm helper `.system/enable-pgvector<version>.sh <database>`.
- Có thể tắt bằng `POSTGRES_INSTALL_PGVECTOR=0`, hoặc chỉ tắt auto-enable bằng `POSTGRES_AUTO_ENABLE_PGVECTOR=0`.
- Khôi phục bốn SQLite binary gốc chưa strip vào `install/sqlite3-original-build/`.
- Thêm `BUILD-INFO.txt` và `SHA256SUMS` riêng cho bộ SQLite original.

## Chuẩn hóa public GitHub repository

- Thêm README ở project root.
- Thêm MIT `LICENSE` cho Bash code, tài liệu và cấu hình do project tạo.
- Thêm `THIRD_PARTY_NOTICES.md` và thư mục `licenses/` để tách giấy phép bên thứ ba.
- Ghi rõ SQLite public domain và phụ thuộc GNU Readline GPLv3-or-later của executable `sqlite3` được bundle.
- Thêm `scripts/rebuild-sqlite-tools.sh` để tải source SQLite 3.53.4, xác minh SHA3-256 và tái dựng hai bộ binary.
- Thêm `.gitignore` cho runtime state, database, log, PID, socket, secret, cache và build workspace.
- Thêm `SECURITY.md` với security boundary và hướng dẫn public artifact.
- Thêm checksum manifest ở root và trong installer.

## 2026-08-09 — Kaggle Remote Development hardening

- Thêm public-safe `setup.sh` cho OpenSSH + ngrok + VS Code Remote-SSH, không hard-code secret.
- Thêm `setup.sh --full`, `--doctor`, `--save-secrets`, `--status`, `--stop`.
- Thêm portable private state `.kaggle-ssh/private.env` (base64, mode 0600).
- Thêm persistent SSH host identity với `HostKeyAlias` và ED25519 fingerprint.
- Temporary ngrok config chứa token được xóa sau khi tunnel sẵn sàng.
- Thêm `scripts/doctor.sh`, `scripts/refresh-manifest.sh`, và `scripts/build-release-zips.sh`.
- Thêm `POSTGRES_FORCE_RUNTIME_REFRESH=1` và `REDIS_FORCE_RUNTIME_REFRESH=1` để refresh runtime khi base image thay đổi mà vẫn giữ data.
