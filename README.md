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
    vm.sh                swap, nginx, psql 17, venv, systemd unit
    https.sh             Let's Encrypt + nginx TLS + renewal hook
  ops/
    deploy.sh            backup + install + health + rollback
    nginx-cdb.conf       reverse proxy :80/:443
    nginx-cloudflare-realip.conf
  migrations/            SQL migration up/down (đã áp dụng)

.github/
  workflows/ci.yml       Postgres 17 + smoke test + syntax/lint
  workflows/deploy.yml   self-hosted runner trên VM
  scripts/ci-smoke.py    59 case Flask test client

docs/
  architecture.md        Sơ đồ, thành phần, data model, luồng request
  api.md                 Hợp đồng API: endpoint, lỗi, validate, session
  operations.md          Deploy, rollback, migration, backup, TLS, cleanup
  security.md            Least privilege, secret, TLS, auth, đánh đổi
  testing.md             CI smoke + kiểm thử UI/hạ tầng
  runbook-manual.md      Việc phải làm tay trên VM/Neon/Cloudflare/Azure
```

## Chạy local

Yêu cầu: Python 3.12+ và **một Neon branch riêng cho dev** (không dùng chung branch
production, không trỏ dev vào DB production).

1. Trong Neon: `Branches → New branch` từ `main`, đặt tên `dev-<tên>`, rồi lấy host,
   role và password của branch đó.
2. Điền `.env`:

```bash
cp .env.example .env
# DB_HOST=<branch-id>.<region>.aws.neon.tech
# DB_NAME=studydb
# DB_USER=<role>
# DB_PASSWORD=<password>
# DB_SSLMODE=verify-full
```

3. Cài dependency, áp schema một lần cho branch mới, chạy app:

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate
# Linux/macOS: source .venv/bin/activate
pip install -r app/requirements.txt

set -a; . ./.env; set +a
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f infra/setup/schema.sql
gunicorn --chdir app --bind 127.0.0.1:8000 app:app
```

`DATABASE_URL` chỉ dùng cho `psql`, dạng
`postgresql://<role>:<password>@<host>/studydb?sslmode=verify-full`.

Mở <http://127.0.0.1:8000/>. App đọc biến trực tiếp từ process env, không tự nạp `.env`.
Tuỳ chọn tạm nếu không dùng Neon: `docker run ... postgres:17` (đặt `DB_SSLMODE=disable`).

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
- `app.py` gắn `?v=<sha1 8 ký tự>` vào `/app.css` và `/app.js` một lần lúc khởi động;
  deploy restart nên asset mới có URL mới (Cloudflare cache ~4 h).

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
| Việc phải chạy tay trên hạ tầng | [docs/runbook-manual.md](docs/runbook-manual.md) |

## Giới hạn

- Demo, không dùng cho dữ liệu thật: **không rate limit**, không CAPTCHA/2FA/xác thực
  email, không có luồng quên/đổi mật khẩu.
- Session là cookie ký phía client; logout chỉ xoá cookie hiện tại. Muốn thu hồi toàn bộ
  phải đổi `APP_SECRET_KEY` rồi restart.
- Chưa test mất toàn máy/PITR/failover; chưa có backup tự động.
- Migration thủ công; deploy không tự chạy DDL.
