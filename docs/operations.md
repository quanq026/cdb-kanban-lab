# Vận hành

> Tất cả lệnh chạy từ **root repo**. Không chạy mục 7 (cleanup) khi còn demo.

## 1. Truy cập & secret

| Mục | Giá trị |
|---|---|
| Web | `https://kanban.akaine.io.vn/` · `/login` · `/register` |
| Health | `https://kanban.akaine.io.vn/api/health` · chi tiết: `curl http://127.0.0.1:8000/api/health?detail=1` trên VM |
| VM | `azureuser@20.48.104.156`, key `~/.ssh/id_rsa_azure`, chỉ từ IP hiện tại |
| App | `/opt/cdb/app`, venv `/opt/cdb/venv`, service `cdb-kanban` |
| Log | `sudo journalctl -u cdb-kanban -f` |
| Secret app | `/etc/cdb/app.env` (600 root): `DB_*` + `APP_SECRET_KEY` |
| Secret lab/owner | `/etc/cdb/secrets.env` (600 root): mật khẩu local, owner Neon, API key |
| Secret local | `.env` / `.env.azure` (gitignored) — **không** commit, không in ra output |

`infra/tools/run-remote.ps1` chuẩn hoá CRLF → LF rồi `scp` + `ssh sudo bash`; dùng nó
thay vì nhét lệnh vào chuỗi `ssh "..."` (PowerShell hiểu `||`, `$`, quote rất khác).

## 2. Deploy app

### 2.1. Dựng hạ tầng từ đầu (chỉ lần đầu)

Hiện tại VM đã tồn tại — bỏ qua mục này nếu chỉ cập nhật app. Bản ghi đầy đủ:

```powershell
az group create -n rg-demo -l japaneast
az vm create -g rg-demo -n vm-cdb `
  --image Canonical:ubuntu-24_04-lts:server-arm64:latest `
  --size Standard_B2pls_v2 --nics nic-demo --admin-username azureuser `
  --ssh-key-values "$env:USERPROFILE\.ssh\id_rsa_azure.pub" --authentication-type ssh `
  --os-disk-size-gb 30 --storage-sku StandardSSD_LRS
```

Sau đó mở NSG 80/443 public, 22 chỉ từ IP hiện tại (không mở 5432), rồi:

```powershell
powershell -File infra\tools\run-remote.ps1 -Path infra\vm\01-provision.sh
```

### 2.2. Cập nhật app

```powershell
powershell -File infra\deploy\deploy.ps1              # đầy đủ
powershell -File infra\deploy\deploy.ps1 -SkipIndex   # chỉ backend/asset, giữ index.html trên VM
```

Luồng:

1. `scp` `app/app.py`, `app/index.html`, `app/app.css`, `app/app.js`, `app/login.html`,
   `app/register.html`, `infra/deploy/nginx-cdb.conf`, `nginx-cloudflare-realip.conf` lên `/tmp/*.new`.
2. `scp` `infra/deploy/deploy-on-vm.sh` → `/tmp/deploy.sh`.
3. Trên VM: backup vào `/opt/cdb/app/backup-YYYY-MM-DD[-HHMMSS]/`, cài file, `nginx -t`,
   reload nginx, restart `cdb-kanban`.
4. Health-check 3 mức: app trực tiếp `:8000`, qua nginx `:443 --resolve`, `/login`,
   `/register`. Bất kỳ bước nào fail → `trap ERR` khôi phục backup và reload.

**Bắt buộc:** mỗi lần sửa `app.css`/`app.js`, tăng `?v=` trong `app/index.html`,
`app/login.html`, `app/register.html` (hiện `?v=20261110i`). Cloudflare cache asset ~4 h,
origin `no-cache` không đủ.

Kiểm tra sau deploy:

```bash
curl -sS https://kanban.akaine.io.vn/api/health
curl -sS -o /dev/null -w '%{http_code}\n' https://kanban.akaine.io.vn/login
sudo systemctl is-active cdb-kanban
```

## 3. Rollback

### 3.1. Rollback tự động

`deploy-on-vm.sh` tự rollback nếu lỗi. Backup gần nhất:

```bash
ls -1 /opt/cdb/app/backup-*
```

### 3.2. Rollback thủ công về một backup

```bash
B=/opt/cdb/app/backup-2026-11-10-065537
sudo install -m 644 -o azureuser -g azureuser "$B/app.py" /opt/cdb/app/app.py
sudo install -m 644 -o azureuser -g azureuser "$B/index.html" /opt/cdb/app/index.html
# nếu backup có: app.css, app.js, login.html, register.html
sudo rm -rf /opt/cdb/app/__pycache__
sudo systemctl restart cdb-kanban
```

Nếu cần bỏ real IP/CSP (quay về nginx trước GĐ A):

```bash
sudo install -m 644 "$B/cdb-kanban.conf" /etc/nginx/sites-available/cdb-kanban
sudo rm -f /etc/nginx/conf.d/cloudflare-realip.conf
sudo nginx -t && sudo systemctl reload nginx
```

### 3.3. Rollback phần login (GĐ C)

