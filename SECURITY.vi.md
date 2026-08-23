# Security Policy

> 🌐 Language / Ngôn ngữ: [English](SECURITY.md) | **Tiếng Việt**

## Phạm vi sử dụng

Dự án dành cho môi trường notebook phát triển **đơn người dùng**, đặc biệt là
Kaggle. Không dùng nguyên cấu hình này cho production nhiều người dùng.

PostgreSQL dùng local `trust` authentication và Redis không cấu hình password
mặc định vì cả hai chỉ bind loopback. Không expose trực tiếp các port database
ra Internet.

## SSH / ngrok

`setup.sh` được thiết kế để có thể public và không hard-code credential.
Credential được lấy theo thứ tự:

1. environment variables;
2. `.kaggle-ssh/private.env`;
3. Kaggle Secrets.

sshd chỉ bind `127.0.0.1` và yêu cầu public-key authentication. Password, PAM,
keyboard-interactive authentication, agent forwarding, X11, `GatewayPorts` và
SSH tunnel device bị tắt. Local TCP forwarding vẫn được bật để phục vụ VS Code
Remote-SSH và forward service development.

Các file sau phải giữ private:

- `.kaggle-ssh/private.env`;
- `.kaggle-ssh/host-keys/*_key`;
- `.kaggle-ssh/connection.txt`;
- `.kaggle-ssh/logs/`;
- mọi SSH client private key;
- `NGROK_AUTHTOKEN` và token/API key khác.

`SSH_PUBLIC_KEY` không phải private key nhưng vẫn nên xem là thông tin cá nhân
của môi trường và không cần commit.

`setup.sh --save-secrets` lưu credential ở dạng base64 trong file mode `0600`.
Base64 **không phải mã hóa**. Nếu private bundle bị lộ, rotate ngrok token và
xóa/regenerate SSH host keys trước khi sử dụng lại.

Temporary ngrok config chứa token được xóa sau khi tunnel đã publish endpoint.

## Socket SSH ControlMaster trên máy local

`connect-kaggle.sh` duy trì một SSH ControlMaster tồn tại lâu cho mỗi profile. Socket của nó là tài nguyên nhạy cảm trên máy local: ai truy cập được socket đều có thể tái sử dụng kết nối đã xác thực. Vì vậy socket sinh tự động được đặt trong thư mục riêng theo từng user (mode `0700`) thay vì nằm trực tiếp trong temp root dùng chung; script từ chối symlink gài sẵn tại đường dẫn thư mục đó và siết mode bị nới rộng trở lại `0700`. Không trỏ `KAGGLE_CONNECT_CONTROL_PATH` vào thư mục mà user khác có thể ghi.

## Log và connection metadata

Ngrok/sshd log, endpoint và connection metadata có thể chứa IP, hostname, port
hoặc thông tin hoạt động. Không đưa chúng vào issue/public artifact trước khi
redact.

## Reporting a vulnerability

Không đăng credential, token, database dump hoặc thông tin nhạy cảm vào public
issue. Khi tạo repository GitHub, nên bật private vulnerability reporting trong
Security settings và dùng kênh đó để nhận báo cáo.

## Trước khi public log/artifact

Loại bỏ tối thiểu:

- `.kaggle-ssh/` và `.system/`;
- environment variables, `.env*`, `private.env`;
- private keys, access token, API key và URL chứa credential;
- `connection.txt`, ngrok/sshd logs;
- database dump;
- log có query hoặc dữ liệu người dùng.
