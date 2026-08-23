# Thông báo phần mềm bên thứ ba

> 🌐 Language / Ngôn ngữ: [English](THIRD_PARTY_NOTICES.md) | **Tiếng Việt**

Tài liệu này mô tả các thành phần bên thứ ba được repository đóng gói hoặc được installer tải về. Tài liệu không thay thế nội dung giấy phép chính thức của upstream và không phải tư vấn pháp lý.

## Phạm vi giấy phép MIT của repository

`LICENSE` ở thư mục gốc áp dụng cho Bash/Python code, notebook, tài liệu và cấu hình được viết cho repository này. MIT **không** tự động áp dụng cho phần mềm bên thứ ba.

## SQLite 3.53.4

Repository đóng gói hai bộ công cụ Linux x86-64:

- `install/sqlite3/`: bản đã strip
- `install/sqlite3-original-build/`: bản không strip

Các executable gồm `sqlite3`, `sqldiff`, `sqlite3_analyzer`, `sqlite3_rsync`. Phần lõi SQLite được SQLite Project công bố dưới dạng public domain.

Metadata source được pin:

- Version: SQLite 3.53.4
- Source archive: `sqlite-src-3530400.zip`
- Source page: `https://sqlite.org/download.html`
- Source URL: `https://www.sqlite.org/2026/sqlite-src-3530400.zip`
- SHA3-256: `b834d474b9b393d85a9e3ee4cc11f1329e007e9376a424ee740796f5c4bda3a8`
- Rebuild helper: `scripts/rebuild-sqlite-tools.sh`

Xem `licenses/SQLite-PUBLIC-DOMAIN.txt`.

### GNU Readline

Các executable `sqlite3` được đóng gói liên kết động tới `libreadline.so.8`. GNU Readline dùng GPL-3.0-or-later. Repository có `licenses/GPL-3.0-or-later.txt` và ghi lại source/rebuild procedure tương ứng của SQLite. Shared library Readline không được đóng gói vào repository.

### Tcl, zlib, glibc và system libraries

`sqlite3_analyzer` liên kết động tới Tcl 8.6; một số binary sử dụng zlib, glibc, libm và các thư viện terminal/system. Các shared library này do môi trường Kaggle/Linux cung cấp và giữ nguyên giấy phép riêng của chúng.

## PostgreSQL và pgvector

Installer tải PostgreSQL và package `postgresql-<major>-pgvector` khi chạy từ PostgreSQL Global Development Group APT repository. Repository này không đóng gói các package đó. PostgreSQL và pgvector dùng PostgreSQL License; xem `licenses/PostgreSQL.txt` và license đi kèm package thực tế.

## Redis

Repository không đóng gói Redis binary hoặc Redis source. `install/install-redis.sh` tải đúng tarball release được yêu cầu từ `download.redis.io/releases/` khi chạy, có thể kiểm tra SHA-256 do maintainer pin, compile trong staging directory, rồi chỉ copy runtime tools vào `.system/redis/versions/<version>/`.

Giấy phép Redis đã thay đổi giữa các dòng release. Người dùng cần kiểm tra license đi kèm **đúng Redis version** đã chọn và tuân thủ các điều khoản đó, đặc biệt trước khi redistribution hoặc cung cấp Redis như một dịch vụ.

## Elastic Stack

Repository không đóng gói Elasticsearch, Kibana hoặc Logstash. `install/install-elastic.sh` tải các official default-distribution archive theo version từ `artifacts.elastic.co`, kiểm tra SHA-512 sidecar do Elastic publish, rồi cài vào `.system/elastic/versions/<version>/` khi chạy.

Default distribution của Elastic được publish theo Elastic License 2.0 (ELv2). Source code Elastic có thêm các lựa chọn license tùy file/version. Cần kiểm tra upstream license của đúng component/version và mục đích sử dụng. Repository này không redistribute các archive của Elastic.

## Qdrant và Qdrant Native Portable

Repository không đóng gói Qdrant binary hoặc QNP source checkout. `install/install-qdrant.sh` fetch QNP `1.0.0` (từ repository mã nguồn mở [`dangkhoa2016/Qdrant-Native-Portable`](https://github.com/dangkhoa2016/Qdrant-Native-Portable) của cùng tác giả) tại đúng Git commit `066084be23d23a5be11ca8e5df28d5da9eef1cc4` khi chạy. QNP release được pin này dùng MIT License. Sau đó QNP source đã pin tải official Qdrant release binary được chọn vào runtime tree `.system/` đã gitignore.

Qdrant **v1.18.3** là release Qdrant đã được validation cho baseline v1.0.0, dùng Apache License 2.0 trong upstream `qdrant/qdrant`. Các Qdrant version khác mà người dùng có thể chọn giữ license đi kèm đúng upstream release đó và cần được kiểm tra riêng. Public source ZIP của repository này không redistribute QNP hoặc Qdrant.

## mise, Node.js, npm, Yarn và Ruby

Installer tải mise khi chạy; mise tiếp tục tải các version runtime/tool được cấu hình. Repository không đóng gói các runtime này. Mỗi upstream project giữ giấy phép riêng.

## Không bảo đảm pháp lý

Đây là inventory kỹ thuật, không thay thế việc đọc điều khoản upstream. Mọi việc sử dụng, chỉnh sửa, deploy hoặc redistribution phải tuân thủ giấy phép của đúng version bên thứ ba được sử dụng và luật áp dụng.
