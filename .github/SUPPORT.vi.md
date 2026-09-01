# Hỗ trợ

> 🌐 Language / Ngôn ngữ: [English](SUPPORT.md) | **Tiếng Việt**

Kaggle Development Kit được duy trì như một development toolkit mã nguồn mở. Hỗ trợ được cung cấp theo khả năng và được tổ chức qua GitHub Issues.

## Nên hỏi ở đâu

Dùng các issue form của repository cho:

- bug có thể tái hiện trong workflow đã được tài liệu hóa;
- đề xuất feature có use case rõ ràng;
- câu hỏi sử dụng chưa được README hoặc tài liệu validation giải đáp.

Trước khi mở issue, hãy kiểm tra:

- [`../README.vi.md`](../README.vi.md)
- [`../install/README.vi.md`](../install/README.vi.md)
- [`../install/VALIDATION.vi.md`](../install/VALIDATION.vi.md)
- các issue đang mở và đã đóng

Với lỗi runtime, hãy cung cấp command liên quan, hành vi mong đợi, hành vi thực tế, thông tin môi trường và log đã được sanitize. Không gửi secret, private key, Kaggle token, ngrok credential, tunnel connection detail, nội dung database hoặc private runtime state khác.

## Phạm vi

Project nhắm tới môi trường development Kaggle single-user có thể tái sử dụng. Đây không phải managed hosting service và không cam kết production multi-user database support, uptime hoặc compatibility với mọi tổ hợp version tùy ý.

Bạn có thể thử nghiệm cấu hình ngoài validated baseline đã tài liệu hóa, nhưng maintainer có thể yêu cầu minimal reproduction trên một baseline được hỗ trợ trước khi phân tích lỗi.

## Security

Không dùng public support issue để báo vulnerability nghi ngờ hoặc secret vô tình bị lộ. Hãy làm theo [`../SECURITY.vi.md`](../SECURITY.vi.md).
