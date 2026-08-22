# Báo cáo validation

> 🌐 Language / Ngôn ngữ: [English](VALIDATION.md) | **Tiếng Việt**

Ngày validation: 2026-08-22

## Trạng thái finalization v1.0.0

Real Kaggle Qdrant acceptance gate đã hoàn tất. Release gate còn lại là verification của gói phát hành: build public source ZIP cuối từ branch finalization, giải nén vào thư mục sạch rồi chạy lại manifest, syntax, deterministic/integration, notebook, SQLite checksum và release-hygiene checks trước khi tạo tag `v1.0.0`.

## Real Kaggle Qdrant acceptance

Target đã validation:

```text
QNP release: 1.0.0
QNP commit: 464cb5dbc1117a8a8a6472d76a10c5e329021156
Qdrant: 1.18.3
REST acceptance endpoint: 127.0.0.1:16333
bind scope: loopback-only
gRPC: disabled
public mode: none
```

Real native Kaggle run đã hoàn tất với:

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

Evidence độc lập từ run đó xác nhận pinned QNP source có integrity sạch, Qdrant `1.18.3` được tải và chạy native, vector data sống qua process restart và lần chạy installer thứ hai, listener chỉ bind loopback, không tạo public tunnel, doctor báo zero failure/warning và acceptance evidence đã sanitize không lộ generated API key.

## Regression permission của acceptance fixture

Acceptance fixture vẫn giữ QNP `PROCESS_MODE=service-user`. Disposable root dùng mode `0711`, cho phép service identity traverse tới service-owned runtime path nhưng không cấp quyền list directory hoặc write; file `qdrant.env` thuộc root vẫn giữ mode `0600`.

```text
tests/test-qdrant-acceptance-permissions.sh PASS
```

Điều này đóng lỗi trước đây khi `mktemp -d` tạo root mode `0700`, khiến generated Qdrant configuration hợp lệ không thể được `qdrantuser` truy cập.

## Coverage deterministic và integration

Qdrant adapter được bao phủ bởi:

```text
tests/test-load-config.sh                   PASS
tests/test-qdrant-config.sh                 PASS
tests/test-qdrant-installer.sh              PASS
tests/test-qdrant-cli.sh                    PASS
tests/integration-qdrant-adapter.sh         PASS
tests/test-qdrant-acceptance-permissions.sh PASS
tests/test-release-hygiene.sh               PASS
```

`tests/integration-qdrant-adapter.sh` cố ý dùng local QNP-compatible process fixture cho deterministic lifecycle/idempotency/persistence coverage. Run `tests/acceptance-qdrant.sh` riêng ở trên là evidence cho Qdrant native thật.

## Validation release hygiene

Public release boundary loại `.git/`, `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, local environment file, log, PID, socket, private-key pattern, `secrets.env`, `runtime.env`, `.qdrant-base` và ZIP cũ.

Release-hygiene fixture cũng đã được harden để không traverse live `.system/` runtime state khi chuẩn bị isolated test tree. Việc này ngăn active PostgreSQL Unix socket như `.s.PGSQL.5433` tạo cảnh báo gây nhiễu `tar: socket ignored`. Test đã cập nhật pass trên live Kaggle checkout khi PostgreSQL runtime state đang tồn tại.

## Các hành vi project khác đã validation

- Cell 2 của notebook hỗ trợ exact multi-version Qdrant config, default version, REST/gRPC port, auto-start policy, resource profile, QNP release và full 40-character QNP source pin.
- Qdrant instance được cô lập trong `.system/qdrant/instances/<version>/`.
- Adapter ép native, single-node, `127.0.0.1`, `PUBLIC_MODE=none` và `START_TUNNEL=0`.
- Routing `bin/kdev qdrant [VERSION] start|stop|restart|status|health|url|logs|version` đã được test.
- PostgreSQL hỗ trợ nhiều major với data/log/run/service helper cô lập và pgvector integration.
- Redis hỗ trợ nhiều exact release `X.Y.Z` với runtime/instance cô lập.
- Elastic hỗ trợ nhiều exact release `X.Y.Z` với runtime/config/data/log/run tree cô lập.
- Hai bộ SQLite tool stripped và original có checksum đã ghi.

## Final artifact gate

Tên public artifact mặc định của release này:

```text
kaggle-development-kit-v1.0.0.zip
kaggle-development-kit-v1.0.0.zip.sha256
```

Trước khi tag `v1.0.0`, build ZIP, giải nén vào thư mục sạch và yêu cầu toàn bộ lệnh sau pass:

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
bash tests/test-release-hygiene.sh
(cd install/sqlite3 && sha256sum -c SHA256SUMS)
(cd install/sqlite3-original-build && sha256sum -c SHA256SUMS)
```

Ngoài ra cần validate `notebooks/kaggle-dev-bootstrap.ipynb` bằng `nbformat.validate`, scan ZIP entry để tìm runtime/private path bị cấm và verify sidecar `.zip.sha256`. Chỉ tạo tag `v1.0.0` sau khi extracted-artifact gate này pass.
