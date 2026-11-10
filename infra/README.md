# infra

Script chạy trên VM hoặc từ máy local. Tất cả lệnh trong tài liệu giả định **root repo** là
working directory.

## Cấu trúc

```text
infra/
  setup/        chạy MỘT LẦN khi dựng hạ tầng mới
  ops/          dùng THƯỜNG XUYÊN (deploy, migration, purge, chạy script từ xa)
```

## `setup/` — dựng lần đầu

| Thư mục | Script | Việc |
|---|---|---|
| `setup/db/` | `schema.sql` | DDL `users`/`tasks` (position + timestamps)/index/trigger + seed lab |
| `setup/vm/` | `01-provision.sh` | swap 2 G, Docker, nginx, psql 17, venv |
| | `02-deploy-app.sh` | deploy app lần đầu (file đã scp vào `/tmp/*`) |
| | `03-fix-tls.sh` | trỏ `DB_SSLROOTCERT` sang CA bundle Ubuntu |
| | `cdb-kanban.service` | systemd unit |
| `setup/local/` | `01-init.sh` | tạo volume/container `cdb-study`, DB `studydb` |
| | `02-roles.sh` | tạo `app_user` least privilege + schema |
| | `03-verify.sh` | kiểm tra quyền, CRUD, TLS local |
| | `04-persistence.sh` | xoá/tạo lại container, giữ volume, so md5 |
| | `05-backup-restore.sh` | `pg_dump -Fc` + `pg_restore --exit-on-error` + đối chiếu |
| `setup/neon/` | `01-restore.sh` | restore dump sang Neon, tạo `app_user` |
| | `02-verify.sh` | TLS verify-full, quyền, CRUD trên Neon |
| `setup/https/` | `01-acme.sh` | webroot + location ACME HTTP-01 |
| | `02-cert.sh` | cài certbot, xin cert Let's Encrypt |
| | `03-nginx.sh` | server block 443 TLS 1.2/1.3 |
| | `04-renew-hook.sh` | deploy hook reload nginx sau gia hạn |
| | `05-hardening.sh` | redirect HTTPS, security header, ACME 80/443 |

Thứ tự dựng mới:

```text
setup/vm/01-provision.sh
setup/local/01-init.sh → 02-roles.sh → 03-verify.sh → 04-persistence.sh → 05-backup-restore.sh
setup/neon/01-restore.sh → 02-verify.sh
setup/vm/02-deploy-app.sh → 03-fix-tls.sh
setup/https/01-acme.sh → 02-cert.sh → 03-nginx.sh → 04-renew-hook.sh → 05-hardening.sh
```

## `ops/` — dùng thường xuyên

| Script | Việc |
|---|---|
| `deploy.sh` | VM: backup, cài app + nginx conf, health-check (retry), tự rollback |
| `nginx-cdb.conf` | reverse proxy :80/:443 |
| `nginx-cloudflare-realip.conf` | `set_real_ip_from` + `CF-Connecting-IP` |
| `run-remote.ps1` | copy script (chuẩn hoá LF) lên VM rồi `sudo bash` |
| `maintenance/auth-migrate.sh` | thêm `users.password_hash` (local + Neon) |
| `maintenance/auth-rollback.sh` | drop cột `password_hash` |
| `maintenance/auth-secret.sh` | thêm `APP_SECRET_KEY` nếu chưa có |
| `maintenance/schema-migrate.sh` | thêm `tasks.position`/`created_at`/`updated_at` + index/trigger |
| `maintenance/schema-rollback.sh` | drop 3 cột + trigger, trả index cũ |
| `maintenance/sql/*.sql` | DDL up/down chuẩn (login, task-order) |
| `maintenance/purge-neon-demo.sh` | backup rồi xoá user/task demo trên Neon |
| `maintenance/purge-test-accounts.sh` | xoá `test-*`/`shot+*`/`verify+*` |
| `maintenance/idle-check.sh` | đo cold start sau khi Neon scale-to-zero |

Deploy thường ngày: push `main` → GitHub Actions `CI` → `Deploy`. Chạy lại thủ công:

```powershell
gh workflow run deploy.yml --ref main
```

Hoặc trên VM khi đã có checkout: `sudo bash infra/ops/deploy.sh "$PWD"`.

## Test

Bộ test thủ công cũ (`app-tests.sh`, `ui-shots.mjs`, `ui-drag-check.mjs`) đã được xoá khỏi
repo để tinh gọn; kết quả lịch sử ở [../docs/evidence/](../docs/evidence/) và git history.
Test tự động duy nhất hiện tại là `.github/scripts/ci-smoke.py` (57 case), chạy trong
`.github/workflows/ci.yml`.

## Quy ước

- Script `.sh` chạy bằng `bash` + `set -euo pipefail`; secret đọc từ
  `/etc/cdb/{secrets,app}.env`, không hardcode, không in ra.
- Script idempotent khi có thể (`IF NOT EXISTS`, `rm -f`, `|| true` cho lệnh đã chạy).
- Đường dẫn trong script là đường dẫn **trên VM**.
- Không commit `.env*`, dump, key. Xem `.gitignore`.
