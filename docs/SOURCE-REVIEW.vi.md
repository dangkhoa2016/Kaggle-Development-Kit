# Phân tích source và kiến trúc public GitHub/Kaggle

## 1. Kết luận từ bản ZIP development hiện tại

Bản development được dùng để review là một **snapshot trạng thái Kaggle đã chạy**, không phải source package phù hợp để push nguyên trạng lên GitHub. Nó chứa runtime/data/log/PID/cache và private state như `.kaggle-ssh/`, SSH host keys, `authorized_keys`, `private.env`, binary ngrok, PostgreSQL data directory và Elastic runtime state. Trong snapshot cũng không có root `setup.sh` mặc dù `scripts/doctor.sh` kiểm tra file này.

Do đó, không nên biến nguyên ZIP development thành repository public. Source public cần được dựng từ public baseline, còn `.system/` và `.kaggle-ssh/` chỉ là state được sinh ra khi chạy.

## 2. Điểm tốt của public baseline

- Có `setup.sh` cho SSH/ngrok, `install/`, `scripts/`, README song ngữ, SECURITY, LICENSE và third-party notices.
- PostgreSQL đã có hướng tách runtime khỏi data/log/run và hỗ trợ pgvector.
- SQLite binary có checksum và metadata build/rebuild.
- `.gitignore` đã có tư duy phân tách source khỏi runtime/private state.

## 3. Khoảng trống cần sửa để trở thành project public dễ dùng

- Version/config còn rải rác trong Bash script, người dùng phải sửa nhiều file.
- PostgreSQL chỉ có multi-version theo danh sách hard-code; Redis thực tế là single-version; Elastic runtime có trong snapshot nhưng installer source chưa có trong public baseline.
- Không có một notebook làm entry point chuẩn để clone repo rồi cấu hình toàn bộ stack.
- Helper command không thống nhất giữa PostgreSQL/Redis/Elastic.
- Public release script trước đây có khái niệm private/dev bundle, không phù hợp với mục tiêu repository công khai.

## 4. Kiến trúc mới

### Source/config layer

- `config/defaults.env`: default public an toàn.
- `.kaggle-dev.env`: local override do notebook sinh ra; luôn bị Git ignore.
- `install/lib/load-config.sh`: một loader chung cho installer.

### Versioned runtime layer

- PostgreSQL: cluster/helper tách theo major version.
- Redis: `.system/redis/versions/<version>/` và `.system/redis/instances/<version>/`.
- Elastic: `.system/elastic/versions/<version>/` chứa runtime/config/data/log/run theo version.

Cài nhiều version **không có nghĩa là start tất cả**. `*_AUTO_START_VERSIONS` quyết định version nào tự chạy. Elastic mặc định không auto-start để không chiếm RAM không cần thiết.

### Unified CLI

`bin/kdev` che giấu chi tiết helper path và cung cấp một interface ổn định:

```bash
bin/kdev versions
bin/kdev postgres 18 psql
bin/kdev redis 8.10.0 cli
bin/kdev elastic 9.5.0 start elasticsearch
bin/kdev doctor
```

## 5. Notebook contract

`notebooks/kaggle-dev-bootstrap.ipynb` cố ý để hai cell đầu có vai trò rõ ràng:

1. **Fetch source:** clone repo lần đầu hoặc fetch/reset checkout đã có về ref cấu hình.
2. **User config:** Python dictionary chứa version, default version, auto-start, port, heap và mise tool versions; cell validate rồi ghi `.kaggle-dev.env` mode `0600`.

Nếu thêm version nhưng chưa khai báo port, notebook tự chọn port chưa dùng. Nếu người dùng tạo collision thủ công, cell dừng với lỗi trước khi installer chạy.

## 6. Default hiện tại

- PostgreSQL: `18`, port `5433`, auto-start `18`, pgvector bật.
- Redis: `8.10.0`, port `6379`, auto-start `8.10.0`.
- Elastic Stack: `9.5.0`; Elasticsearch `9200`, Kibana `5601`, Logstash API `9600`, Logstash input `5044`; **không auto-start mặc định**.

Elastic `9.5.0` được giữ làm default vì đây là version xuất hiện trong runtime/log của snapshot development đã chạy, không phải tuyên bố rằng đó luôn là “latest”.

## 7. Public security boundary

Không được commit/publish:

- `.system/`
- `.kaggle-ssh/`
- `.kaggle-dev.env`
- `private.env`, private SSH key, host key
- database/data directory, PID/socket/log/cache
- token/ngrok connection state

Secrets SSH/ngrok nên đi qua Kaggle Secrets hoặc local private state và không nằm trong notebook source.

## 8. Validation đã thực hiện

- Syntax check toàn bộ Bash script.
- Parse/validate notebook bằng `nbformat`/JSON.
- Chạy Cell 2 với default và multi-version combinations.
- Test automatic port allocation và collision detection.
- Test routing của `bin/kdev` bằng fake helpers.
- Kiểm tra public/private boundary.
- Kiểm tra checksum của bundled SQLite binaries.

Chưa chạy full Internet download + lifecycle của mọi version trên chính build container; cần một smoke test cuối trên fresh Kaggle Notebook trước public release/tag.
