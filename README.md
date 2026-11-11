# CDB Kanban

Ứng dụng Kanban nhỏ (Flask + PostgreSQL 17) tinh gọn, chạy trọn gói trên bất kỳ VPS nào qua Docker Compose (bao gồm App, PostgreSQL 17 và Caddy tự động cấp SSL). Cắm là chạy (Plug & Play), không cần cấu hình database hay dịch vụ bên ngoài.

| | |
|---|---|
| Web demo | `https://<your-domain>/` |
| Health check | `https://<your-domain>/api/health` |
| Stack | Flask 3.1 · psycopg 3.3 · PostgreSQL 17 · gunicorn · Caddy · Docker |

## Bắt đầu nhanh

**Yêu cầu:** VPS (Ubuntu/Debian) đã cài Docker & Docker Compose, 1 domain trỏ về IP VPS.

### 4 bước triển khai:
1. Clone repo: `git clone <repo-url> && cd cdb-kanban-lab`
2. Tạo file cấu hình: `cp .env.example .env`
   - Điền `DOMAIN=<your-domain.com>`
   - Sinh mã bí mật bằng `openssl rand -hex 32` rồi điền vào `APP_SECRET_KEY`
   *(Database PostgreSQL 17 nội bộ đã được cấu hình tự động sẵn trong Docker, không cần cài đặt hay chạy lệnh SQL gì thêm).*
3. Khởi chạy: `docker compose up -d --build`
4. Mở trình duyệt truy cập `https://<your-domain.com>` (Caddy tự cấp phát SSL Let's Encrypt, Postgres tự khởi tạo bảng).

> [!TIP]
> **Đổi mật khẩu DB (tùy chọn):** Mật khẩu DB nội bộ đã được cấu hình mặc định sẵn. Nếu muốn đổi, hãy bỏ comment `DB_PASSWORD=<mật khẩu>` trong `.env` **trước** lần `docker compose up` đầu tiên (vì Postgres chỉ nhận mật khẩu khi khởi tạo volume lần đầu). Nếu đã khởi chạy trước đó, bạn có 2 cách:
> 1. Chạy `docker compose down -v` (xoá dữ liệu) rồi up lại; hoặc
> 2. Đổi mật khẩu trực tiếp: `docker exec -it cdb-db psql -U app_user -d studydb -c "ALTER USER app_user PASSWORD '<mật khẩu mới>'"` rồi cập nhật `DB_PASSWORD` trong `.env` và chạy `docker compose up -d`.

> [!NOTE]
> **Dùng Database bên ngoài (PostgreSQL độc lập / Neon):**
> Điền các thông số kết nối vào `.env`: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` và `DB_SSLMODE=verify-full` (hoặc `require`). Sau đó khởi chạy mà không cần bật service db nội bộ bằng tùy chọn `--no-deps`:
> ```bash
> docker compose up -d --no-deps --build app caddy
> ```

### Cập nhật khi có bản mới:
```bash
git pull && docker compose up -d --build
```

### Xử lý sự cố thường gặp:
- **Không mở được web / Timeout:** Đảm bảo VPS đã mở cổng 80 và 443 (`sudo ufw allow 80,443/tcp` và cấu hình Security Group/Firewall của VPS).
- **Lỗi chứng chỉ SSL:** Đảm bảo bản ghi DNS (A/AAAA) đã trỏ đúng về IP VPS trước khi chạy compose để Caddy cấp chứng chỉ.
- **Nếu dùng Cloudflare Proxy:** Đặt SSL/TLS ở chế độ **Full (strict)** để tránh lỗi vòng lặp chuyển hướng (301 redirect loop).

Chi tiết vận hành nâng cao và bảo mật xem tại thư mục [docs/](docs/).

---

## Cấu trúc repo

```
Caddyfile                Reverse proxy Caddy + tự cấp SSL tự động
docker-compose.yml       Compose trọn gói (app + db + caddy) cho mọi VPS
Dockerfile               Image runtime (python:3.12-slim, non-root, healthcheck)
.dockerignore
.env.example

app/                     Mã nguồn ứng dụng
  app.py                 Flask API, connection pool, session, static & headers
  index.html             Board Kanban
  login.html             Đăng nhập
  register.html          Đăng ký
  app.css                CSS (light/dark, responsive)
  app.js                 Board, auth, optimistic update, drag & drop
  requirements.txt       Dependency pin

infra/
  setup/
    schema.sql           DDL users/tasks + index + trigger

.github/
  workflows/ci.yml       Test Postgres 17 + lint + actionlint + docker build
  dependabot.yml         pip, github-actions, docker (hằng tuần)
  scripts/ci-smoke.py    59 case Flask test client

docs/                    Tài liệu chi tiết hệ thống
```

## Chạy local dev

Yêu cầu: Python 3.12+ và database Postgres 17 (hoặc chạy `docker compose up db -d`).

1. Điền `.env`:
   ```bash
   cp .env.example .env
   # Điền DOMAIN=localhost và APP_SECRET_KEY
   ```
2. Cài dependency và chạy app:
   ```bash
   python -m venv .venv
   # Windows: .venv\Scripts\activate
   # Linux/macOS: source .venv/bin/activate
   pip install -r app/requirements.txt

   # Nạp env và chạy
   gunicorn --chdir app --bind 127.0.0.1:8000 app:app
   ```
3. Mở <http://127.0.0.1:8000/>.

## CI/CD

- **CI (`.github/workflows/ci.yml`):** Tự động kích hoạt khi push/PR `main`: khởi động container service Postgres 17, nạp `schema.sql`, kiểm tra syntax (`py_compile`, `node --check`), chạy lint (`ruff`, `actionlint`), chạy 59 test cases smoke test và kiểm tra build image (`hadolint`, `docker build`).

## Tài liệu

| Muốn biết | Đọc |
|---|---|
| Hệ thống ghép thế nào, schema ra sao | [docs/architecture.md](docs/architecture.md) |
| Gọi API nào, mã lỗi nào | [docs/api.md](docs/api.md) |
| Vận hành và bảo mật | [docs/operations.md](docs/operations.md) · [docs/security.md](docs/security.md) |
| Kiểm thử và test cases | [docs/testing.md](docs/testing.md) |

## Giới hạn

- Demo, không dùng cho dữ liệu thực tế nhạy cảm: **không rate limit tầng app**, không CAPTCHA/2FA/xác thực email.
- **Không có cơ chế sao lưu tự động (No backup)**: Đây là bản demo dữ liệu tinh gọn. Dữ liệu chỉ tồn tại trong Docker volume `db_data`; mất volume hoặc VPS là mất dữ liệu. Lệnh `docker compose down -v` xoá sạch dữ liệu (còn `docker compose down` thì giữ).
- Session cookie ký phía client (`HttpOnly`, `SameSite=Lax`, `Secure`); đổi `APP_SECRET_KEY` sẽ thu hồi toàn bộ session.
- Migration database chạy thủ công bằng psql; deploy không tự ý chạy DDL.
