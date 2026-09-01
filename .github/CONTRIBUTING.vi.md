# Đóng góp cho Kaggle Development Kit

> 🌐 Language / Ngôn ngữ: [English](CONTRIBUTING.md) | **Tiếng Việt**

Cảm ơn bạn đã quan tâm đến việc đóng góp cho Kaggle Development Kit. Dự án chủ động thận trọng với persistence, việc chỉ expose service ở local, hành vi restore và tính toàn vẹn của release. Thay đổi nên giữ các bảo đảm này trừ khi pull request chủ động đề xuất và tài liệu hóa một thay đổi policy.

## Trước khi bắt đầu

1. Tìm issue và pull request hiện có để tránh trùng công việc.
2. Giữ mỗi thay đổi tập trung vào một vấn đề hoặc feature có tính logic riêng.
3. Không đưa runtime state, database data, log, credential, tunnel endpoint, private key, PID/socket sinh ra hoặc `.kaggle-dev.env` vào repository.
4. Với thay đổi hành vi, bổ sung regression coverage khi phù hợp.
5. Khi hành vi dành cho người dùng thay đổi, cập nhật tài liệu English và Vietnamese đồng thời.

## Quy trình development

Tạo topic branch từ `main` mới nhất, thực hiện thay đổi nhỏ nhất nhưng đầy đủ về logic, và dùng commit message mô tả mục đích thay vì lịch sử debug.

Repository dùng SHA-256 manifest cho nội dung release được Git track. Sau khi thay đổi file tracked, làm mới manifest:

```bash
bash scripts/refresh-manifest.sh
sha256sum -c MANIFEST.sha256
(cd install && sha256sum -c MANIFEST.sha256)
```

Kiểm tra cú pháp các shell script được track:

```bash
git ls-files '*.sh' | while IFS= read -r file; do
  bash -n "$file" || exit 1
done
```

Chạy các test liên quan đến thay đổi. Trước khi yêu cầu review, workflow GitHub Actions `CI` nên PASS; workflow này kiểm tra manifest, cú pháp shell, deterministic regression tests, checksum SQLite và JSON của notebook.

## Các invariant của project

Trừ khi thay đổi chủ động sửa một contract đã được tài liệu hóa, contribution nên giữ các mặc định sau:

- database và service endpoint chỉ bind loopback theo mặc định;
- SSH dùng public-key authentication và explicit forwarding;
- persisted state không bị âm thầm xóa trong cold restore;
- recovery fail-closed khi ownership, metadata hoặc source identity không thể được xác minh;
- exact runtime pin đã cấu hình được xác minh thay vì âm thầm thay bằng version khác;
- public release artifact loại private state và runtime state.

Xem [`../SECURITY.vi.md`](../SECURITY.vi.md), [`../README.vi.md`](../README.vi.md) và [`../install/VALIDATION.vi.md`](../install/VALIDATION.vi.md) để biết contract public hiện tại.

## Pull request

Một pull request tốt nên giải thích:

- vấn đề nào đang được giải quyết;
- vì sao cách tiếp cận đã chọn là phù hợp;
- test hoặc validation nào đã chạy;
- restore, security, compatibility hoặc release behavior có thay đổi hay không;
- tài liệu và manifest đã được cập nhật hay chưa.

Không gom refactor không liên quan vào cùng pull request trừ khi chúng thật sự cần thiết cho thay đổi.

## Vấn đề security

Không báo vulnerability nghi ngờ, credential bị lộ hoặc runtime artifact nhạy cảm trong public issue. Hãy làm theo hướng dẫn báo cáo riêng tư trong [`../SECURITY.vi.md`](../SECURITY.vi.md).
