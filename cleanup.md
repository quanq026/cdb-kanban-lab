# Cleanup — dọn tài nguyên

> **KHÔNG chạy các lệnh dưới đây khi còn cần demo.** Đây là hướng dẫn dọn dẹp, không phải script tự động.

## 1. Dọn Azure

```bash
# Xem trước những gì sẽ mất
az resource list -g rg-demo -o table

# Xoá toàn bộ (VM, NIC, IP, NSG, VNet, đĩa OS)
az group delete -n rg-demo --yes --no-wait

# Hoặc chỉ tạm dừng VM, giữ đĩa/IP để bật lại nhanh
az vm deallocate -g rg-demo -n vm-cdb
```

## 2. Dọn Neon

```bash
# Chỉ xoá database của lab, GIỮ project (project thuộc org Vercel, dùng chung)
psql "host=<endpoint> dbname=postgres user=neondb_owner sslmode=verify-full sslrootcert=system" \
  -c 'DROP DATABASE IF EXISTS studydb'

# Xoá role app_user (sau khi đã drop database)
psql "host=<endpoint> dbname=postgres user=neondb_owner sslmode=verify-full sslrootcert=system" \
  -c 'DROP ROLE IF EXISTS app_user'
```

**Không xoá project `neon-cyclamen-chair`** — project này có từ trước (do Vercel tạo), không phải tài nguyên của lab.

## 3. Dọn trên VM (nếu chỉ muốn xoá phần lab)

```bash
sudo systemctl disable --now cdb-kanban
sudo rm -f /etc/systemd/system/cdb-kanban.service /etc/cdb/app.env
sudo rm -f /etc/nginx/sites-enabled/cdb-kanban /etc/nginx/sites-available/cdb-kanban
sudo rm -f /etc/nginx/conf.d/cloudflare-realip.conf
sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
sudo systemctl daemon-reload && sudo systemctl reload nginx
sudo rm -rf /opt/cdb
docker rm -f cdb-study
docker volume rm cdb-study-data     # xoá dữ liệu local, không thể phục hồi
rm -f /home/azureuser/studydb-lab.dump
sudo rm -f /etc/cdb/secrets.env
# /etc/cdb/demo-login.txt đã bị xoá khi purge demo; rm -f để idempotent
sudo rm -f /etc/cdb/demo-login.txt
```

## 3b. Gỡ TLS/certbot (nếu dọn sạch domain)

```bash
sudo certbot delete --cert-name kanban.akaine.io.vn
sudo systemctl disable --now certbot.timer
sudo apt-get remove -y certbot
sudo rm -rf /var/www/letsencrypt
# /etc/letsencrypt còn account + renewal config; xoá nếu chắc chắn không dùng lại:
# sudo rm -rf /etc/letsencrypt /var/log/letsencrypt
```

Sau khi gỡ, DNS `kanban.akaine.io.vn` nên tắt proxy Cloudflare hoặc xoá bản ghi, nếu không Cloudflare sẽ trả 521/522.

## 3c. Rollback cấu hình Cloudflare (chỉ zone `akaine.io.vn`)

Nếu cần quay lại trạng thái trước hardening (dùng token CF, không in token):

```bash
ZONE=fc94e4214166b8219e611c7129d37cf8
curl -sS -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE/settings/ssl" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"value":"full"}'
curl -sS -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE/settings/min_tls_version" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"value":"1.0"}'
```

Lưu ý: HSTS đã đẩy xuống browser với `max-age=15552000` — rollback phía server **không** xoá HSTS trong browser đã truy cập; phải chờ hết hạn hoặc xoá HSTS cache. Vì vậy đừng bật `includeSubDomains`/`preload` nếu chưa chắc.

## 3d. Rollback app về bản trước GĐ A/B/B+/login

Mỗi lần deploy, `infra/app-deploy.sh` copy bản cũ vào `/opt/cdb/app/backup-YYYY-MM-DD[-HHMMSS]/`:

```bash
ls -1 /opt/cdb/app/backup-*
# chọn bản muốn quay lại, ví dụ bản gốc trước GĐ A:
B=/opt/cdb/app/backup-2026-11-10
sudo install -m 644 -o azureuser -g azureuser "$B/app.py" /opt/cdb/app/app.py
sudo install -m 644 -o azureuser -g azureuser "$B/index.html" /opt/cdb/app/index.html
# bản backup GĐ A/B có app.css, app.js; bản gốc thì không cần
sudo rm -rf /opt/cdb/app/__pycache__
sudo systemctl restart cdb-kanban
```

Nếu cần bỏ luôn phần real IP/CSP (quay về nginx trước GĐ A):

