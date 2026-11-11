# Kiểm thử

Tài liệu hướng dẫn quy trình kiểm thử tự động trong CI/CD, kiểm thử thủ công và kiểm thử hạ tầng cho dự án **CDB Kanban**.

---

## 1. Kiểm thử tự động trên CI (GitHub Actions)

Bộ kiểm thử tự động được cấu hình trong file `.github/workflows/ci.yml`, tự động kích hoạt trên mỗi `push` vào nhánh `main` và trên mọi `pull_request`.

| Hạng mục | Công cụ / Môi trường | Chi tiết kiểm tra |
|---|---|---|
| **Database Service** | `postgres:17` (Docker container) | Khởi tạo service DB, nạp `infra/setup/schema.sql` |
| **Kiểm tra cú pháp** | `python -m py_compile`, `node --check` | Đảm bảo không có lỗi cú pháp trong `app/app.py`, `app/app.js` và `ci-smoke.py` |
| **Linting code** | `ruff check app .github/scripts` | Kiểm tra chuẩn code Python, phát hiện biến thừa, import không dùng, v.v. |
| **Linting Workflow** | `actionlint` | Kiểm tra tính đúng đắn của các file GitHub Actions workflow |
| **Smoke Tests** | `python .github/scripts/ci-smoke.py` | **59 test cases** chạy qua Flask Test Client (59 PASS / 0 FAIL) |
| **Container Build & Scan** | Docker build & `trivy` | Đóng gói image Docker trên kiến trúc ARM64 và quét lỗ hổng bảo mật (CVE) |

---

## 2. Chạy kiểm thử tự động ở máy Local

Bạn có thể chạy toàn bộ 59 ca kiểm thử khói (smoke test) ngay trên máy phát triển của mình:

### Bước 1: Khởi động container PostgreSQL nội bộ
```bash
docker compose up db -d
```
Container `cdb-db` sẽ khởi động và nạp sẵn schema bảng dữ liệu.

### Bước 2: Thiết lập môi trường và chạy test
```bash
# Cài đặt thư viện (nếu chưa cài)
python -m venv .venv
source .venv/bin/activate  # Trên Windows: .venv\Scripts\activate
pip install -r app/requirements.txt

# Thiết lập biến môi trường trỏ vào DB container
export DB_HOST=127.0.0.1
export DB_PORT=5432
export DB_NAME=studydb
export DB_USER=app_user
export DB_PASSWORD=<mat-khau-db>
export DB_SSLMODE=disable
export APP_SECRET_KEY=local-test-secret-key-32-chars-long

# Chạy smoke test
python .github/scripts/ci-smoke.py
```
Kết quả mong đợi: Toàn bộ 59 test cases đều in `PASS` và kết thúc với `no leftover ci-* users`.

---

## 3. Kiểm thử giao diện người dùng (UI Checklist)

| Kịch bản kiểm thử | Thao tác thực hiện | Kết quả kỳ vọng |
|---|---|---|
| **Chưa đăng nhập** | Truy cập `https://<domain>/` | Tự động chuyển hướng (302) về `/login`, không lộ bảng Kanban |
| **Đăng ký tài khoản** | Nhập email và mật khẩu ≥ 8 ký tự | Đăng ký thành công (201), tự động chuyển vào trang chủ với bảng trống |
| **Xác thực mật khẩu yếu** | Nhập mật khẩu < 8 ký tự hoặc nhập lại không khớp | Form chặn ngay ở trình duyệt, hiển thị thông báo lỗi rõ ràng |
| **Đăng nhập** | Nhập email và mật khẩu đúng | Đăng nhập thành công, hiển thị đúng email ở menu góc phải |
| **Đổi giao diện (Theme)** | Nhấn nút icon ◐ ở topbar | Chuyển đổi mượt mà giữa chế độ Tự động → Sáng → Tối |
| **Thêm công việc** | Nhấn phím tắt `N` hoặc nút "Thêm việc" | Dialog mở ra; nhập tiêu đề và Enter tạo thẻ mới ở đầu cột "Todo" |
| **Kéo thả / Đổi cột** | Kéo thẻ từ "Todo" sang "Doing" hoặc "Done" | Thẻ di chuyển mượt mà, vị trí và trạng thái được lưu bền vững khi F5 |
| **Đổi thứ tự trong cột** | Dùng nút mũi tên ↑ / ↓ hoặc kéo thẻ đổi vị trí | Thứ tự `position` được cập nhật liên tục |
| **Xóa công việc** | Nhấn icon xóa thùng rác | Hiển thị hộp thoại xác nhận trước khi xóa vĩnh viễn |
| **Đăng xuất** | Mở menu tài khoản → Nhấn "Đăng xuất" | Xóa cookie phiên đăng nhập và chuyển hướng về trang `/login` |

---

## 4. Kiểm thử hạ tầng & Triển khai thực tế

| Hạng mục kiểm tra | Lệnh thực hiện | Kết quả kỳ vọng |
|---|---|---|
| **Health Check công khai** | `curl -sS https://<domain>/api/health` | `{"db_user":"app_user","ok":true,"status":"ok"}` |
| **Health Check chi tiết (Localhost)** | `curl -sS http://127.0.0.1:8000/api/health?detail=1` | Trả về thông tin chi tiết (`database`, `backend_addr`, `db_host`, `sslmode`) |
| **Chứng chỉ TLS / HTTPS** | `curl -Iv https://<domain>/` | Bắt tay TLS thành công (TLS 1.2 / TLS 1.3), chứng chỉ Let's Encrypt hợp lệ |
| **Cổng database không lộ** | `nc -zv <IP-VPS> 5432` hoặc `Test-NetConnection` | Bị từ chối kết nối (Connection refused / Timeout) từ bên ngoài Internet |
| **Bảo toàn dữ liệu qua Restart** | Tạo task mới → Chạy `docker compose restart` → F5 trang web | Toàn bộ dữ liệu vẫn nguyên vẹn do được lưu trong volume `db_data` |
