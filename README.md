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
                   nginx :443 (VM) ──► 127.0.0.1:8000
                                            │ container cdb-app (gunicorn + Flask)
                                            │ psycopg_pool 1–5
                                            ▼
                             Neon PostgreSQL 17 "studydb" (verify-full)
```

App chạy trong container non-root `cdb-app` (image `ghcr.io/<owner>/cdb-kanban:<sha>`), chỉ
publish `127.0.0.1:8000`. App kết nối bằng role `app_user` least-privilege; port `5432`
không mở ra Internet.

## Cấu trúc repo

```
Dockerfile               image runtime (python:3.12-slim, non-root, healthcheck)
.dockerignore
app/                     Ứng dụng (copy vào /app trong image)
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
    vm.sh                swap, nginx, psql 17, Docker + compose, docker group
    https.sh             Let's Encrypt + nginx TLS + renewal hook
  ops/
    deploy.sh            pull image + compose up + health + rollback theo tag
    docker-compose.yml   service app, bind 127.0.0.1:8000, read-only, log rotate
    backup.sh            pg_dump Neon -> R2 + prune (chạy trên GitHub Actions)
    restore-test.sh      restore bản mới nhất vào DB tạm + kiểm tra
    nginx-cdb.conf       reverse proxy :80/:443
    nginx-cloudflare-realip.conf
  migrations/            SQL migration up/down (đã áp dụng)

.github/
  workflows/ci.yml       test Postgres 17 + lint + build/scan/push image arm64
  workflows/backup.yml   backup Neon ra R2 hằng ngày + restore test hằng tuần
  workflows/deploy.yml   self-hosted runner trên VM, deploy theo tag SHA
  dependabot.yml         pip, github-actions, docker (hằng tuần)
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

Yêu cầu: Python 3.12+ và **Neon branch schema-only** cho dev. Không dùng branch copy từ
`main` có dữ liệu: branch đó chứa email và password hash production.

1. Neon: `Branches → New branch`, chọn `Schema only`, đặt tên `dev-<tên>`, rồi lấy host,
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

3. Cài dependency và chạy app (branch schema-only đã có bảng, không cần áp `schema.sql`):

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate
# Linux/macOS: source .venv/bin/activate
pip install -r app/requirements.txt

set -a; . ./.env; set +a
gunicorn --chdir app --bind 127.0.0.1:8000 app:app
```

Nếu dùng project/DB trống thay vì branch schema-only, áp schema một lần:
`psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f infra/setup/schema.sql` — file này có seed và
không idempotent, chỉ áp lên DB trống.

`DATABASE_URL` chỉ dùng cho `psql`, dạng
`postgresql://<role>:<password>@<host>/studydb?sslmode=verify-full`. Password có ký tự đặc
biệt phải URL-encode trong URL (`@` → `%40`, `:` → `%3A`, `/` → `%2F`); `DB_PASSWORD` giữ
nguyên, không encode.

Mở <http://127.0.0.1:8000/>. App đọc biến trực tiếp từ process env, không tự nạp `.env`.

## CI/CD

```text
push main ──► CI (ubuntu-latest): test Postgres 17 + lint
                  └─ Image (ubuntu-24.04-arm): hadolint + build arm64 + trivy
                       └─ push main: ghcr.io/<owner>/cdb-kanban:<sha> (+ latest)
                  └─ xanh ──► Deploy (self-hosted runner trên VM)
                                 └─ docker pull <sha> → compose up → health
```

- `CI` chạy khi push/PR `main`: test + lint, cùng một job `Image (linux/arm64)` build
  `python:3.12-slim`, chạy `hadolint`, `trivy` (fail HIGH/CRITICAL có bản vá), chỉ push
  GHCR khi push `main`. PR chỉ build, không push.
- `Deploy` chạy sau khi **toàn bộ** CI trên `main` xanh, qua runner `[self-hosted, cdb-vm]`
  (chỉ cần outbound HTTPS, không mở SSH cho GitHub).
- `deploy.sh` pull tag SHA, ghi `/opt/cdb/current_tag` + `previous_tag`, `docker compose up -d`,
  cài nginx conf, `nginx -t`, reload, health-check 10×2 s; lỗi → quay lại `previous_tag`
  rồi exit 1. Image cũ được prune, giữ 3 tag gần nhất.
- `Backup` chạy hằng ngày 02:17 VN trên `ubuntu-latest`: dump Neon, đẩy dump + manifest
  counts lên R2, prune còn 14 bản; thứ Hai 10:17 VN restore bản mới nhất vào DB tạm để
  kiểm tra; 03:47 VN hằng ngày kiểm bản mới nhất không cũ quá 36 h
  (xem [docs/operations.md §5](docs/operations.md)).
- `app.py` gắn `?v=<sha1 8 ký tự>` vào `/app.css` và `/app.js` một lần lúc khởi động;
  container restart nên asset mới có URL mới (Cloudflare cache ~4 h).

Chạy lại deploy thủ công (tag phải là SHA đã build thành công):

```bash
gh workflow run deploy.yml --ref main
gh run watch
```

## Dựng production

```bash
git clone <repo-url> /opt/cdb/src && cd /opt/cdb/src
sudo install -d -m 700 /etc/cdb
sudoedit /etc/cdb/secrets.env     # NEON_HOST, NEON_APP_PASSWORD (+ owner DSN cho migration)
sudo bash infra/setup/vm.sh       # swap, nginx, psql client, Docker + compose
sudo bash infra/setup/https.sh    # DNS đã trỏ về VM, port 80/443 mở
```

Sau đó làm checklist cutover trong [docs/runbook-manual.md](docs/runbook-manual.md) §3
(đăng nhập GHCR thử, chạy container trên cổng 8001, rồi mới tắt `cdb-kanban.service`),
rồi deploy lần đầu bằng tag có thật:

```bash
gh workflow run deploy.yml --ref main
```

`deploy.sh` nhận `IMAGE_TAG` (bắt buộc) và `IMAGE_REPO` (bắt buộc), `DOMAIN` tuỳ chọn;
`IMAGE_REPO` mặc định trên workflow là `ghcr.io/<owner>/cdb-kanban`.

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
- Chưa diễn tập mất toàn máy/failover; backup là logical dump hằng ngày (RPO ≤ 24 h), không
  có PITR. Xem [docs/operations.md §5](docs/operations.md).
- Migration thủ công; deploy không tự chạy DDL.
