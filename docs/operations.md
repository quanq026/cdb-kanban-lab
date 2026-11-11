# Vận hành

Tài liệu hướng dẫn quản trị, vận hành, sao lưu và xử lý sự cố cho hệ thống **CDB Kanban** chạy trên Docker Compose.

---

## 1. Triển khai ứng dụng

### 1.1. Chuẩn bị máy chủ
- Máy chủ / VPS chạy Linux (Ubuntu, Debian, CentOS, v.v.), hỗ trợ cả x86_64 và ARM64.
- Đã cài đặt Docker và Docker Compose v2 (`docker compose version`).
- Tên miền đã trỏ bản ghi `A` (hoặc `AAAA`) về địa chỉ IP công khai của máy chủ.
- Tường lửa máy chủ (UFW / Security Group) đã mở cổng `80` và `443` (TCP).

### 1.2. Khởi chạy hệ thống
1. Clone mã nguồn về máy chủ:
   ```bash
   git clone <repo-url> && cd cdb-kanban-lab
   ```
2. Tạo file cấu hình môi trường:
   ```bash
   cp .env.example .env
   nano .env
   ```
   *Chỉ cần điền 2 trường bắt buộc:*
   - `DOMAIN`: Tên miền của bạn (ví dụ: `kanban.example.com`).
   - `APP_SECRET_KEY`: Chuỗi bí mật ngẫu nhiên (sinh nhanh bằng lệnh `openssl rand -hex 32`).

3. Khởi chạy toàn bộ hệ thống trong background:
   ```bash
   docker compose up -d --build
   ```

4. Kiểm tra trạng thái các container:
   ```bash
   docker compose ps
   ```
   Cả 3 container `cdb-db`, `cdb-app`, `cdb-caddy` đều ở trạng thái `running` (hoặc `healthy`).

---

## 2. Quản lý thường nhật

### 2.1. Theo dõi log
Xem log trực tiếp theo thời gian thực:
```bash
# Xem log toàn bộ hệ thống
docker compose logs -f

# Xem log riêng từng thành phần
docker compose logs -f app
docker compose logs -f caddy
docker compose logs -f db
```

### 2.2. Khởi động lại hoặc dừng dịch vụ
```bash
# Khởi động lại dịch vụ app
docker compose restart app

# Tạm dừng toàn bộ dịch vụ (dữ liệu DB trong volume vẫn được bảo toàn)
docker compose down

# Bật lại hệ thống
docker compose up -d
```

### 2.3. Cập nhật phiên bản mới
Khi có commit hoặc bản phát hành mới trên repository:
```bash
git pull origin main
docker compose up -d --build
```
Lệnh trên sẽ tự động rebuild image app mới và áp dụng thay đổi mà không làm mất dữ liệu của PostgreSQL.

---

## 3. Xử lý sự cố (Troubleshooting)

| Hiện tượng | Nguyên nhân có thể | Cách khắc phục |
|---|---|---|
| Truy cập web bị timeout | Chưa mở cổng tường lửa trên VPS | Kiểm tra `sudo ufw status`, chạy `sudo ufw allow 80,443/tcp` và kiểm tra Security Group của VPS |
| Lỗi SSL / "Certificate Invalid" | DNS chưa trỏ về IP máy chủ hoặc Let's Encrypt bị rate limit | Kiểm tra bản ghi domain: `dig +short yourdomain.com`. Xem log Caddy: `docker compose logs caddy` |
| Lỗi vòng lặp chuyển hướng (Redirect loop 301) | Sử dụng Cloudflare Proxy với chế độ SSL Flexible | Vào Cloudflare Dashboard → SSL/TLS → Chuyển sang chế độ **Full (strict)** |
| Ứng dụng báo lỗi 503 `db_unavailable` | Container DB đang khởi động hoặc gặp sự cố | Kiểm tra `docker compose ps` xem `cdb-db` đã `healthy` chưa. Đọc log bằng `docker compose logs db` |
| App không khởi động được | Thiếu file `.env` hoặc thiếu biến bắt buộc | Đảm bảo `.env` đã có giá trị cho `DOMAIN` và `APP_SECRET_KEY` |

---

## 4. Dọn dẹp & Gỡ bỏ hoàn toàn

Nếu muốn dừng và gỡ bỏ hoàn toàn dự án cùng toàn bộ dữ liệu database:
```bash
docker compose down -v --rmi all
```
> [!CAUTION]
> Tham số `-v` sẽ xóa vĩnh viễn volume `db_data` (chứa dữ liệu người dùng và task) cùng các volume SSL của Caddy. Nếu chỉ chạy `docker compose down` (không có `-v`), dữ liệu database vẫn được bảo toàn.
