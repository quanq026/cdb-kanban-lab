# infra

Script chạy trên VM hoặc từ máy local. Tất cả lệnh trong tài liệu giả định **root repo** là
working directory.

## Bảng tra nhanh

| Thư mục | Script | Việc |
|---|---|---|
| `db/` | `schema.sql` | DDL `users`/`tasks` (position + timestamps)/index/trigger + seed lab |
| `vm/` | `01-provision.sh` | swap 2 G, Docker, nginx, psql 17, venv |
| | `02-deploy-app.sh` | deploy app lần đầu (file đã scp vào `/tmp/*`) |
| | `03-fix-tls.sh` | trỏ `DB_SSLROOTCERT` sang CA bundle Ubuntu |
| `local/` | `01-init.sh` | tạo volume/container `cdb-study`, DB `studydb` |
| | `02-roles.sh` | tạo `app_user` least privilege + schema |
| | `03-verify.sh` | kiểm tra quyền, CRUD, TLS local |
| | `04-persistence.sh` | xoá/tạo lại container, giữ volume, so md5 |
| | `05-backup-restore.sh` | `pg_dump -Fc` + `pg_restore --exit-on-error` + đối chiếu |
| `neon/` | `01-restore.sh` | restore dump sang Neon, tạo `app_user` |
| | `02-verify.sh` | TLS verify-full, quyền, CRUD trên Neon |
| `https/` | `01-acme.sh` | webroot + location ACME HTTP-01 |
| | `02-cert.sh` | cài certbot, xin cert Let's Encrypt |
| | `03-nginx.sh` | server block 443 TLS 1.2/1.3 |
| | `04-renew-hook.sh` | deploy hook reload nginx sau gia hạn |
| | `05-hardening.sh` | redirect HTTPS, security header, ACME 80/443 |
| `deploy/` | `deploy.ps1` | local: upload app + nginx + chạy deploy trên VM |
| | `deploy-on-vm.sh` | backup, cài file, health-check, tự rollback |
| | `cdb-kanban.service` | systemd unit |
| | `nginx-cdb.conf` | reverse proxy :80/:443 |
| | `nginx-cloudflare-realip.conf` | `set_real_ip_from` + `CF-Connecting-IP` |
| `test/` | `app-tests.sh` | 108 case API, tự đăng ký/tự dọn |
| | `ui-shots.mjs` | 8 ảnh UI qua Chrome CDP |
| `maintenance/` | `auth-migrate.sh` | thêm `users.password_hash` (local + Neon) |
| | `auth-rollback.sh` | drop cột `password_hash` |
| | `auth-secret.sh` | thêm `APP_SECRET_KEY` nếu chưa có |
| | `schema-migrate.sh` | thêm `tasks.position`/`created_at`/`updated_at` + index/trigger |
| | `schema-rollback.sh` | drop 3 cột + trigger, trả index cũ |
| | `sql/2026-11-10-login*.sql` | DDL up/down chuẩn (login) |
| | `sql/2026-11-10-task-order*.sql` | DDL up/down chuẩn (position + timestamps) |
| | `purge-neon-demo.sh` | backup rồi xoá user/task demo trên Neon |
| | `purge-test-accounts.sh` | xoá `test-*`/`shot+*`/`verify+*` |
| | `idle-check.sh` | đo cold start sau khi Neon scale-to-zero |
| `tools/` | `run-remote.ps1` | copy script (chuẩn hoá LF) lên VM rồi `sudo bash` |

## Thứ tự dựng mới

```text
vm/01-provision.sh
local/01-init.sh → 02-roles.sh → 03-verify.sh → 04-persistence.sh → 05-backup-restore.sh
neon/01-restore.sh → 02-verify.sh
vm/02-deploy-app.sh → vm/03-fix-tls.sh
https/01-acme.sh → 02-cert.sh → 03-nginx.sh → 04-renew-hook.sh → 05-hardening.sh
```

Cập nhật app sau này chỉ cần `deploy/deploy.ps1`; migration dùng
`maintenance/auth-*` (login) và `maintenance/schema-*` (tasks).

## Quy ước

- Script `.sh` chạy bằng `bash` + `set -euo pipefail`; secret đọc từ
  `/etc/cdb/{secrets,app}.env`, không hardcode, không in ra.
- Script idempotent khi có thể (`IF NOT EXISTS`, `rm -f`, `|| true` cho lệnh đã chạy).
- Đường dẫn trong script là đường dẫn **trên VM**; script local dùng `$Root` tương đối.
- Không commit `.env*`, dump, key. Xem `.gitignore`.
