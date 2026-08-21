# Báo cáo validation

> 🌐 Language / Ngôn ngữ: [English](VALIDATION.md) | **Tiếng Việt**

Ngày validation: 2026-08-22

## Trạng thái release candidate

Source tree này là **release candidate**, chưa phải final tagged release. Phần tích hợp Qdrant đã pass các kiểm tra deterministic về cấu hình, pin source, CLI/doctor, lifecycle bằng local process, persistence, syntax, notebook và release hygiene trong build environment. Release gate cuối cùng là chạy Qdrant 1.18.3 native thật trên một Kaggle Notebook mới có outbound Internet.

Build sandbox hiện tại không resolve được `github.com`, vì vậy `tests/acceptance-qdrant.sh` thoát với status `75` và kết quả `BLOCKED` rõ ràng trước khi tải bất kỳ thứ gì. Đây là giới hạn của environment, không phải kết quả acceptance Qdrant đã pass. Không được đánh dấu adapter Qdrant cho Kaggle là final-release validated cho tới khi chính test đó pass trên một Kaggle session mới.

## Phần tích hợp Qdrant đã validation trong build này

- Cell 2 của notebook nhận cấu hình Qdrant exact multi-version, default version, REST/gRPC port, auto-start policy, resource profile, QNP release và full QNP source commit 40 ký tự.
- Target mặc định là Qdrant `1.18.3`, REST `6333`, gRPC `6334`, gRPC mặc định tắt và Qdrant mặc định auto-start.
- Đã chạy thử tự cấp port với Qdrant `1.18.2` + `1.18.3`; các REST/gRPC port được sinh không va chạm PostgreSQL, Redis hoặc Elastic.
- `install/install-qdrant.sh` pin QNP bằng exact release + full Git commit, kiểm tra QNP `VERSION`, chạy source-integrity của QNP khi có, activate source atomically và tái dùng immutable cache hợp lệ ở lần cài sau.
- Mỗi Qdrant version có tree `.system/qdrant/instances/<version>/` riêng cùng REST/gRPC metadata độc lập.
- Adapter ép native, single-node, bind `127.0.0.1`, `PUBLIC_MODE=none` và `START_TUNNEL=0`.
- Đã test routing `bin/kdev qdrant [VERSION] start|stop|restart|status|health|url|logs|version`.
- `scripts/doctor.sh` kiểm tra QNP pin, Qdrant binary, loopback config, endpoint metadata và running/ready state mà không in generated API key.
- Integration fixture local khởi chạy một HTTP process thật thông qua Qdrant service helper được sinh, ghi persistence sentinel, restart service, chạy lại installer và xác nhận sentinel sống qua cả hai thao tác.
- QNP pin/release mismatch, exact version không hợp lệ, port trùng và cấu hình sai đều fail closed.

## Các Qdrant test đã pass tại đây

```text
tests/test-load-config.sh              PASS
tests/test-qdrant-config.sh            PASS
tests/test-qdrant-installer.sh         PASS
tests/test-qdrant-cli.sh               PASS
tests/integration-qdrant-adapter.sh    PASS
```

`tests/integration-qdrant-adapter.sh` cố ý dùng một fixture tương thích QNP chạy local để kiểm tra adapter mới, process lifecycle, loopback endpoint, idempotent reinstall và persistence mà không tuyên bố fixture đó chính là Qdrant.

## Bằng chứng QNP/Qdrant thật đã có từ trước

Dự án Qdrant Native Portable được dùng làm integration authority trước đây đã chạy Qdrant thật `1.18.3` thành công trong external validation, gồm collection/vector operation có authentication và persistence/recreation. Bằng chứng trước đó hỗ trợ việc chọn QNP/Qdrant baseline này, nhưng **không** thay thế fresh Kaggle acceptance gate của adapter mới.

## Final Kaggle release gate

Chạy từ repository root trên một Kaggle Notebook mới có Internet:

```bash
bash tests/acceptance-qdrant.sh
```

Một run thành công phải kết thúc bằng:

```text
fresh_install=PASS
readyz=PASS
vector_upsert_read_search=PASS
restart_persistence=PASS
idempotent_second_install=PASS
doctor=PASS
PASS: real Qdrant 1.18.3 native acceptance
```

Test còn kiểm tra bind chỉ trên loopback, không có QNP public tunnel artifact và generated API key không xuất hiện trong acceptance summary đã sanitize hoặc doctor output.

## Các kiểm tra GitHub-first multi-version khác

- Public shell script pass `bash -n`, gồm cả template sinh service controller.
- Notebook hợp lệ theo nbformat/JSON và giữ Cell 1 là GitHub fetch/update, Cell 2 là cấu hình người dùng.
- Cell 2 đã được chạy thử với cấu hình default và multi-version, gồm global port-collision detection.
- PostgreSQL hỗ trợ nhiều major với data/log/run/service helper riêng.
- Redis hỗ trợ nhiều exact release `X.Y.Z` với runtime/instance directory cô lập.
- Elastic hỗ trợ nhiều exact release `X.Y.Z` với runtime/config/data/log/run cô lập.
- Public release builder loại `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, file environment chứa secret, private-key pattern, log, cache và ZIP sinh ra.
- Hai bộ SQLite bundled tool được kiểm tra theo checksum đã ghi.

## Kiểm tra release-candidate archive sau khi giải nén sạch

Một RC archive đã được build rồi validation từ bản giải nén sạch, không dùng trực tiếp working tree:

- root `MANIFEST.sha256`: verify 59 entry;
- installer `MANIFEST.sha256`: verify 26 entry;
- 20 shell file đã giải nén pass `bash -n`;
- notebook đã giải nén pass `nbformat.validate`;
- toàn bộ deterministic Qdrant test cùng local-process adapter integration test pass từ archive đã giải nén;
- scan ZIP entry không thấy `.git/`, `.system/`, `.kaggle-ssh/`, `.kaggle-dev.env`, log/PID/socket, private-key file pattern, `secrets.env`, `runtime.env` hoặc `.qdrant-base`.

Kết quả archive verification này không thay đổi trạng thái BLOCKED của real native Kaggle acceptance gate.

## Full smoke test đề xuất trước release

Sau khi Qdrant acceptance gate pass, chạy:

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

Sau đó stop các service không cần thiết và xác nhận Git không stage private/runtime state.
