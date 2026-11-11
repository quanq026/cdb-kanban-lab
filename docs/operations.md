# Vận hành

## 1. Truy cập & secret

| Mục | Giá trị |
|---|---|
| VM | `<VM_IP>` (SSH key-only, port 22 chỉ mở từ IP vận hành) |
| User deploy | `<deploy-user>` (thuộc group `docker`, chạy được `docker compose`) |
| App | container `cdb-app` từ image `ghcr.io/<owner>/cdb-kanban:<sha>` |
| Compose | `/opt/cdb/docker-compose.yml`, env `/opt/cdb/compose.env` (600), tag `/opt/cdb/current_tag` + `/opt/cdb/previous_tag` |
| Secret | `/etc/cdb/app.env` (container `env_file`) + `/etc/cdb/secrets.env` (owner) — 600 root |

`/etc/cdb/app.env` chứa `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`,
`DB_SSLMODE`, `DB_SSLROOTCERT`, `APP_SECRET_KEY`. Không commit file này; container chỉ
mount nó qua `env_file`, không bake vào image.

## 2. Deploy app

```text
push main ──► CI xanh (test + lint + build/scan image) ──► push GHCR <sha>
                    └─ xanh ──► Deploy (workflow_run)
                                   └─ runner tự host trên VM
                                        └─ sudo env IMAGE_TAG=<sha> IMAGE_REPO=<repo> \
                                             bash infra/ops/deploy.sh "$GITHUB_WORKSPACE"
```

`deploy.sh` (đọc `IMAGE_TAG` + `IMAGE_REPO`, `DOMAIN` tuỳ chọn):

1. Từ chối chạy nếu `cdb-kanban.service` còn active (cutover chưa xong) hoặc thiếu compose.
2. `docker pull "$IMAGE_REPO:$IMAGE_TAG"`.
3. Ghi `previous_tag` (tag đang chạy) rồi `current_tag`, và `/opt/cdb/compose.env`
   (`CDB_IMAGE`, `IMAGE_TAG`).
4. `docker compose up -d --remove-orphans` với `infra/ops/docker-compose.yml`.
5. Health-check 4 mức, retry 10×2 s: app `:8000`, nginx `:443 --resolve`, `/login`,
   `/register`. Fail → `trap ERR` đưa compose về `previous_tag` rồi exit 1.
6. Cài nginx conf + real IP, `nginx -t` trước khi reload.
7. Prune image cũ, giữ 3 tag gần nhất (luôn giữ `current_tag` + `previous_tag`).

Chạy tay khi cần (tag phải đã có trên GHCR, thường là SHA của commit đã qua CI):

```bash
sudo env IMAGE_REPO=ghcr.io/<owner>/cdb-kanban IMAGE_TAG=<sha> \
  bash infra/ops/deploy.sh "$PWD"
```

**Asset:** `app.py` gắn `?v=<sha1 8 ký tự>` vào `/app.css`/`/app.js` lúc khởi động;
container restart nên URL đổi khi nội dung đổi (Cloudflare cache ~4 h).

Kiểm tra sau deploy:

```bash
curl -sS https://kanban.akaine.io.vn/api/health
curl -sS -o /dev/null -w '%{http_code}\n' https://kanban.akaine.io.vn/login
sudo docker compose --env-file /opt/cdb/compose.env -f /opt/cdb/docker-compose.yml ps
cat /opt/cdb/current_tag /opt/cdb/previous_tag
sudo docker exec cdb-app python -c \
  'import urllib.request as u;print(u.urlopen("http://127.0.0.1:8000/api/health?detail=1").read().decode())'
```

`?detail=1` chỉ cho localhost, request từ host vào container bị 403; phải chạy bằng
`docker exec` như trên (từ trong container là `127.0.0.1`).

## 3. Rollback

### 3.1. Tự động

`deploy.sh` tự rollback khi health-check fail: đọc `/opt/cdb/previous_tag`, ghi lại
`compose.env`, `docker compose up -d` và kiểm tra health, rồi exit 1 (workflow đỏ).

### 3.2. Thủ công về tag trước

```bash
sudo cat /opt/cdb/previous_tag
sudo env IMAGE_REPO=ghcr.io/<owner>/cdb-kanban IMAGE_TAG="$(sudo cat /opt/cdb/previous_tag)" \
  bash infra/ops/deploy.sh "$PWD"
```

Hoặc chỉ đổi compose rồi up lại (không đụng nginx):

```bash
cd /opt/cdb
sudo sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$(cat previous_tag)/" compose.env
sudo docker compose --env-file compose.env -f docker-compose.yml up -d
```

Lưu ý: chạy `deploy.sh` cho tag cũ sẽ ghi đè `previous_tag` bằng tag đang chạy — nếu cần
giữ cả hai, chép `/opt/cdb/current_tag` trước khi rollback.

### 3.3. Xem và dọn image

```bash
sudo docker image ls ghcr.io/<owner>/cdb-kanban
sudo docker image rm ghcr.io/<owner>/cdb-kanban:<sha>   # tag không còn dùng
```

`deploy.sh` đã prune còn 3 tag; xoá tay chỉ khi cần giải phóng đĩa. Không xoá tag đang là
`current_tag`/`previous_tag`.

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
  `trg_tasks_updated_at`. Script từ chối chạy nếu `RESTORE_TEST_DSN` trùng DSN, trùng host,
  hoặc trùng tên database với `NEON_BACKUP_DSN`.
