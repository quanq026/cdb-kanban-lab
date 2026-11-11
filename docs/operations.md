# Vận hành

## 1. Truy cập & secret

| Mục | Giá trị |
|---|---|
| VM | `<VM_IP>` (SSH key-only, port 22 chỉ mở từ IP vận hành) |
| User deploy | `<deploy-user>` (owner của `/opt/cdb/app`) |
| App | `/opt/cdb/app`, venv `/opt/cdb/venv`, systemd `cdb-kanban`, nginx site `cdb-kanban` |
| Secret | `/etc/cdb/app.env` (app) + `/etc/cdb/secrets.env` (owner) — 600 root |

`/etc/cdb/app.env` chứa `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`,
`DB_SSLMODE`, `DB_SSLROOTCERT`, `APP_SECRET_KEY`. Không commit file này.

## 2. Deploy app

```text
push main ──► CI xanh ──► Deploy (workflow_run)
                              └─ runner tự host trên VM
                                   └─ sudo bash infra/ops/deploy.sh "$GITHUB_WORKSPACE"
```

`deploy.sh`:

1. Backup `/opt/cdb/app` + nginx conf vào `/opt/cdb/app/backup-<stamp>/`.
2. Cài `app/*` + `infra/ops/nginx-*.conf`, `nginx -t`, reload nginx, restart `cdb-kanban`.
3. Health-check 3 mức, retry 10×2 s: app `:8000`, nginx `:443 --resolve`, `/login`,
   `/register`. Bất kỳ bước nào fail → `trap ERR` khôi phục backup.

Chạy trực tiếp trên VM khi có checkout:

```bash
sudo bash infra/ops/deploy.sh "$PWD"
```

Override khi cần: `APP_OWNER`, `APP_GROUP`, `DOMAIN` (mặc định lấy owner/group của
`/opt/cdb/app` và domain trong script).

**Asset:** `app.py` gắn `?v=<sha1 8 ký tự>` vào `/app.css`/`/app.js` lúc khởi động;
deploy restart nên URL đổi khi nội dung đổi (Cloudflare cache ~4 h).

Kiểm tra sau deploy:

```bash
curl -sS https://kanban.akaine.io.vn/api/health
curl -sS -o /dev/null -w '%{http_code}\n' https://kanban.akaine.io.vn/login
sudo systemctl is-active cdb-kanban
```

## 3. Rollback

### 3.1. Tự động

`deploy.sh` tự rollback khi lỗi. Backup gần nhất:

```bash
ls -1 /opt/cdb/app/backup-*
```

### 3.2. Thủ công về một backup

```bash
B=/opt/cdb/app/backup-<stamp>
OWNER=$(stat -c %U /opt/cdb/app)
GROUP=$(stat -c %G /opt/cdb/app)
sudo install -m 644 -o "$OWNER" -g "$GROUP" "$B/app.py" /opt/cdb/app/app.py
sudo install -m 644 -o "$OWNER" -g "$GROUP" "$B/index.html" /opt/cdb/app/index.html
# nếu backup có: app.css, app.js, login.html, register.html
sudo rm -rf /opt/cdb/app/__pycache__
sudo systemctl restart cdb-kanban
```

Khôi phục nginx + real IP:

```bash
sudo install -m 644 "$B/cdb-kanban.conf" /etc/nginx/sites-available/cdb-kanban
sudo install -m 644 "$B/cloudflare-realip.conf" /etc/nginx/conf.d/cloudflare-realip.conf
sudo nginx -t && sudo systemctl reload nginx
```

## 4. Migration database

Hai migration đã áp dụng; deploy **không** tự chạy DDL.

| Thay đổi | Up / down |
|---|---|
| `users.password_hash` | `infra/migrations/2026-11-10-login.sql` / `...-login-rollback.sql` |
| `tasks.position`, `created_at`, `updated_at` | `infra/migrations/2026-11-10-task-order.sql` / `...-task-order-rollback.sql` |

Áp dụng thủ công bằng role owner:

```bash
psql "$DSN" -v ON_ERROR_STOP=1 -f infra/migrations/2026-11-10-task-order.sql
```

`2026-11-10-task-order.sql` additive + idempotent: thêm cột, backfill `position` theo `id`,
đặt `NOT NULL`/default, đổi index, tạo trigger `trg_tasks_updated_at`. Bản rollback chỉ
đụng bảng `tasks`, không đụng `users`.

`infra/setup/schema.sql` có seed dữ liệu mẫu và không idempotent — chỉ áp lên DB trống.

## 5. Backup & restore

