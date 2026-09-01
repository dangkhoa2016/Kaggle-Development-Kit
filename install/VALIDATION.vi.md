# Validation

> 🌐 Language / Ngôn ngữ: [English](VALIDATION.md) | **Tiếng Việt**

Baseline đã ghi nhận: **2026-08-22**

Tài liệu này ghi lại một baseline validation có thể chạy lại cho public repository. Các version tương lai chưa được kiểm tra không mặc nhiên được xem là được hỗ trợ.

## Baseline Qdrant đã được xác minh

```text
QNP release: 1.0.0
QNP commit: 21f83a6df7410b8f8bcc1a0919c0b51999d4b6ca
Qdrant: 1.18.3
REST acceptance endpoint: 127.0.0.1:16333
bind scope: loopback-only
gRPC: disabled
public mode: none
```

Một lần chạy native acceptance trên Kaggle đã ghi nhận:

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

Lần chạy acceptance xác minh rằng pinned QNP source được sử dụng, Qdrant `1.18.3` chạy native, vector data tồn tại sau restart và lần chạy installer thứ hai, listener chỉ bind loopback, không tạo public tunnel và output đã sanitize không lộ generated API key.

## Coverage permission và cold restore

Qdrant acceptance fixture dùng QNP `PROCESS_MODE=service-user`. Disposable root cho phép service identity traverse mà không cấp quyền list directory hoặc write, trong khi `qdrant.env` vẫn thuộc root và giữ mode `0600`.

Các kiểm tra liên quan:

```text
tests/test-qdrant-acceptance-permissions.sh
tests/test-qdrant-cold-restore.sh
tests/test-bootstrap-privilege.sh
tests/test-redis-cold-restore.sh
tests/test-mise-cold-restore.sh
tests/test-doctor-mise-toolchain.sh
```

Trên Kaggle, state trong `/kaggle/working` có thể tồn tại lâu hơn OS account của VM bên dưới. `install/install-all.sh bootstrap` tái tạo Qdrant service user đã ghi nhận khi cần và khôi phục ownership cho các writable path đã lưu. `config/qdrant.yaml` vẫn giữ `root:<user>` với mode `0640`. Coverage cold restore của PostgreSQL cũng xác minh rằng `install/install-all.sh install` tái tạo các thư mục cluster rỗng bắt buộc trước khi gọi PostgreSQL installer, tránh trường hợp cluster đã restore fail ngay lần start đầu tiên vì các path như `pg_notify` bị mất. Coverage deterministic cho Redis chạy đúng path cấu hình instance thật của standalone `install-redis.sh` và xác minh ownership stale ở bên trong `data/`, `logs/` và `run/` được sửa trước validation, trong khi `redis.conf`, `redis-user.conf`, `port` vẫn thuộc root và không tạo state world-writable. Coverage cold restore của mise mô phỏng các managed binary đã lưu bị đổi thành mode `0644`: execute state dưới `bin/`/`sbin/` được sửa trước, exact pin còn thiếu cấu trúc hoặc sai version được force-reinstall riêng lẻ, còn installer verification và doctor đều tắt auto-install khi probe và bắt buộc cả managed-path provenance lẫn exact version của Node/Ruby/npm/Yarn.

## Deterministic và integration checks

Repository có các kiểm tra sau:

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

`tests/integration-qdrant-adapter.sh` dùng local QNP-compatible process fixture để kiểm tra lifecycle, idempotency và persistence một cách deterministic. `tests/acceptance-qdrant.sh` chạy với Qdrant native.

## Kiểm tra release hygiene

Public release tooling loại các runtime/sensitive path như:

- `.git/`
- `.system/`
- `.kaggle-ssh/`
- `.kaggle-dev.env`
- `.env*`
- log, PID, socket, private-key pattern
- `secrets.env`
- `runtime.env`
- `.qdrant-base`
- các ZIP đã có

Deterministic release-hygiene test:

```bash
bash tests/test-release-hygiene.sh
```

## Chạy lại validation của repository

Từ một checkout sạch:

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

Để kiểm tra cả public source archive:

```bash
OUT_DIR="$PWD/release"
bash scripts/build-release-zips.sh "$OUT_DIR"
(cd "$OUT_DIR" && sha256sum -c kaggle-development-kit-v1.0.0.zip.sha256)
```

Giải nén ZIP vào một thư mục sạch rồi chạy lại checksum, shell syntax, deterministic tests, SQLite checksum và notebook JSON checks trong thư mục đó.

## Tóm tắt hành vi đã được xác minh

- Cell 2 của notebook hỗ trợ exact multi-version Qdrant config, default version, REST/gRPC port, auto-start policy, resource profile, QNP release và full 40-character QNP source pin.
- Qdrant instance được cô lập trong `.system/qdrant/instances/<version>/`.
- Adapter dùng native single-node mode, `127.0.0.1`, `PUBLIC_MODE=none` và `START_TUNNEL=0`.
- Routing `bin/kdev qdrant [VERSION] start|stop|restart|status|health|url|logs|version` được test.
- PostgreSQL hỗ trợ nhiều major với data/log/run/service helper cô lập và pgvector integration; cluster đã lưu được preflight-repair các thư mục rỗng chuẩn bị mất trước khi installer start PostgreSQL.
- Redis hỗ trợ nhiều exact release `X.Y.Z` với runtime/instance cô lập; ownership của writable `data/logs/run` đã lưu được sửa đệ quy trước validation startup mà không chuyển các metadata instance được quản lý khỏi root.
- Elastic hỗ trợ nhiều exact release `X.Y.Z` với runtime/config/data/log/run tree cô lập.
- Cold restore cho Node/Ruby/npm/Yarn do mise quản lý sửa executable state theo phạm vi, chỉ reinstall exact pin còn unhealthy, và fail validation nếu rơi sang system PATH hoặc sai configured version.
- Hai bộ SQLite tool stripped và original có checksum đã ghi.

Baseline đã ghi nhận chỉ áp dụng cho các version nêu ở trên. Các version khác nên được validation riêng trước khi xem là được hỗ trợ.