```powershell
powershell -File infra\tools\run-remote.ps1 -Path infra\maintenance\auth-rollback.sh
```

Sau đó:

```bash
sudo sed -i '/^APP_SECRET_KEY=/d' /etc/cdb/app.env
sudo rm -f /opt/cdb/app/login.html
# khôi phục app.py/index.html từ backup ngay trước bản login
sudo systemctl restart cdb-kanban
```

`auth-rollback.sh` chỉ `DROP COLUMN IF EXISTS users.password_hash`; **không** đụng bảng
khác. Đã diễn tập rollback trong transaction local: `after_drop=0` → `ROLLBACK` →
`after_rollback=1`.

Lưu ý: UI mới gọi `DELETE /api/tasks/<id>?user_id=`; `app.py` cũ đọc `user_id` từ body.
Rollback phải khôi phục **cả `app.py` và `index.html`**.

### 3.4. Rollback phần đăng ký + purge demo

```powershell
powershell -File infra\tools\run-remote.ps1 -Path infra\maintenance\purge-test-accounts.sh
```

Tắt đăng ký công khai: khôi phục `app.py`/`index.html`/`login.html` từ backup trước bản
register, xoá `register.html`, restart. Dữ liệu demo (nếu thật sự cần) phục hồi từ
`/home/azureuser/neon-demo-purge-2026-11-10-062210.sql` (xem [evidence/auth.md](evidence/auth.md)).

### 3.5. Rollback schema tasks (GĐ C)

```powershell
powershell -File infra\tools\run-remote.ps1 -Path infra\maintenance\schema-rollback.sh
```

Script chỉ trên bảng `tasks`: drop trigger + function, drop 3 cột mới, tạo lại
`idx_tasks_user_status`; **không** đụng `users`/`password_hash`. App mới phải được rollback
về bản cũ **trước** (hoặc cùng lúc) vì code mới đọc `position`/`created_at`/`updated_at`.

## 4. Migration database

Hai migration GĐ C, đều chạy giống local Docker và Neon bằng role owner:

| Migration | Up / down | Runner |
|---|---|---|
| `users.password_hash` | `sql/2026-11-10-login.sql` / `...-login-rollback.sql` | `auth-migrate.sh` / `auth-rollback.sh` |
| `tasks.position`, `created_at`, `updated_at` | `sql/2026-11-10-task-order.sql` / `...-task-order-rollback.sql` | `schema-migrate.sh` / `schema-rollback.sh` |

```powershell
powershell -File infra\tools\run-remote.ps1 -Path infra\maintenance\auth-migrate.sh
powershell -File infra\tools\run-remote.ps1 -Path infra\maintenance\schema-migrate.sh
```

- `schema-migrate.sh` là **additive + idempotent**: thêm cột, backfill `position` theo `id`,
  đặt `NOT NULL`/default, đổi index, tạo trigger `trg_tasks_updated_at`. App cũ vẫn chạy
  được trong lúc migrate (INSERT cũ nhận `position` default 0).
- Script tự kiểm tra `app_user` đọc/ghi được cột mới + trigger bằng một transaction
  `INSERT/UPDATE ... ROLLBACK`, rồi in index/trigger thật.
- `schema-rollback.sh` đã diễn tập trong transaction local:
  up → `position_nulls=0`, index mới + trigger hiện diện → down → `down_columns=0`,
  index cũ quay lại → `ROLLBACK` không để lại thay đổi.
- `app_user` giữ nguyên quyền mức bảng; không cấp thêm. Trigger chạy không cần `EXECUTE`
  riêng cho `app_user` (đã xác nhận bằng transaction ở trên).
- Secret ký session: `infra/maintenance/auth-secret.sh` thêm `APP_SECRET_KEY` vào
  `/etc/cdb/app.env` nếu chưa có (không in giá trị).

## 5. Backup, restore, purge

| Việc | Cách làm |
|---|---|
| Dump local (lab) | `infra/local/05-backup-restore.sh` → `/home/azureuser/studydb-lab.dump` |
| Restore sang Neon | `infra/neon/01-restore.sh` (pg_restore `--no-owner --no-privileges`) |
| Kiểm tra Neon | `infra/neon/02-verify.sh` (TLS, quyền, CRUD) |
| Backup trước purge | `/home/azureuser/neon-demo-purge-<stamp>.sql` (data-only, column-inserts) |
| Purge demo | `infra/maintenance/purge-neon-demo.sh` — backup rồi xoá task → user trên Neon |
| Dọn tài khoản test | `infra/maintenance/purge-test-accounts.sh` — `test-*`, `shot+*`, `verify+*` |
| Backup app | Tự động mỗi lần deploy: `/opt/cdb/app/backup-*` |
| Backup Neon định kỳ | **Chưa bật** — Neon Free không có PITR dài; dump thủ công khi cần |

Purge **không** đụng schema: `users`/`tasks` (kể cả `password_hash`, `position`, timestamp)
giữ nguyên, chỉ xoá row. Production hiện `users=1` (tài khoản thật) `tasks=16` (16 việc mẫu); local docker
vẫn giữ seed 2 user / 5 task.

