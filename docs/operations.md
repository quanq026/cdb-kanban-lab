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

### 5.1. Kiến trúc

Workflow `backup.yml` chạy trên GitHub-hosted `ubuntu-latest`, không phụ thuộc VM:

```text
Neon production ──pg_dump -Fc──► cdb-<stamp>.dump + .json (row counts) ──aws s3──► R2 cdb/
```

- Job `Backup`: cron hằng ngày 19:17 UTC (02:17 VN) và `workflow_dispatch`; dump, kiểm tra
  `pg_restore -l` đọc được, upload dump + manifest counts, prune bản cũ.
- Job `Restore newest dump`: cron thứ Hai 03:17 UTC (10:17 VN) hoặc `workflow_dispatch` với
  input `restore_test`; tải bản mới nhất, restore vào `RESTORE_TEST_DSN`, so counts với
  manifest và kiểm tra index `idx_tasks_user_status_position` + trigger
  `trg_tasks_updated_at`. Script từ chối chạy nếu `RESTORE_TEST_DSN` trùng
  `NEON_BACKUP_DSN`.
- Fail → workflow đỏ (email GitHub). Nếu secret `NOTIFY_WEBHOOK` có giá trị thì gửi thêm
  POST JSON kiểu Discord (`{"content": "..."}`).
- Secret nằm trong GitHub Environment `backup`, không có trên VM: `NEON_BACKUP_DSN`,
  `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
  `RESTORE_TEST_DSN` (+ tuỳ chọn `NOTIFY_WEBHOOK`). VM chết vẫn backup/restore được.
- `deploy.sh` vẫn backup app + nginx conf vào `/opt/cdb/app/backup-<stamp>/` trên VM; bản
  đó chỉ để rollback code, không thay thế backup DB.

### 5.2. Lịch, retention, RPO/RTO

| Mục | Giá trị |
|---|---|
| Lịch dump | Hằng ngày 02:17 VN (cron `17 19 * * *` UTC) |
| Retention | `BACKUP_KEEP` bản mới nhất, mặc định 14 (2 tuần); mỗi bản có `.json` counts |
| RPO | ≤ 24 h (mất tối đa dữ liệu phát sinh từ bản dump gần nhất) |
| RTO | ~10–20 phút (restore vào branch mới, đổi `NEON_HOST`, restart app) |
| Phạm vi | Logical dump; **chưa** có PITR/WAL, **chưa** diễn tập mất toàn máy/failover |

Giữ N bản gần nhất thay vì 7 daily + 4 weekly vì dữ liệu nhỏ (dump vài trăm KB), 14 bản
daily đã phủ 2 tuần và vẫn bắt được lỗi phát hiện muộn trong 1 tuần, không cần thêm tầng
thư mục và logic prune. Đổi bằng biến `BACKUP_KEEP` trong workflow.

### 5.3. Restore thủ công

```bash
export R2_ENDPOINT='https://<account-id>.r2.cloudflarestorage.com'
export R2_BUCKET='<bucket>'
export AWS_ACCESS_KEY_ID='<key>' AWS_SECRET_ACCESS_KEY='<secret>'

aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://$R2_BUCKET/cdb/"
aws --endpoint-url "$R2_ENDPOINT" s3 cp \
  "s3://$R2_BUCKET/cdb/cdb-<stamp>.dump" ./restore.dump
aws --endpoint-url "$R2_ENDPOINT" s3 cp \
  "s3://$R2_BUCKET/cdb/cdb-<stamp>.json" ./cdb-<stamp>.json   # counts lúc dump

# Tạo Neon branch mới từ main, dùng DSN role owner của branch đó
pg_restore --exit-on-error --no-owner --no-privileges --clean --if-exists \
  -d "$TARGET_DSN" ./restore.dump
psql "$TARGET_DSN" -c 'SELECT count(*) FROM users' -c 'SELECT count(*) FROM tasks'
rm -f ./restore.dump ./cdb-<stamp>.json
```

Kiểm tra xong thì trỏ app sang branch mới (`/etc/cdb/secrets.env` → `NEON_HOST`) rồi
`sudo systemctl restart cdb-kanban`, hoặc promote branch. Không restore đè production đang
chạy khi chưa có branch dự phòng. Dump chứa dữ liệu thật: không commit, không để trong repo.

### 5.4. Chạy restore test

```bash
gh workflow run backup.yml --ref main -f restore_test=true
gh run watch
```

Hoặc chạy tay trên máy có `psql` 17 + `awscli`:

```bash
export NEON_BACKUP_DSN='postgresql://...' RESTORE_TEST_DSN='postgresql://...'
export R2_ENDPOINT='https://<account-id>.r2.cloudflarestorage.com' R2_BUCKET='<bucket>'
export R2_ACCESS_KEY_ID='<key>' R2_SECRET_ACCESS_KEY='<secret>'
bash infra/ops/restore-test.sh
```

In từng bước `PASS`/`FAIL`, exit code 1 nếu lệch counts hoặc thiếu index/trigger.

Trạng thái diễn tập thật: **[chưa chạy]** — điền ngày + kết quả sau lần chạy đầu tiên.

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
- Backup logical hằng ngày lên R2 (RPO ≤ 24 h), restore test hằng tuần; chưa có PITR và
  chưa diễn tập mất toàn máy/failover.
- Cert phụ thuộc `certbot.timer`; VM tắt quá lâu có thể hết hạn.
- Không rate limit (xem [security.md](security.md) §6).
- `/api/health?detail=1` chỉ xem được từ localhost (SSH vào VM hoặc `ssh -L`).
