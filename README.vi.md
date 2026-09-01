# Kaggle Development Kit

[![CI](https://github.com/dangkhoa2016/Kaggle-Development-Kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/dangkhoa2016/Kaggle-Development-Kit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/dangkhoa2016/Kaggle-Development-Kit?display_name=tag&sort=semver)](https://github.com/dangkhoa2016/Kaggle-Development-Kit/releases/latest)
[![License: MIT](https://img.shields.io/github/license/dangkhoa2016/Kaggle-Development-Kit)](LICENSE)

> 🌐 Language / Ngôn ngữ: [English](README.md) | **Tiếng Việt**

Dự án bootstrap theo hướng **GitHub-first** để biến một phiên Kaggle Notebook thành môi trường Linux phục vụ development. Dự án có thể cài và quản lý **SQLite, nhiều phiên bản PostgreSQL + pgvector, nhiều phiên bản Redis chính xác, nhiều phiên bản Elastic Stack, Qdrant, mise/Node/Ruby/npm/Yarn, OpenSSH, ngrok và tmux** mà không cần Docker.

Điểm vào được khuyến nghị là [`notebooks/kaggle-dev-bootstrap.ipynb`](notebooks/kaggle-dev-bootstrap.ipynb): Cell 1 lấy/cập nhật mã nguồn từ GitHub; Cell 2 là nơi người dùng chỉnh version/port/cấu hình.

## Baseline đã được xác minh

Baseline v1.0.0 được tài liệu hóa sử dụng Qdrant native `1.18.3` thông qua [Qdrant Native Portable (QNP)](https://github.com/dangkhoa2016/Qdrant-Native-Portable) `1.0.0` (dự án của cùng tác giả), pin tại commit `464cb5dbc1117a8a8a6472d76a10c5e329021156`. Tổ hợp này đã được xác minh trên Kaggle với fresh install, `/readyz`, vector upsert/read/search, persistence sau restart, cài lại idempotent, doctor checks, bind chỉ trên loopback, không public tunnel và output không lộ secret. Xem [`install/VALIDATION.vi.md`](install/VALIDATION.vi.md) để biết baseline đã ghi nhận và cách kiểm tra có thể chạy lại.

## Thiết kế dành cho public repository

Git repository chỉ chứa source, tài liệu, checksum và các SQLite tool được chủ động bundle. Runtime được tạo cục bộ trong `.system/`; trạng thái SSH/ngrok nằm trong `.kaggle-ssh/`; cấu hình riêng do notebook tạo nằm trong `.kaggle-dev.env`. Cả ba đều bị loại khỏi Git.

**Không public runtime snapshot** chứa database data, log, PID, `private.env`, `authorized_keys`, SSH host private key, token hoặc thông tin tunnel.

## Chạy nhanh trên Kaggle

1. Tạo Kaggle Notebook và bật Internet.
2. Upload/mở `notebooks/kaggle-dev-bootstrap.ipynb`.
3. **Cell 1** mặc định clone repository chính thức. Chỉ đặt `KAGGLE_DEV_REPOSITORY_URL` khi bạn muốn dùng fork hoặc repository khác.
4. Trong **Cell 2**, chỉnh version, port, component cần cài và danh sách auto-start.
5. Chạy Cell 3 để cài đặt, Cell 4 để kiểm tra.

Cell 1 kiểm tra sức khỏe repository bằng chính Git thay vì xem việc `.git/` tồn tại là bằng chứng checkout còn dùng được. Với checkout khỏe mạnh, Cell 1 fetch và reset chính xác về remote ref đã chọn. Sau Kaggle cold restore, nếu Git metadata bị thiếu hoặc không hoàn chỉnh, Cell 1 chỉ dựng lại Git metadata ngay tại chỗ, đồng thời giữ nguyên `.system/`, `.kaggle-dev.env` và các persisted state chưa track khác. Metadata hỏng được quarantine để phục vụ forensic sau khi recovery thành công; nếu quá trình dựng lại hoặc fetch thất bại, recovery fail-closed và khôi phục metadata hỏng ban đầu khi có thể.

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

Qdrant được tích hợp bằng một adapter mỏng trên **Qdrant Native Portable (QNP) 1.0.0 được pin bằng full Git commit** từ repository của cùng tác giả ([`dangkhoa2016/Qdrant-Native-Portable`](https://github.com/dangkhoa2016/Qdrant-Native-Portable)). QNP tiếp tục là source authority cho setup/lifecycle/strict-mode/storage của Qdrant; repository này bổ sung cấu hình Kaggle, cô lập theo version, tự phân bổ port, `kdev` và release hygiene. Qdrant **1.18.3** là target đã được xác minh cho baseline v1.0.0. Exact version `X.Y.Z` khác vẫn có thể cấu hình nhưng nên được xác minh riêng trước khi xem là baseline được hỗ trợ.

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

PostgreSQL dùng package chính thức từ PGDG. Redis exact version được compile từ source tarball chính thức. Elastic tải tar archive chính thức và xác minh file SHA-512 sidecar trước khi giải nén. Qdrant được QNP source đã pin tải lúc runtime từ official GitHub release của `qdrant/qdrant`. Adapter của development kit bind Qdrant vào `127.0.0.1` và cố ý tắt public tunnel/proxy mode.

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

Việc cài database/toolchain không cần credential SSH. Khi muốn truy cập một phiên Kaggle qua SSH/ngrok, tạo hai **Kaggle Secrets**:

- `SSH_PUBLIC_KEY`
- `NGROK_AUTHTOKEN`

Sau đó chạy:

```bash
bash setup.sh
# hoặc
bin/kdev ssh start
```

`setup.sh` chỉ bind sshd ở loopback và dùng public-key authentication. Connection state chỉ được ghi trong `.kaggle-ssh/`.

### Kết nối từ máy local hoặc cloud IDE

Chạy [`connect-kaggle.sh`](connect-kaggle.sh) trên **máy development phía local** (ví dụ GitHub Codespaces, terminal VS Code local hoặc một cloud IDE khác), không chạy trên Kaggle. Script duy trì một SSH ControlMaster và chỉ forward các port dịch vụ đã cấu hình đang thực sự LISTEN trên Kaggle.

Khi đã có entry `Host kaggle` chuẩn từ thông tin kết nối SSH/ngrok:

```bash
./connect-kaggle.sh start
./connect-kaggle.sh status
./connect-kaggle.sh stop
./connect-kaggle.sh restart
```

Mặc định, candidate port được discover từ cấu hình hiệu lực của Kaggle Development Kit (`config/defaults.env` cộng với `.kaggle-dev.env`). Có thể override hoặc bổ sung discovery:

```bash
KAGGLE_FORWARD_PORTS="6379 5433 6333" ./connect-kaggle.sh start
KAGGLE_EXTRA_PORTS="3000 8000 7860" ./connect-kaggle.sh start
KAGGLE_PORT_MAPS="15433:5433 16379:6379" ./connect-kaggle.sh start
```

Mọi local forward do script quản lý chỉ bind vào `127.0.0.1`. Chạy lại `start` là incremental và idempotent: service Kaggle mới bắt đầu listen sẽ được thêm mà không tạo duplicate forward. `start` cũng không phá hủy: mỗi profile giữ một bản ghi về phiên mà nó đang quản lý, và nếu phiên đã lưu đó còn sống nhưng SSH destination hiện tại lại resolve sang nơi khác, `start` sẽ từ chối đổi đích và yêu cầu bạn chạy `restart`.

`restart` là thao tác thay thế tường minh: nó dừng phiên managed đã lưu của profile, xác minh shutdown, rồi start endpoint desired vừa resolve hiện tại. Nó đối chiếu các ControlMaster sibling do script quản lý theo SSH destination đã resolve (`user`, `hostname`, `port`). Vì vậy hai SSH alias khác nhau nhưng cùng trỏ tới một Kaggle/ngrok endpoint được xem là cùng endpoint, còn một alias đã đổi sang ngrok session khác thì không. Đường dẫn identity file chỉ là cấu hình xác thực và không được dùng làm định danh endpoint. Nếu một managed ControlMaster không thể dừng sạch — kể cả sibling cùng endpoint từ chối kết thúc — `connect-kaggle.sh` giữ lại control socket và state rồi fail an toàn thay vì xóa metadata quản lý hoặc start phiên mới đè lên nó; restart cũng chờ một sibling chỉ là chậm thoát trước khi tiếp quản local port của nó. Bản ghi cũ của một phiên đã chết (stale) sẽ được `start`/`restart` tự dọn để phục hồi. Vì `stop` chỉ nhắm vào control path đã lưu của profile nên nó vẫn hoạt động ngay cả khi identity file bị chuyển đi hoặc cấu hình SSH không còn resolve được; `status` báo cáo endpoint stored so với desired mà không thay đổi state nào. Việc thay đổi chính sách ControlPath không bao giờ khiến `start` thay thế một master đang sống: nó tiếp tục dùng socket tại vị trí đã ghi nhận, và `restart` mới thực hiện migration sang path sinh mới. Script không tự động terminate các local process không liên quan; nếu một process khác đang chiếm local port cần dùng, việc bind sẽ fail an toàn và bạn có thể override bằng `KAGGLE_PORT_MAPS` hoặc tự giải phóng port đó.

Socket ControlMaster sinh tự động không nằm trực tiếp trong thư mục temp dùng chung: khi `$XDG_RUNTIME_DIR` được đặt, chúng nằm dưới `$XDG_RUNTIME_DIR/kaggle-connect/<profile-hash>.sock`, ngược lại nằm dưới `${TMPDIR:-/tmp}/kaggle-connect-<uid>/<profile-hash>.sock`. Thư mục `kaggle-connect` sinh tự động được tạo với quyền an toàn (mode `0700`), symlink tồn sẵn tại đường dẫn đó bị từ chối, và mode bị nới rộng sẽ được siết lại về `0700`. Đặt `KAGGLE_CONNECT_CONTROL_DIR` để chọn thư mục gốc riêng khác, hoặc `KAGGLE_CONNECT_CONTROL_PATH` nếu môi trường của bạn tự quản thư mục socket riêng.

## Restore / phiên Kaggle mới

Repository và runtime state được tách riêng có chủ đích. Sau khi restore output cũ của `/kaggle/working`, chạy:

```bash
bash install/install-all.sh bootstrap
bin/kdev doctor
```

Nếu bắt đầu từ session sạch, chạy lại notebook: Cell 1 lấy source, Cell 2 tạo config local, Cell 3 tạo lại runtime còn thiếu. Nếu data PostgreSQL đã lưu vẫn còn nhưng các thư mục cluster rỗng bị mất, đường chạy Cell 3 qua `install-all.sh install` sẽ sửa lại các thư mục bắt buộc đó trước khi PostgreSQL được start. Cold restore của Redis được xử lý ở cả `install/install-redis.sh` và đường chạy `install-all.sh install`: các tree `data/`, `logs/` và `run/` đã lưu được gán ownership đệ quy lại cho Redis service user hiện tại trước validation startup, trong khi `redis.conf`, `redis-user.conf` và `port` vẫn thuộc root. `install-all.sh bootstrap` áp dụng cùng contract ownership cho Redis writable state. Toolchain mise cũng xử lý cold restore: installer chỉ sửa execute bit bên dưới các path `bin/`/`sbin/` của tool đã lưu, probe từng exact pin được quản lý với mise auto-install bị tắt, và chỉ force-reinstall tool vẫn còn thiếu, không executable hoặc sai version. Validation fail-closed nếu Node, Ruby, npm hoặc Yarn managed không khớp pin đã cấu hình.

## Checksum và release artifact

Làm mới checksum:

```bash
bash scripts/refresh-manifest.sh
sha256sum -c MANIFEST.sha256
(cd install && sha256sum -c MANIFEST.sha256)
```

Build và verify public release artifact v1.0.0:

```bash
OUT_DIR="$PWD/release"
bash scripts/build-release-zips.sh "$OUT_DIR"
(cd "$OUT_DIR" && sha256sum -c kaggle-development-kit-v1.0.0.zip.sha256)
```

Builder tự tạo cả `kaggle-development-kit-v1.0.0.zip` và sidecar `.zip.sha256`. Release script cố ý loại `.git/`, `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, local environment file, log, PID, socket, private-key pattern, runtime secret và các ZIP cũ.

## Ranh giới security/public

Có thể public: `setup.sh`, `connect-kaggle.sh`, `install/`, `scripts/`, `bin/`, `config/defaults.env`, `notebooks/`, `mise.toml`, tài liệu/license/checksum và SQLite binary đi kèm notice.

Giữ private/runtime-only: `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, `.env*`, private key, token, log, PID, database/dump, tunnel endpoint và `private.env`.

Dự án này dành cho **development single-user**, không phải production database host nhiều người dùng. Xem [`SECURITY.vi.md`](SECURITY.vi.md).

## License

Code, cấu hình và tài liệu của project dùng MIT License trừ khi có ghi chú khác. Thành phần bên thứ ba giữ license riêng; xem [`THIRD_PARTY_NOTICES.vi.md`](THIRD_PARTY_NOTICES.vi.md) và [`licenses/`](licenses/).