## 6. TLS & domain

| Mục | Giá trị |
|---|---|
| Cert origin | `/etc/letsencrypt/live/kanban.akaine.io.vn/`, hạn 2027-02-07 |
| Gia hạn | `certbot.timer`; deploy hook `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` |
| ACME | HTTP-01 webroot `/var/www/letsencrypt`, location `^~ /.well-known/acme-challenge/` |
| Cloudflare | `ssl=strict`, `min_tls_version=1.2`, `always_use_https=on`, HTTP/3 + Brotli |
| Header | HSTS 180 ngày (không includeSubDomains/preload), nosniff, SAMEORIGIN, Referrer-Policy, Permissions-Policy |

```bash
sudo certbot certificates
sudo certbot renew --dry-run
systemctl list-timers 'certbot*'
```

Nếu IP VM đổi: cập nhật DNS/Origin Rule ở Cloudflare; `http://20.48.104.156/` chỉ còn 301.
Nếu IP nhà đổi: cập nhật NSG rule `Allow-SSH`.

## 7. Cleanup / decommission

> **Không chạy khi còn demo.** Đây là hướng dẫn, không phải script tự động.

### 7.1. Azure

```bash
az resource list -g rg-demo -o table          # xem trước
az vm deallocate -g rg-demo -n vm-cdb         # dừng compute, giữ đĩa/IP (~$6.05/tháng)
az group delete -n rg-demo --yes --no-wait    # xoá toàn bộ
```

### 7.2. Neon

```bash
# Chỉ xoá DB của lab, GIỮ project (project thuộc org Vercel, dùng chung)
psql "host=<endpoint> dbname=postgres user=neondb_owner sslmode=verify-full sslrootcert=system" \
  -c 'DROP DATABASE IF EXISTS studydb'
psql "..." -c 'DROP ROLE IF EXISTS app_user'
```

Không xoá project `neon-cyclamen-chair`/`icy-sound-48483515` — không phải tài nguyên lab.

### 7.3. VM

```bash
sudo systemctl disable --now cdb-kanban
sudo rm -f /etc/systemd/system/cdb-kanban.service /etc/cdb/app.env
sudo rm -f /etc/nginx/sites-enabled/cdb-kanban /etc/nginx/sites-available/cdb-kanban
sudo rm -f /etc/nginx/conf.d/cloudflare-realip.conf
sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
sudo systemctl daemon-reload && sudo systemctl reload nginx
sudo rm -rf /opt/cdb
docker rm -f cdb-study
docker volume rm cdb-study-data     # mất dữ liệu local, không phục hồi
rm -f /home/azureuser/studydb-lab.dump
sudo rm -f /etc/cdb/secrets.env /etc/cdb/demo-login.txt
```

### 7.4. TLS/certbot

```bash
sudo certbot delete --cert-name kanban.akaine.io.vn
sudo systemctl disable --now certbot.timer
sudo apt-get remove -y certbot
sudo rm -rf /var/www/letsencrypt
# sudo rm -rf /etc/letsencrypt /var/log/letsencrypt   # nếu chắc chắn không dùng lại
```

Sau đó tắt proxy/xoá bản ghi DNS `kanban`, nếu không Cloudflare trả 521/522.

### 7.5. Rollback Cloudflare (chỉ zone `akaine.io.vn`)

```bash
ZONE=fc94e4214166b8219e611c7129d37cf8
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
| VM | `az vm list -g rg-demo -d -o table` |
| Static IP | `az network public-ip list -o table` (vẫn tính phí dù không gắn) |
| Disk | `az disk list -o table` |
| Snapshot | `az snapshot list -o table` |
| NIC / NSG / VNet | `az network nic list` / `nsg list` / `vnet list` |
| Resource group | `az group list -o table` (`NetworkWatcherRG` do Azure tạo, không đáng kể) |
| Neon | `psql ... -c '\l'` |
| Docker | `docker ps -a`, `docker volume ls` |
| Cert | `sudo certbot certificates`, `systemctl list-timers 'certbot*'` |
| DNS | dashboard Cloudflare |

**Thứ tự an toàn:** chụp/dump bằng chứng → `az vm deallocate` → drop `studydb` (giữ
project) → `az group delete -n rg-demo --yes` → kiểm tra bảng trên.

## 8. Chi phí & giới hạn vận hành

- VM + IP + disk ≈ **$44.30/tháng** nếu chạy 24/7; 8 giờ demo ≈ $0.49. Ngưỡng $10 bị vượt
  sau ~7 ngày. Chi tiết: [evidence/cloud.md](evidence/cloud.md).
- Neon Free scale-to-zero sau 5 phút: request đầu sau idle ~1.9–3.1 s; pool có
  `check_connection` + retry nên không trả 500/503.
- Chưa có backup định kỳ/PITR/failover; dump nằm cùng VM.
- Cert phụ thuộc `certbot.timer`; VM tắt quá lâu có thể hết hạn.
- Không rate limit (xem [security.md](security.md) §6).
- `?detail=1` chỉ xem được từ localhost (SSH vào VM hoặc `ssh -L`).