```bash
sudo install -m 644 "/opt/cdb/app/backup-2026-11-10/cdb-kanban.conf" /etc/nginx/sites-available/cdb-kanban
sudo rm -f /etc/nginx/conf.d/cloudflare-realip.conf
sudo nginx -t && sudo systemctl reload nginx
```

### Rollback riêng phần login (GĐ C)

Chỉ cần khi muốn bỏ xác thực và quay về bản chưa có login:

```bash
# 1. Bỏ cột hash trên local docker + Neon (idempotent)
powershell -File scripts\run-remote.ps1 -Path infra\login-rollback.sh

# 2. Gỡ secret + trang login, khôi phục app cũ
sudo sed -i '/^APP_SECRET_KEY=/d' /etc/cdb/app.env
sudo rm -f /opt/cdb/app/login.html
# app.py/index.html: dùng backup ngay trước bản login (xem $B ở trên)
sudo systemctl restart cdb-kanban
```

`login-rollback.sh` chỉ `DROP COLUMN IF EXISTS users.password_hash`; **không** đụng bảng `tasks`/`users` khác. Đã diễn tập rollback trong transaction trên local: `after_drop=0` → `ROLLBACK` → `after_rollback=1`.

Lưu ý: UI mới gọi `DELETE /api/tasks/<id>?user_id=`; `app.py` cũ đọc `user_id` từ body. Vì vậy rollback phải khôi phục **cả `app.py` và `index.html`** (bản gốc self-contained, không dùng `app.css`/`app.js`). `app.css`/`app.js` còn trên đĩa cũng không ảnh hưởng vì `index.html` cũ không tham chiếu.

### Rollback riêng phần đăng ký + purge demo

```bash
# 1. Dọn tài khoản test/evidence còn sót (test-*/shot+*/verify+*)
powershell -File scripts\run-remote.ps1 -Path infra\purge-test-accounts.sh

# 2. Tắt đăng ký công khai: khôi phục app.py/index.html/login.html từ backup ngay trước bản register
#    (backup mới nhất có register.html; chọn backup trước đó), rồi:
sudo rm -f /opt/cdb/app/register.html
sudo rm -rf /opt/cdb/app/__pycache__
sudo systemctl restart cdb-kanban
```

- Khôi phục dữ liệu demo (nếu thật sự cần): xem `evidence/cleanup-register.md` §5, dùng `neon-demo-purge-2026-11-10-062210.sql`.
- Purge demo **không** đụng schema: `users`/`tasks`/`password_hash` giữ nguyên, chỉ xoá row.
- Backup Neon nằm trên VM tại `/home/azureuser/neon-demo-purge-*.sql`; tải về trước khi xoá VM nếu muốn giữ.

## 4. Kiểm tra tài nguyên còn sót

| Loại | Lệnh kiểm tra | Ghi chú |
|---|---|---|
| VM | `az vm list -g rg-demo -d -o table` | phải rỗng sau khi xoá RG |
| Static public IP | `az network public-ip list -o table` | IP tĩnh vẫn tính phí dù không gắn VM |
| Managed disk | `az disk list -o table` | đĩa OS còn lại nếu chỉ xoá VM |
| Snapshot | `az snapshot list -o table` | lab không tạo snapshot |
| NIC | `az network nic list -o table` | NIC mồ côi |
| NSG / VNet | `az network nsg list` / `az network vnet list` | |
| Resource group | `az group list -o table` | còn `NetworkWatcherRG` (Azure tự tạo, không tính phí đáng kể) |
| Neon DB | `psql ... -c '\l'` | còn `studydb` nếu chưa drop |
| Neon branch/endpoint | Neon console | lab không tạo branch mới |
| Docker local | `docker ps -a`, `docker volume ls` | còn `cdb-study`, `cdb-study-data` |
| Cert TLS | `sudo certbot certificates` | cert `kanban.akaine.io.vn` hết hạn 2027-02-07; `systemctl list-timers 'certbot*'` |
| DNS Cloudflare | dashboard Cloudflare | bản ghi `kanban` vẫn proxy về IP cũ → trả 521 sau khi xoá RG |
| SSH key | không cần xoá | `~/.ssh/id_rsa_azure` dùng lại được |

## 5. Thứ tự dọn an toàn

1. Chụp lại bằng chứng / dump nếu cần (`/home/azureuser/studydb-lab.dump`).
2. `az vm deallocate` trước để dừng tính giờ compute, xác nhận không cần nữa.
3. Drop `studydb` trên Neon (giữ project).
4. `az group delete -n rg-demo --yes` — xoá luôn IP tĩnh và đĩa.
5. Kiểm tra lại bảng ở mục 4.
