# Môi trường phát triển trên Kaggle

> 🌐 Language / Ngôn ngữ: [English](README.md) | **Tiếng Việt**

Dự án bootstrap theo hướng **GitHub-first** để biến một phiên Kaggle Notebook thành môi trường Linux phục vụ development. Dự án có thể cài và quản lý **SQLite, nhiều phiên bản PostgreSQL + pgvector, nhiều phiên bản Redis chính xác, nhiều phiên bản Elastic Stack, Qdrant, mise/Node/Ruby/npm/Yarn, OpenSSH, ngrok và tmux** mà không cần Docker.

Điểm vào được khuyến nghị là [`notebooks/kaggle-dev-bootstrap.ipynb`](notebooks/kaggle-dev-bootstrap.ipynb): Cell 1 tự fetch/update mã nguồn từ GitHub; Cell 2 là nơi người dùng chỉnh version/port/cấu hình.

## Thiết kế dành cho GitHub public

Git repository chỉ chứa source, tài liệu, checksum và các SQLite tool được chủ động bundle. Runtime được tạo cục bộ trong `.system/`; trạng thái SSH/ngrok nằm trong `.kaggle-ssh/`; cấu hình riêng do notebook tạo nằm trong `.kaggle-dev.env`. Cả ba đều bị loại khỏi Git.

**Không public runtime snapshot** chứa database data, log, PID, `private.env`, `authorized_keys`, SSH host private key, token hoặc thông tin tunnel.

## Chạy nhanh trên Kaggle

1. Tạo Kaggle Notebook và bật Internet.
2. Upload/mở `notebooks/kaggle-dev-bootstrap.ipynb`.
3. Trong **Cell 1**, sửa GitHub repository URL của bạn (hoặc đặt `KAGGLE_DEV_REPOSITORY_URL`).
4. Trong **Cell 2**, chỉnh version, port, component cần cài và danh sách auto-start.
5. Chạy Cell 3 để cài đặt, Cell 4 để kiểm tra.

Nếu project đã được clone, Cell 1 dùng `git fetch` + `git reset --hard FETCH_HEAD` để source khớp đúng ref trên GitHub, nhưng cố ý giữ các file local chưa track như `.kaggle-dev.env`.

## Mô hình cấu hình

Mặc định của repository nằm tại [`config/defaults.env`](config/defaults.env). Notebook tạo file override `.kaggle-dev.env` (mode `0600`, đã gitignore). Các installer tự động nạp file này.

Ví dụ cài nhiều version:

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

# Source authority của Qdrant Native Portable
QNP_RELEASE="1.0.0"
QNP_SOURCE_COMMIT="464cb5dbc1117a8a8a6472d76a10c5e329021156"
```

**Cài đặt version** và **khởi động process** là hai việc khác nhau. Có thể cài nhiều version nhưng chỉ chạy một version. Elastic mặc định **không auto-start** vì chạy nhiều full stack cùng lúc tốn RAM/CPU trên Kaggle.

Qdrant được tích hợp bằng một adapter mỏng trên **Qdrant Native Portable (QNP) 1.0.0 được pin bằng full Git commit**. QNP tiếp tục là source authority cho setup/lifecycle/strict-mode/storage của Qdrant; repository này bổ sung cấu hình Kaggle, cô lập theo version, tự phân bổ port, `kdev` và release hygiene. Qdrant **1.18.3** là target duy nhất của release candidate được bao phủ bởi real acceptance gate. Có thể cấu hình exact version `X.Y.Z` khác nhưng phải test riêng. Final Kaggle validation vẫn bị chặn bởi `tests/acceptance-qdrant.sh` cho tới khi test đó pass.

## Layout multi-version

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

PostgreSQL dùng package chính thức từ PGDG. Redis exact version được compile từ source tarball chính thức; Redis 8.10+ mặc định dùng upstream core-only build target để tránh kéo theo toolchain module nặng. Elastic tải tar archive chính thức và xác minh file SHA-512 sidecar trước khi giải nén. Qdrant được QNP source đã pin tải lúc runtime từ official GitHub release của `qdrant/qdrant`. Adapter của development kit bind Qdrant vào `127.0.0.1` và cố ý tắt public tunnel/proxy mode.

## CLI thống nhất

Dùng [`bin/kdev`](bin/kdev) thay vì phải nhớ nhiều helper nằm trong `.system`:

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

Cài từng nhóm:

```bash
bin/kdev install postgres
bin/kdev install redis
bin/kdev install elastic
bin/kdev install qdrant
bin/kdev install tools
bin/kdev install all
```

## SSH + VS Code Remote-SSH

Việc cài database/toolchain không cần credential SSH. Khi muốn truy cập Kaggle qua SSH/ngrok, tạo hai **Kaggle Secrets**:

- `SSH_PUBLIC_KEY`
- `NGROK_AUTHTOKEN`

Sau đó chạy:

```bash
bash setup.sh
# hoặc
bin/kdev ssh start
```

`setup.sh` chỉ bind sshd ở loopback và dùng public-key authentication. Connection state chỉ được ghi trong `.kaggle-ssh/`.

## Restore / phiên Kaggle mới

Repository và runtime state được tách riêng có chủ đích. Sau khi restore output cũ của `/kaggle/working`, chạy:

```bash
bash install/install-all.sh bootstrap
bin/kdev doctor
```

Nếu bắt đầu từ session sạch, chỉ cần chạy lại notebook: Cell 1 lấy source, Cell 2 tạo config local, Cell 3 tạo lại runtime còn thiếu.

## Checksum và đóng gói public

```bash
bash scripts/refresh-manifest.sh
sha256sum -c MANIFEST.sha256
(cd install && sha256sum -c MANIFEST.sha256)

bash scripts/build-release-zips.sh
```

Release script chỉ tạo source ZIP public và cố ý loại `.git/`, `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env` và các ZIP cũ.

## Ranh giới security/public

Có thể public: `setup.sh`, `install/`, `scripts/`, `bin/`, `config/defaults.env`, `notebooks/`, `mise.toml`, tài liệu/license/checksum và SQLite binary đi kèm notice.

Giữ private/runtime-only: `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, `.env*`, private key, token, log, PID, database/dump, tunnel endpoint và `private.env`.

Dự án này dành cho **development single-user**, không phải production database host nhiều người dùng. Xem [`SECURITY.vi.md`](SECURITY.vi.md).

## Tài liệu phân tích kiến trúc

Xem [`docs/SOURCE-REVIEW.vi.md`](docs/SOURCE-REVIEW.vi.md) để biết vì sao runtime snapshot không nên public, các thiếu sót của baseline cũ, thiết kế multi-version mới và checklist release.

## License

Code/config/tài liệu của project dùng MIT License trừ khi có ghi chú khác. Thành phần bên thứ ba giữ license riêng; xem [`THIRD_PARTY_NOTICES.vi.md`](THIRD_PARTY_NOTICES.vi.md) và [`licenses/`](licenses/).
