# Kiến trúc bộ cài

> 🌐 Language / Ngôn ngữ: [English](README.md) | **Tiếng Việt**

Mọi installer tự động nạp `config/defaults.env`, sau đó nạp `.kaggle-dev.env` local đã gitignore.

- `install-all.sh`: điều phối SQLite, PostgreSQL, Redis, Elastic, Qdrant và mise tools; trước khi gọi PostgreSQL trên state đã lưu, nó tái tạo các thư mục cluster rỗng bắt buộc có thể bị mất sau cold restore.
- `install-postgres.sh`: hỗ trợ nhiều PostgreSQL major version từ PGDG, data/log/run tách riêng, tùy chọn pgvector.
- `install-redis.sh`: compile nhiều exact Redis release từ source chính thức vào runtime/instance theo version; trước validation, installer sửa đệ quy ownership của `data/`, `logs/` và `run/` đã lưu cho Redis service user hiện tại.
- `install-elastic.sh`: nhiều exact Elastic Stack version, runtime/config/data/log/run tách riêng, xác minh SHA-512 chính thức.
- `install-qdrant.sh`: nhiều exact Qdrant release thông qua một QNP 1.0.0 checkout được pin bằng full Git commit, với instance root tách riêng và endpoint local chỉ bind loopback.
- `install-other.sh`: mise cùng Node/Ruby/npm/Yarn đã pin version.
- `lib/common.sh`: helper privilege, package extraction, permission, atomic runtime replacement.
- `lib/load-config.sh`: helper cấu hình, version key và list dùng chung.

Cách dùng khuyến nghị:

```bash
bash install/install-all.sh install
bash scripts/doctor.sh
bin/kdev versions
```

Restore `.system` đã có:

```bash
bash install/install-all.sh bootstrap
```

Bootstrap an toàn với cold restore: sau khi Kaggle reset VM/runtime, nó tái tạo các service user bị mất, sửa đệ quy ownership của `data/`, `logs/` và `run/` trong từng Redis instance đã lưu, đồng thời sửa lại ownership của Qdrant đã lưu — `storage/`, `snapshots/`, `logs/`, `tmp/` nhận lại `<user>:<user>`, còn `config/qdrant.yaml` nhận lại `root:<user>` và giữ mode chặt `0640`. Mọi thao tác sửa quyền chạy qua abstraction root/sudo chung và bootstrap fail nếu một thao tác sửa bắt buộc không thể khôi phục. Giống mọi installer khác trong repository, nó tôn trọng `KAGGLE_SYSTEM_DIR` nên toàn bộ runtime tree có thể đặt trên storage persistent.

### PostgreSQL

```bash
POSTGRES_VERSIONS="16 18" \
POSTGRES_PORT_16=5432 \
POSTGRES_PORT_18=5433 \
bash install/install-postgres.sh
```

Chỉ những version trong `POSTGRES_AUTO_START_VERSIONS` được giữ chạy sau validation. `POSTGRES_INSTALL_PGVECTOR=1` cài package pgvector tương ứng cho từng major version. Khi `install-all.sh install` thấy cluster đã lưu còn `PG_VERSION`, nó tái tạo các path rỗng chuẩn như `pg_notify`, `pg_logical/mappings` và `pg_wal/archive_status` trước khi PostgreSQL installer có thể start cluster đó.

### Redis

```bash
REDIS_VERSIONS="7.4.10 8.10.0" \
REDIS_PORT_7_4_10=6380 \
REDIS_PORT_8_10_0=6379 \
bash install/install-redis.sh
```

Redis dùng exact release upstream. Mỗi version có runtime và persistence directory riêng. Khi reinstall/cold restore, standalone installer chỉ sửa ownership đệ quy bên trong các tree writable `data/`, `logs/` và `run/` trước validation startup; các file được quản lý ở instance root (`redis.conf`, `redis-user.conf` và `port`) vẫn thuộc root. Có thể dùng `REDIS_SHA256_<VERSION_KEY>` để pin digest tarball.

### Elastic Stack

```bash
ELASTIC_VERSIONS="9.4.2 9.5.0" \
ELASTIC_COMPONENTS="elasticsearch kibana logstash" \
ELASTIC_AUTO_START_VERSIONS="" \
bash install/install-elastic.sh
```

Mỗi version được cô lập. Elasticsearch/Kibana/Logstash trong cùng một instance cố ý dùng cùng version. Tar archive được xác minh bằng SHA-512 sidecar đi kèm artifact. Elastic mặc định không auto-start.

### Qdrant

```bash
QDRANT_VERSIONS="1.18.3" \
QDRANT_PORT_1_18_3=6333 \
QDRANT_GRPC_PORT_1_18_3=6334 \
QDRANT_ENABLE_GRPC=0 \
QDRANT_AUTO_START_VERSIONS="1.18.3" \
bash install/install-qdrant.sh
```

Adapter pin QNP `1.0.0` (từ repository [`dangkhoa2016/Qdrant-Native-Portable`](https://github.com/dangkhoa2016/Qdrant-Native-Portable) của cùng tác giả) tại commit `066084be23d23a5be11ca8e5df28d5da9eef1cc4`, chạy native single-node, bind Qdrant vào `127.0.0.1` và tắt public access của QNP. Mỗi exact Qdrant version có tree `.system/qdrant/instances/<version>/` riêng. Qdrant **1.18.3** là baseline v1.0.0 đã được xác minh; exact version khác vẫn có thể cấu hình nhưng nên được kiểm tra riêng trước khi xem là baseline được hỗ trợ.

Xem README ở root, [`VALIDATION.vi.md`](VALIDATION.vi.md) và `notebooks/kaggle-dev-bootstrap.ipynb` để biết cách sử dụng và validation dành cho người dùng public.