| Việc | Cách làm |
|---|---|
| Backup app | Tự động mỗi lần deploy: `/opt/cdb/app/backup-*` |
| Dump Neon | `pg_dump -Fc "$NEON_DSN" > backup.dump` |
| Restore Neon | `pg_restore --exit-on-error --no-owner --no-privileges -d "$NEON_DSN" backup.dump` |
| Backup định kỳ | **Chưa bật** — Neon Free không có PITR dài; dump thủ công khi cần |

Dump chứa dữ liệu thật: không commit, không để trong repo.

## 6. TLS & domain

| Mục | Giá trị |
|---|---|
| Cert origin | `/etc/letsencrypt/live/kanban.akaine.io.vn/` |
| Gia hạn | `certbot.timer` + deploy hook reload nginx |
| ACME | HTTP-01 webroot `/var/www/letsencrypt` |
| Cloudflare | `ssl=strict`, `min_tls_version=1.2`, `always_use_https=on`, HTTP/3 + Brotli |
| Header | HSTS 180 ngày, nosniff, SAMEORIGIN, Referrer-Policy, Permissions-Policy |

Đổi domain: sửa cả biến `DOMAIN` (`deploy.yml` hoặc env khi chạy tay) và
`infra/ops/nginx-cdb.conf` (redirect, `server_name`, đường dẫn cert), rồi chạy lại
`infra/setup/https.sh`.

```bash
sudo certbot certificates
sudo certbot renew --dry-run
systemctl list-timers 'certbot*'
```

Nếu IP VM đổi: cập nhật DNS/Origin Rule ở Cloudflare. Nếu IP vận hành đổi: cập nhật NSG
rule SSH.

## 7. Cleanup / decommission

> **Không chạy khi còn demo.** Đây là hướng dẫn, không phải script tự động.

### 7.1. Azure

```bash
az resource list -g <resource-group> -o table
az vm deallocate -g <resource-group> -n <vm-name>
az group delete -n <resource-group> --yes --no-wait
```

### 7.2. Neon

```bash
psql "$NEON_OWNER_DSN" -c 'DROP DATABASE IF EXISTS studydb'
psql "$NEON_OWNER_DSN" -c 'DROP ROLE IF EXISTS app_user'
```

Chỉ xoá DB/role của project này; không xoá project dùng chung.

### 7.3. VM

```bash
sudo systemctl disable --now cdb-kanban
sudo rm -f /etc/systemd/system/cdb-kanban.service /etc/cdb/app.env
sudo rm -f /etc/nginx/sites-enabled/cdb-kanban /etc/nginx/sites-available/cdb-kanban
sudo rm -f /etc/nginx/conf.d/cloudflare-realip.conf
sudo systemctl daemon-reload && sudo systemctl reload nginx
sudo rm -rf /opt/cdb
sudo rm -f /etc/cdb/secrets.env
```

### 7.4. TLS/certbot

```bash
sudo certbot delete --cert-name kanban.akaine.io.vn
sudo systemctl disable --now certbot.timer
sudo apt-get remove -y certbot
sudo rm -rf /var/www/letsencrypt
```

Sau đó tắt proxy/xoá bản ghi DNS `kanban`, nếu không Cloudflare trả 521/522.

### 7.5. Rollback Cloudflare (nếu cần)

```bash
ZONE=<CF_ZONE_ID>
curl -sS -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE/settings/ssl" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"value":"full"}'
curl -sS -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE/settings/min_tls_version" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"value":"1.0"}'
```

HSTS đã xuống browser (180 ngày): rollback server **không** xoá HSTS cache. Vì vậy không
bật `includeSubDomains`/`preload`.

### 7.6. Kiểm tra tài nguyên còn sót

| Loại | Lệnh |
|---|---|
| VM | `az vm list -g <resource-group> -d -o table` |
| Static IP | `az network public-ip list -o table` (vẫn tính phí dù không gắn) |
| Disk | `az disk list -o table` |
| Snapshot | `az snapshot list -o table` |
| NIC / NSG / VNet | `az network nic list` / `nsg list` / `vnet list` |
| Resource group | `az group list -o table` |
| Neon | `psql "$NEON_OWNER_DSN" -c '\l'` |
| Cert | `sudo certbot certificates`, `systemctl list-timers 'certbot*'` |
| DNS | dashboard Cloudflare |

## 8. Chi phí & giới hạn vận hành

- VM + IP + disk ≈ **$44.30/tháng** nếu chạy 24/7; deallocate sau demo.
- Neon Free scale-to-zero sau 5 phút: request đầu sau idle ~1.9–3.1 s; pool có
  `check_connection` + retry nên không trả 500/503.
- Chưa có backup định kỳ/PITR/failover.
- Cert phụ thuộc `certbot.timer`; VM tắt quá lâu có thể hết hạn.
- Không rate limit (xem [security.md](security.md) §6).
- `/api/health?detail=1` chỉ xem được từ localhost (SSH vào VM hoặc `ssh -L`).
