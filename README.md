# CDB Kanban

Ứng dụng Kanban nhỏ (Flask + PostgreSQL 17) chạy trên một VM Azure, database là Neon
(managed Postgres), phía trước là nginx + Let's Encrypt + Cloudflare.

| | |
|---|---|
| Web | <https://kanban.akaine.io.vn/> |
| Health | <https://kanban.akaine.io.vn/api/health> |
| Stack | Flask 3.1 · psycopg 3.3 · PostgreSQL 17 · gunicorn · nginx · Docker |

## Kiến trúc

```
Browser ──HTTPS──► Cloudflare (proxy, SSL strict)
                        │ TLS 1.2/1.3
                        ▼
                   nginx :443 (VM Azure) ──► gunicorn 127.0.0.1:8000 (Flask)
                                                   │ psycopg_pool 1–5
                                                   ▼
                                    Neon PostgreSQL 17 "studydb" (verify-full)
```

VM còn chạy container `postgres:17` tại `127.0.0.1:55432` làm nguồn dump cho lab.
App production chỉ nói chuyện với Neon.

## Cấu trúc repo

```
app/                     Ứng dụng (deploy vào /opt/cdb/app)
  app.py                 Flask API, pool, session, static + cache headers
  index.html             Board Kanban
  login.html             Đăng nhập
  register.html          Đăng ký
  app.css                CSS (light/dark, responsive)
  app.js                 Board, auth, optimistic update, drag & drop

infra/
  setup/                 Chạy MỘT LẦN khi dựng mới
    schema.sql           DDL users/tasks + index + trigger
    vm.sh                swap, Docker, nginx, psql 17, venv, systemd unit
    local-db.sh          Postgres 17 trong Docker + app_user
    neon.sh              restore dump sang Neon + app_user
    https.sh             Let's Encrypt + nginx TLS + renewal hook
  ops/                   Dùng THƯỜNG XUYÊN
    deploy.sh            backup + install + health + rollback
    nginx-cdb.conf       reverse proxy :80/:443
    nginx-cloudflare-realip.conf
    run-remote.ps1       copy script LF lên VM rồi chạy bằng sudo
    maintenance/         auth-*, schema-*, purge-*, idle-check, sql/

.github/
  workflows/ci.yml       Postgres 17 + smoke test + syntax
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

## Dựng mới

Yêu cầu: Azure CLI đã đăng nhập, SSH key `~/.ssh/id_rsa_azure`, PowerShell. Chạy từ
**root repo**.

```powershell
# 1. Chuẩn bị secrets trên VM (không commit): /etc/cdb/secrets.env
#    NEON_HOST, NEON_APP_PASSWORD, NEON_OWNER_USER, NEON_OWNER_PASSWORD,
#    PG_SUPER_PASSWORD, LOCAL_APP_PASSWORD

# 2. Bootstrap VM: swap, Docker, nginx, psql 17, venv, systemd unit
powershell -File infra\ops\run-remote.ps1 -Path infra\setup\vm.sh

# 3. (Tuỳ chọn) Postgres local trong Docker
scp -i $env:USERPROFILE\.ssh\id_rsa_azure infra\setup\schema.sql `
  azureuser@20.48.104.156:/opt/cdb/schema.sql
powershell -File infra\ops\run-remote.ps1 -Path infra\setup\local-db.sh

# 4. (Tuỳ chọn) Restore dump sang Neon
powershell -File infra\ops\run-remote.ps1 -Path infra\setup\neon.sh

# 5. HTTPS (DNS đã trỏ về VM, port 80/443 mở)
powershell -File infra\ops\run-remote.ps1 -Path infra\setup\https.sh

# 6. Deploy app lần đầu từ checkout trên VM
sudo bash infra/ops/deploy.sh "$PWD"
```

Các lần sau chỉ cần push `main`: `CI` xanh → `Deploy` chạy tự động qua self-hosted
runner `cdb-vm`.

```powershell
gh workflow run deploy.yml --ref main   # chạy lại thủ công
gh run watch
```

`infra/ops/deploy.sh` backup bản cũ vào `/opt/cdb/app/backup-YYYY-MM-DD[-HHMMSS]/`
trước khi ghi đè; nếu `nginx -t` fail, service không lên hoặc health-check fail (retry
10 lần) thì tự khôi phục. Mỗi lần đổi `app.css`/`app.js` phải tăng `?v=` trong **cả ba**
HTML vì Cloudflare cache asset tĩnh (~4 h).

## Cấu hình production

| Thành phần | Giá trị |
|---|---|
| VM | `20.48.104.156` · japaneast · `Standard_B2pls_v2` (Arm64, 2 vCPU / 4 GiB) · Ubuntu 24.04 |
| App | `/opt/cdb/app`, venv `/opt/cdb/venv`, systemd `cdb-kanban`, nginx site `cdb-kanban` |
| Neon | DB `studydb`, role `app_user`, endpoint trực tiếp (không `-pooler`) |
| TLS origin | Let's Encrypt `CN=kanban.akaine.io.vn`, tự gia hạn `certbot.timer` |
| Secret | `/etc/cdb/app.env` (app) + `/etc/cdb/secrets.env` (owner) — **không** trong repo |
| DB local | container `cdb-study`, volume `cdb-study-data`, `127.0.0.1:55432` |

## Tài liệu

| Muốn biết | Đọc |
|---|---|
| Hệ thống ghép thế nào, schema ra sao | [docs/architecture.md](docs/architecture.md) |
| Gọi API nào, lỗi nào | [docs/api.md](docs/api.md) |
| Deploy / rollback / migration / dọn tài nguyên | [docs/operations.md](docs/operations.md) |
| Mô hình bảo mật và đánh đổi | [docs/security.md](docs/security.md) |
| Test gì, chạy sao | [docs/testing.md](docs/testing.md) |

## Phạm vi & giới hạn

- Demo, không dùng cho dữ liệu thật: **không rate limit**, không CAPTCHA/2FA/xác thực
  email, không có luồng quên/đổi mật khẩu.
- Session là cookie ký phía client; logout chỉ xoá cookie hiện tại. Muốn thu hồi toàn bộ
  phải đổi `APP_SECRET_KEY` rồi restart.
- Chưa test mất toàn máy/PITR/failover; dump nằm cùng VM.
- Migration thủ công; deploy không tự chạy DDL.
