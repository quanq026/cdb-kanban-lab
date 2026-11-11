# CDB Kanban

Ứng dụng Kanban nhỏ (Flask + PostgreSQL 17) chạy trên một VM, database là Neon
(managed Postgres), phía trước là nginx + Let's Encrypt + Cloudflare.

| | |
|---|---|
| Web | <https://kanban.akaine.io.vn/> |
| Health | <https://kanban.akaine.io.vn/api/health> |
| Stack | Flask 3.1 · psycopg 3.3 · PostgreSQL 17 · gunicorn · nginx |

## Kiến trúc

```
Browser ──HTTPS──► Cloudflare (proxy, SSL strict)
                        │ TLS 1.2/1.3
                        ▼
                   nginx :443 (VM) ──► gunicorn 127.0.0.1:8000 (Flask)
                                            │ psycopg_pool 1–5
                                            ▼
                             Neon PostgreSQL 17 "studydb" (verify-full)
```

App chỉ kết nối bằng role `app_user` least-privilege. Port `5432` không mở ra Internet.

## Cấu trúc repo

```
app/                     Ứng dụng (deploy vào /opt/cdb/app)
  app.py                 Flask API, pool, session, static + cache headers
  index.html             Board Kanban
  login.html             Đăng nhập
  register.html          Đăng ký
  app.css                CSS (light/dark, responsive)
  app.js                 Board, auth, optimistic update, drag & drop
  requirements.txt       Dependency pin

infra/
  setup/
    schema.sql           DDL users/tasks + index + trigger (CI dùng)
    vm.sh                swap, Docker, nginx, psql 17, venv, systemd unit
    https.sh             Let's Encrypt + nginx TLS + renewal hook
  ops/
    deploy.sh            backup + install + health + rollback
    nginx-cdb.conf       reverse proxy :80/:443
    nginx-cloudflare-realip.conf
  migrations/            SQL migration up/down (đã áp dụng)

.github/
  workflows/ci.yml       Postgres 17 + smoke test + syntax/lint
  workflows/deploy.yml   self-hosted runner trên VM
  scripts/ci-smoke.py    57 case Flask test client

docs/
  architecture.md        Sơ đồ, thành phần, data model, luồng request
  api.md                 Hợp đồng API: endpoint, lỗi, validate, session
  operations.md          Deploy, rollback, migration, backup, TLS, cleanup
  security.md            Least privilege, secret, TLS, auth, đánh đổi
  testing.md             CI smoke + kiểm thử UI/hạ tầng
```

## Chạy local

Yêu cầu: Python 3.12+, Docker (hoặc một Postgres 17 sẵn có).

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate
# Linux/macOS: source .venv/bin/activate
pip install -r app/requirements.txt

# Postgres 17 local
docker run -d --name cdb-local -p 127.0.0.1:5432:5432 \
  -e POSTGRES_PASSWORD=dev -e POSTGRES_DB=studydb postgres:17
PGPASSWORD=dev psql "host=127.0.0.1 port=5432 dbname=studydb user=postgres" \
  -f infra/setup/schema.sql

# Biến môi trường: copy rồi sửa cho local (DB_USER=postgres, DB_SSLMODE=disable)
cp .env.example .env
set -a; . ./.env; set +a

gunicorn --chdir app --bind 127.0.0.1:8000 app:app
```

Mở <http://127.0.0.1:8000/>. App đọc biến trực tiếp từ process env, không tự nạp `.env`.

## CI/CD

```text
push main ──► CI (ubuntu-latest): Postgres 17 + schema + ci-smoke.py + lint
                  └─ xanh ──► Deploy (self-hosted runner trên VM)
                                 └─ sudo bash infra/ops/deploy.sh "$GITHUB_WORKSPACE"
```

- `CI` chạy khi push/PR `main`: cài `app/requirements.txt`, áp `infra/setup/schema.sql`,
  `py_compile` / `node --check` / `bash -n` / shellcheck / ruff, rồi `ci-smoke.py`.
- `Deploy` chạy sau khi CI trên `main` xanh, qua runner `[self-hosted, cdb-vm]` (chỉ cần
  outbound HTTPS, không mở SSH cho GitHub).
- `deploy.sh` backup `/opt/cdb/app` + nginx conf vào `/opt/cdb/app/backup-<stamp>/`, cài
  file, `nginx -t`, reload, restart, health-check retry 10×2 s; lỗi → tự rollback.
- Mỗi lần đổi `app.css`/`app.js` phải tăng `?v=` trong **cả ba** HTML (Cloudflare cache
  asset ~4 h).

Chạy lại deploy thủ công:

```bash
gh workflow run deploy.yml --ref main
gh run watch
```

## Dựng production

```bash
git clone <repo-url> /opt/cdb/src && cd /opt/cdb/src
sudo install -d -m 700 /etc/cdb
sudoedit /etc/cdb/secrets.env     # NEON_HOST, NEON_APP_PASSWORD (+ owner DSN cho migration)
sudo bash infra/setup/vm.sh       # bootstrap VM, đọc app/requirements.txt
sudo bash infra/setup/https.sh    # DNS đã trỏ về VM, port 80/443 mở
sudo bash infra/ops/deploy.sh "$PWD"
```

`deploy.sh` đọc `APP_OWNER`, `APP_GROUP`, `DOMAIN` từ env nếu cần override; mặc định lấy
owner/group của `/opt/cdb/app` và domain trong script.

## Tài liệu

| Muốn biết | Đọc |
|---|---|
| Hệ thống ghép thế nào, schema ra sao | [docs/architecture.md](docs/architecture.md) |
| Gọi API nào, lỗi nào | [docs/api.md](docs/api.md) |
| Deploy / rollback / migration / dọn tài nguyên | [docs/operations.md](docs/operations.md) |
| Mô hình bảo mật và đánh đổi | [docs/security.md](docs/security.md) |
| Test gì, chạy sao | [docs/testing.md](docs/testing.md) |

## Giới hạn

- Demo, không dùng cho dữ liệu thật: **không rate limit**, không CAPTCHA/2FA/xác thực
  email, không có luồng quên/đổi mật khẩu.
- Session là cookie ký phía client; logout chỉ xoá cookie hiện tại. Muốn thu hồi toàn bộ
  phải đổi `APP_SECRET_KEY` rồi restart.
- Chưa test mất toàn máy/PITR/failover; dump nằm cùng VM.
- Migration thủ công; deploy không tự chạy DDL.