- Job `Check latest dump age`: cron hằng ngày 03:47 VN, fail nếu object `.dump` mới nhất cũ
  hơn 36 giờ, để phát hiện backup im lặng (job vẫn xanh nhưng không có bản mới).
- Fail → workflow đỏ (email GitHub). Nếu secret `NOTIFY_WEBHOOK` có giá trị thì gửi thêm
  POST JSON kiểu Discord (`{"content": "..."}`).
- Secret nằm trong GitHub Environment `backup`, không có trên VM: `NEON_BACKUP_DSN`,
  `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
  `RESTORE_TEST_DSN` (+ tuỳ chọn `NOTIFY_WEBHOOK`). VM chết vẫn backup/restore được.
- Backup trên VM chỉ còn lớp image/tag: `/opt/cdb/previous_tag` cho rollback code; không
  còn thư mục `backup-<stamp>` vì code nằm trong image immutable.

### 5.2. Lịch, retention, RPO/RTO

| Mục | Giá trị |
|---|---|
| Lịch dump | Hằng ngày 02:17 VN (cron `17 19 * * *` UTC) |
| Retention | `BACKUP_KEEP` bản `.dump` mới nhất, mặc định 14 (2 tuần); tính **mọi** bản trong bucket, kể cả `workflow_dispatch` chạy tay; mỗi bản có `.json` counts |
| RPO | ≤ 24 h (mất tối đa dữ liệu phát sinh từ bản dump gần nhất) |
| RTO | ~10–20 phút (restore vào branch mới, sửa `DB_HOST` trong `/etc/cdb/app.env`, `docker compose up -d --force-recreate`) |
| Phạm vi | Logical dump; **chưa** có PITR/WAL, **chưa** diễn tập mất toàn máy/failover |

Counts trong manifest lấy từ **cùng snapshot** với dump: `backup.sh` giữ một transaction
`REPEATABLE READ`, `pg_export_snapshot()`, rồi truyền snapshot đó cho `pg_dump --snapshot`
và cho hai câu `SELECT count(*)`. Vì vậy restore-test so sánh **bằng** (không có dung sai
chênh lệch); DSN backup phải dùng endpoint trực tiếp của Neon, không qua pooler.

Chốt an toàn trước khi prune (dump mới vẫn được giữ, chỉ bỏ bước prune và exit 1):
users = 0, hoặc users giảm còn dưới 50% so với manifest của bản trước. Workflow đỏ để
người dùng kiểm tra; bản dump mới vẫn nằm trên R2 nếu sau đó cần dùng.

Retention giữ N bản gần nhất thay vì 7 daily + 4 weekly vì dữ liệu nhỏ (dump vài trăm KB),
14 bản daily đã phủ 2 tuần và vẫn bắt được lỗi phát hiện muộn trong 1 tuần, không cần thêm
tầng thư mục và logic prune. Đổi bằng biến `BACKUP_KEEP` trong workflow.

GitHub tắt schedule sau 60 ngày repo không có hoạt động; workflow hẹn giờ khác cũng bị tắt
theo nên không tự keepalive được. Dùng external cron gọi `workflow_dispatch` (xem
[runbook-manual.md](runbook-manual.md) §2) hoặc kiểm tra thủ công hằng tháng.

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

Kiểm tra xong thì trỏ app sang branch mới: `sudoedit /etc/cdb/app.env` đổi `DB_HOST`, cập
nhật cả `/etc/cdb/secrets.env` (`NEON_HOST`) để lần `vm.sh` sau không ghi đè, rồi
`sudo docker compose --env-file /opt/cdb/compose.env -f /opt/cdb/docker-compose.yml up -d
--force-recreate` — hoặc promote branch. Không restore đè production đang chạy khi chưa có
branch dự phòng. Dump chứa dữ liệu thật: không commit, không để trong repo.

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

Guard DSN chặn cả trường hợp trùng **host** và trùng **tên database**, nên branch Neon
(mặc định dùng lại tên DB production) chưa đủ: tạo database riêng trong branch, ví dụ
`CREATE DATABASE restoretest;`, rồi đặt `RESTORE_TEST_DSN` dạng
`postgresql://<user>:<pass>@<branch-host>/restoretest`.

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
sudo docker compose --env-file /opt/cdb/compose.env -f /opt/cdb/docker-compose.yml down
sudo docker image rm $(sudo docker image ls ghcr.io/<owner>/cdb-kanban -q) 2>/dev/null || true
sudo rm -f /etc/cdb/app.env
sudo rm -f /etc/nginx/sites-enabled/cdb-kanban /etc/nginx/sites-available/cdb-kanban
sudo rm -f /etc/nginx/conf.d/cloudflare-realip.conf
sudo systemctl reload nginx
sudo rm -rf /opt/cdb
sudo rm -f /etc/cdb/secrets.env
```

Nếu VM còn di sản systemd của bản cũ: `sudo systemctl disable --now cdb-kanban` và
`sudo rm -f /etc/systemd/system/cdb-kanban.service /opt/cdb/venv` trước khi xoá `/opt/cdb`.

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
- `/api/health?detail=1` chỉ xem được từ localhost (SSH vào VM rồi `docker exec cdb-app
  python -c ...`, hoặc `ssh -L`).
- Image arm64 build trên runner `ubuntu-24.04-arm`; đĩa VM chứa tối đa 3 tag image (cộng
  base layer dùng chung), prune tự động sau mỗi deploy.
