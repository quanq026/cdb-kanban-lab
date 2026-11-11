# Bảo mật

Tài liệu mô tả chi tiết các biện pháp và kiến trúc bảo mật của dự án **CDB Kanban**.

---

## 1. Nguyên tắc thiết kế

- **Least Privilege (Quyền hạn tối thiểu)**: Áp dụng ở mọi tầng từ tài khoản database, quyền hạn người dùng trong container Linux đến cổng mạng mở ra ngoài.
- **Fail Closed (Đóng khi có lỗi)**: Khi xảy ra sự cố cơ sở dữ liệu hoặc thiếu phiên đăng nhập, hệ thống trả về mã lỗi JSON chuẩn (401/403/503), không bao giờ làm lộ stack trace hay thông tin nhạy cảm.
- **Không tin cậy Client**: Mọi quyền truy cập dữ liệu (`task`, `user`) đều được xác thực và đối chiếu nghiêm ngặt với `session.uid` phía máy chủ. Mọi câu lệnh SQL đều được tham số hóa.
- **Phòng thủ theo chiều sâu (Defense-in-Depth)**: Kết hợp bảo vệ mạng (firewall), bảo vệ proxy (Caddy TLS), bảo vệ container (read-only, non-root, drop capabilities) và bảo vệ ứng dụng (CSP, security headers, cookie ký mã hóa).

---

## 2. Bảo mật mạng & Cổng kết nối

| Cổng | Giao thức | Phạm vi truy cập | Mục đích |
|---|---|---|---|
| `80` | HTTP | Toàn cầu (Public) | Nhận request từ người dùng; Caddy tự động chuyển hướng 301 sang HTTPS |
| `443` | HTTPS | Toàn cầu (Public) | Điểm truy cập web chính thống, mã hóa TLS |
| `5432` | PostgreSQL | Nội bộ host (`127.0.0.1`) | Chỉ mở cho chính máy host để chạy dev local; **không** mở ra Internet |
| `8000` | HTTP | Mạng nội bộ Docker | Gunicorn lắng nghe trong mạng bridge nội bộ; chỉ Caddy mới gọi tới |

- Caddy là cổng ngõ duy nhất tiếp nhận request từ bên ngoài Internet.
- Giao tiếp giữa Caddy, Flask App và PostgreSQL Container hoàn toàn nằm trên mạng ảo Docker riêng biệt.

---

## 3. Bảo vệ Container (Container Hardening)

Container ứng dụng (`cdb-app`) được cấu hình nghiêm ngặt trong `docker-compose.yml` và `Dockerfile`:
- **Chạy dưới quyền non-root**: Khởi tạo user `app` với `UID 10001`, không có quyền `sudo` hay quyền root trong container.
- **Root filesystem chỉ đọc (`read_only: true`)**: Mã nguồn và hệ thống tệp bên trong container không thể bị sửa đổi hoặc ghi đè ngay cả khi ứng dụng bị tấn công thực thi mã.
- **Chỉ ghi tạm vào RAM (`tmpfs: /tmp:size=32m`)**: Chỉ thư mục `/tmp` được phép ghi tạm thời với dung lượng giới hạn trong bộ nhớ RAM, tự xóa sạch khi restart.
- **Bỏ mọi đặc quyền Linux (`cap_drop: ALL`)**: Tước toàn bộ Linux capabilities của container.
- **Chặn leo thang đặc quyền (`security_opt: no-new-privileges:true`)**: Không cho phép tiến trình con giành thêm quyền thông qua suid/sgid.
- **Giới hạn bộ nhớ (`mem_limit: 256m`)**: Ngăn chặn tấn công DoS làm cạn kiệt tài nguyên RAM của máy chủ.

---

## 4. Quản lý Secret & Cấu hình

| File / Biến | Vị trí | Mục đích |
|---|---|---|
| `.env` | Máy chủ (local) | Chứa biến bí mật triển khai, đã được liệt kê trong `.gitignore` để không bao giờ bị lộ lên git |
| `.env.example` | Repository Git | File mẫu công khai, chỉ chứa các biến giữ chỗ (`DOMAIN=`, `APP_SECRET_KEY=`) |
| `APP_SECRET_KEY` | Biến môi trường | Chuỗi bí mật ngẫu nhiên dùng để ký cookie phiên đăng nhập; nếu thay đổi khóa này, mọi session cũ lập tức hết hiệu lực |
| `DB_PASSWORD` | Môi trường Docker | Mật khẩu giao tiếp nội bộ giữa App và Database; mặc định tự sinh giá trị nội bộ an toàn |

---

## 5. TLS / HTTPS & Edge

- **Tự động cấp phát chứng chỉ**: Caddy tự động đăng ký và gia hạn chứng chỉ TLS từ Let's Encrypt / ZeroSSL qua cơ chế ACME HTTP-01 / TLS-ALPN-01.
- **Ép buộc HTTPS**: Mọi truy cập qua cổng 80 đều được tự động chuyển hướng sang 443 với mã HTTP 301.
- **Tương thích Cloudflare Proxy**: Nếu người dùng trỏ domain qua Cloudflare, khuyến nghị đặt chế độ SSL là **Full (strict)** để mã hóa đầu cuối giữa Cloudflare và VPS.
- **Security Headers được tích hợp sẵn**:
  - `Content-Security-Policy`: `default-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'` (ngăn chặn XSS và Clickjacking, không dùng `unsafe-inline`).
  - `X-Content-Type-Options`: `nosniff` (ngăn chặn MIME-sniffing).
  - `X-Frame-Options`: `SAMEORIGIN`.
  - `Referrer-Policy`: `strict-origin-when-cross-origin`.
  - `Permissions-Policy`: `geolocation=(), microphone=(), camera=()`.

---

## 6. Xác thực & Quản lý phiên (Authentication & Session)

- **Mật khẩu an toàn**: Băm bằng giải thuật **scrypt** (`werkzeug.security`) với salt ngẫu nhiên riêng cho từng tài khoản, không lưu trữ mật khẩu dạng plaintext.
- **Chống Timing Attack**: Khi người dùng nhập sai email, ứng dụng vẫn thực hiện hàm so sánh băm với `DUMMY_HASH` để giữ độ trễ phản hồi đồng nhất, tránh rò rỉ sự tồn tại của email.
- **Cookie ký mã hóa (`cdb_session`)**:
  - `HttpOnly`: JavaScript không thể đọc được cookie (chống đánh cắp qua XSS).
  - `SameSite=Lax`: Chống tấn công CSRF.
  - `Secure=True`: Cookie chỉ được truyền qua đường dẫn HTTPS an toàn.
  - Hạn sử dụng: 12 giờ (`timedelta(hours=12)`).
- **Phân quyền người dùng**:
  - Mọi thao tác CRUD task đều kiểm tra `user_id` có khớp với `session.uid` hay không qua hàm `same_user()`.
  - Thao tác trên task của user khác hoặc task không tồn tại đều trả về `404 Not Found` để không lộ ID hay sự tồn tại của dữ liệu.
