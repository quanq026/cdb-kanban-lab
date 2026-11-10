# Cloud Database Lab — PostgreSQL 17 + Docker + Azure + Neon

Bài lab end-to-end: dựng PostgreSQL 17 trong Docker trên VM Azure, làm quen backup/restore, đẩy dữ liệu lên Neon (managed Postgres), rồi viết web Kanban Flask dùng chính database cloud đó.

## 1. Kiến trúc

```
Trình duyệt ──HTTPS──► Cloudflare (proxy, Full/Full strict)
                          │ TLS tới origin
                          ▼
                     nginx :443 (VM Azure) ──► gunicorn 127.0.0.1:8000 (Flask)
                                                     │ psycopg_pool (min 1, max 5)
                                                     ▼
                                      Neon PostgreSQL 17 "studydb"  (TLS 1.3, verify-full)

nginx :80 vẫn mở cho IP trực tiếp và cho ACME HTTP-01 (gia hạn cert).
VM Azure còn chạy: container postgres:17 @ 127.0.0.1:55432 (volume cdb-study-data)
                  → nguồn của file dump dùng để restore sang Neon và để làm evidence.
```

| Thành phần | Giá trị thực tế |
|---|---|
| VM | `vm-cdb`, `20.48.104.156`, japaneast, **Standard_B2pls_v2** (Arm64, 2 vCPU / 4 GiB), Ubuntu 24.04.5 LTS |
| Đĩa | Standard SSD 30 GB (`vm-cdb-osdisk`), swap 2 GB |
| NSG | 22 chỉ từ `118.70.140.18/32`; 80 và 443 public; **không mở 5432** |
| Postgres local | container `cdb-study` (postgres:17.11), volume `cdb-study-data`, `127.0.0.1:55432`, DB `studydb` |
| Neon | project `icy-sound-48483515`, branch `br-silent-darkness-a1gqqmlj`, endpoint `ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech`, DB `studydb`, role `app_user` |
| App | `/opt/cdb/app` + venv `/opt/cdb/venv`, systemd `cdb-kanban`, nginx site `cdb-kanban` |
| Domain | `kanban.akaine.io.vn` → Cloudflare proxy (A/AAAA) → origin `20.48.104.156` |
| TLS origin | Let's Encrypt `CN=kanban.akaine.io.vn` (`/etc/letsencrypt/live/kanban.akaine.io.vn/`), hết hạn **2027-02-07**, tự gia hạn bằng `certbot.timer` |
| Web | <https://kanban.akaine.io.vn/> · health: <https://kanban.akaine.io.vn/api/health> · IP trực tiếp: <http://20.48.104.156/> |

## 2. Cấu trúc thư mục

```
app/
  app.py               Flask API + pool + ProxyFix + log request + session/login/register
  index.html           UI Kanban (markup, top bar + menu tài khoản/theme)
  login.html           trang đăng nhập
  register.html        trang đăng ký tài khoản (công khai)
  app.css              1 file CSS: design B (warm + teal), light/dark, responsive, skeleton, toast
  app.js               1 file JS thuần: login/register/board, fetch, optimistic update, drag & drop
  cdb-kanban.service   systemd unit
  nginx-cdb.conf       reverse proxy :80/:443
infra/
  schema.sql           users / tasks / index / seed
  provision.sh         swap, docker, nginx, postgresql-client-17, venv
  gd2*-*.sh            các bước Postgres local (tạo, verify, persistence, backup)
  gd3*-neon.sh         restore + app_user + kiểm tra TLS trên Neon
  gd4*.sh              deploy app, sửa CA bundle
  https-1-acme.sh      webroot ACME + location /.well-known cho HTTP-01
  https-2-cert.sh      cài certbot, xin cert Let's Encrypt
  https-3-nginx.sh     nginx 80 + 443 (TLS 1.2/1.3), reload
  https-4-renew-hook.sh  deploy hook: nginx -t + reload sau khi cert gia hạn
  https-5-hardening.sh nginx: redirect HTTP→HTTPS, security headers, ACME trên cả 80/443
  nginx-cloudflare-realip.conf  set_real_ip_from dải Cloudflare + real_ip_header CF-Connecting-IP
  app-deploy.sh        backup + cài app/nginx, health-check, tự rollback nếu lỗi
  app-tests.sh         86 test API thật (curl, tự đăng ký/tự xoá tài khoản) → evidence/app-tests-nolimit.md
  ui-shots.mjs         tự đăng ký + chụp screenshot login/register/board/menu desktop/mobile, light/dark qua CDP
  login-*.sh           migration / rollback / thêm APP_SECRET_KEY
  purge-neon-demo.sh   backup rồi xoá user/task demo trên Neon (một lần)
  purge-test-accounts.sh  dọn tài khoản test-*/shot+*/verify+* còn sót
  migration-2026-11-10-login*.sql  DDL up/down của cột users.password_hash
  ev-local.sh          sinh evidence constraints/transaction/index/persistence/backup-restore
  ev-cloud.sh          sinh evidence cloud + monitoring
  ev-https.sh          sinh evidence https (domain, cert, TLS, Cloudflare)
  ev-https2.ps1        sinh evidence https-hardening (Cloudflare settings + headers)
scripts/
  run-remote.ps1       copy script lên VM (chuẩn hoá LF) rồi chạy bằng sudo
  deploy-app.ps1       upload app.py/index.html/login.html/register.html/app.css/app.js/nginx rồi chạy app-deploy.sh
design/
  options.html         2 phương án thiết kế GĐ B+ (mockup tĩnh, không deploy)
  options.png          ảnh chụp 2 phương án cạnh nhau
evidence/              bằng chứng, mỗi file có lệnh + output thật
PROGRESS.md            nhật ký từng bước, lỗi và cách xử lý
cleanup.md             lệnh dọn + danh sách tài nguyên cần kiểm tra
```

## 3. Cách chạy lại

Yêu cầu: Azure CLI đã đăng nhập, SSH key `~/.ssh/id_rsa_azure`, PowerShell.

```powershell
# 1. Hạ tầng (nếu tạo mới; hiện tại đã tồn tại)
az group create -n rg-demo -l japaneast
az vm create -g rg-demo -n vm-cdb --image Canonical:ubuntu-24_04-lts:server-arm64:latest `
  --size Standard_B2pls_v2 --nics nic-demo --admin-username azureuser `
  --ssh-key-values "$env:USERPROFILE\.ssh\id_rsa_azure.pub" --authentication-type ssh `
  --os-disk-size-gb 30 --storage-sku StandardSSD_LRS

# 2. Cài phần mềm trên VM
powershell -File scripts\run-remote.ps1 -Path infra\provision.sh

# 3. Postgres local + role + dump/restore
powershell -File scripts\run-remote.ps1 -Path infra\gd2a.sh
powershell -File scripts\run-remote.ps1 -Path infra\gd2b.sh
powershell -File scripts\run-remote.ps1 -Path infra\gd2d-persistence.sh
powershell -File scripts\run-remote.ps1 -Path infra\gd2e-backup.sh

# 4. Neon (điền biến trong .env trước)
powershell -File scripts\run-remote.ps1 -Path infra\gd3-neon.sh
powershell -File scripts\run-remote.ps1 -Path infra\gd3b-neon.sh

# 5. Web (lần đầu)
scp app\app.py app\index.html app\cdb-kanban.service app\nginx-cdb.conf azureuser@20.48.104.156:/tmp/
powershell -File scripts\run-remote.ps1 -Path infra\gd4-deploy.sh
powershell -File scripts\run-remote.ps1 -Path infra\gd4b-fix-tls.sh

# 5b. Cập nhật app sau này
powershell -File scripts\deploy-app.ps1     # backup + upload + restart + health-check, tự rollback nếu lỗi
powershell -File scripts\run-remote.ps1 -Path infra\app-tests.sh   # 86 test API (tự đăng ký, tự xoá)
node infra\ui-shots.mjs evidence             # tự đăng ký + screenshot login/register/board
powershell -File scripts\run-remote.ps1 -Path infra\purge-test-accounts.sh   # dọn tài khoản evidence
```

`deploy-app.ps1` copy file cũ vào `/opt/cdb/app/backup-YYYY-MM-DD[-HHMMSS]/` trước khi ghi đè; nếu `nginx -t` fail, service không lên hoặc health-check fail thì tự khôi phục bản backup và reload lại.

# 6. Domain + HTTPS (DNS đã trỏ về Cloudflare → origin)
powershell -File scripts\run-remote.ps1 -Path infra\https-1-acme.sh
powershell -File scripts\run-remote.ps1 -Path infra\https-2-cert.sh
powershell -File scripts\run-remote.ps1 -Path infra\https-3-nginx.sh
powershell -File scripts\run-remote.ps1 -Path infra\https-4-renew-hook.sh
powershell -File scripts\run-remote.ps1 -Path infra\https-5-hardening.sh
powershell -File infra\ev-https2.ps1
```

## 4. Biến môi trường

Máy local: `.env` (đã gitignore) chứa `PG_SUPER_PASSWORD`, `LOCAL_APP_PASSWORD`, `NEON_APP_PASSWORD`, `NEON_*`, `NEON_API_KEY`. Không có secret nào nằm trong file SQL hay file được commit.

Trên VM:
- `/etc/cdb/secrets.env` (600, root) — mật khẩu cho các script lab và role owner Neon.
- `/etc/cdb/app.env` (600, root) — 8 biến app cần:

| Biến | Giá trị |
|---|---|
| `DB_HOST` | endpoint Neon (trực tiếp, không `-pooler`) |
| `DB_PORT` | `5432` |
| `DB_NAME` | `studydb` |
| `DB_USER` | `app_user` |
| `DB_PASSWORD` | mật khẩu riêng của `app_user` |
| `DB_SSLMODE` | `verify-full` |
| `DB_SSLROOTCERT` | `/etc/ssl/certs/ca-certificates.crt` |
| `APP_SECRET_KEY` | khoá ký cookie session (thêm bởi `infra/login-secret.sh`, không in ra) |

## 5. API

| Method | Path | Ghi chú |
|---|---|---|
| POST | `/api/register` | **công khai**; body `{email, password}` → 201 + tự đăng nhập; email sai/mật khẩu <8 ký tự → 400 `invalid_request`; trùng email → 409 `unique_violation`; **không giới hạn số tài khoản** |
| POST | `/api/login` | body `{email, password}` → set cookie `cdb_session` (12 h); sai → 401 `invalid_credentials`; **không khoá theo số lần sai** |
| POST | `/api/logout` | xoá session, 200 `{ok:true}` |
| GET | `/api/me` | user của session hiện tại `{user:{id,email}}`; chưa đăng nhập → 401 |
| GET | `/api/health` | công khai: `{status, db_user, ok}` — **không** trả host/database/ssl |
| GET | `/api/health?detail=1` | chỉ `127.0.0.1`/`::1`: thêm `database`, `backend_addr`, `db_host`, `sslmode`; ngoài localhost → 403 |
| GET | `/api/users` | chỉ trả chính user đang đăng nhập (giữ endpoint cho tương thích) |
| GET | `/api/tasks?user_id=` | task của 1 user; `user_id` phải khớp session |
| POST | `/api/tasks` | body `{user_id, title}` → tạo ở `todo` |
| PATCH | `/api/tasks/<id>` | body `{user_id, status?, title?}` — phải có ít nhất 1 field; SQL `WHERE id=%s AND user_id=%s` |
| DELETE | `/api/tasks/<id>?user_id=` | **không dùng body**; SQL `WHERE id=%s AND user_id=%s` |

Mọi endpoint (trừ `/api/register`, `/api/login`, `/api/health`) đều cần session; thiếu → **401** `unauthenticated`. `user_id` không khớp user trong session → **403** `forbidden_user`.

Validate ở backend: `title` rỗng/toàn khoảng trắng → 400; `title` > 200 ký tự → 400; `status` ngoài `todo|doing|done` → 400; task không thuộc user → 404. Mọi SQL đều tham số hóa.

Lỗi luôn là JSON `{error, code}` (không trả HTML):

| Tình huống | HTTP | `code` |
|---|---|---|
| Chưa đăng nhập (API) | 401 | `unauthenticated` |
| `user_id` không khớp session | 403 | `forbidden_user` |
| Sai email/mật khẩu, user chưa có hash | 401 | `invalid_credentials` |
| Body/validate sai, `CHECK` violation, user_id không tồn tại (FK) | 400 | `invalid_request`, `check_violation`, `foreign_key_violation` |
| Trùng email khi đăng ký | 409 | `unique_violation` |
| Task không thuộc user / không tồn tại | 404 | `not_found` |
| `?detail=1` từ ngoài localhost | 403 | `forbidden` |
| Không kết nối được DB (Neon ngủ/lỗi mạng) | 503 | `db_unavailable` |
| Lỗi DB khác / lỗi không lường trước | 500 | `db_error`, `internal_error` |

- **Không còn rate limit:** đã bỏ toàn bộ giới hạn ghi 60/phút, login 8 lần sai/5 phút và đăng ký 5 tài khoản/giờ theo yêu cầu (đánh đổi được chấp nhận: không có chống spam/dò mật khẩu phía app; xem mục 11).
- **Log request:** mỗi request ghi 1 dòng `METHOD path status Xms ip=...` ra journald (`journalctl -u cdb-kanban`), không ghi body/header/token.
- **IP thật:** nginx dùng `real_ip_header CF-Connecting-IP` chỉ tin dải Cloudflare (`infra/nginx-cloudflare-realip.conf`), set `X-Forwarded-For`/`X-Forwarded-Proto`, app dùng `werkzeug ProxyFix` (`x_for=1, x_proto=1, x_host=1`) nên log thấy IP người dùng, không phải IP Cloudflare.

## 5b. Giao diện & trải nghiệm

- **Đăng nhập / đăng ký thật:** `/login` (email + mật khẩu) và `/register` (mở công khai, mật khẩu ≥ 8 ký tự, tự đăng nhập sau khi tạo) → session cookie 12 h; mọi trang/API đều chặn khi chưa đăng nhập. Top bar gọn: brand · ô tìm kiếm · nút theme · avatar mở menu (email + **Đăng xuất**) · **Thêm việc**. Hai trang auth là layout riêng, chỉ tiêu đề + form (không subtitle), link qua lại. Dữ liệu demo trên Neon đã xoá — user mới vào board trống.
- **Design B (đã chọn):** 1 accent teal `#0f766e` (dark `#2dd4bf`) + neutrals ấm `#fbfaf7`/`#1d1b19`, chip màu theo trạng thái, radius 10–14 px, không viền cột; chuyển động 150–200 ms và tôn trọng `prefers-reduced-motion`. Chỉ 1 file CSS + 1 file JS.
- **Responsive:** desktop 3 cột; ≤760px bảng cuộn ngang dạng snap, mỗi cột ~86vw (đã chụp ở đúng 375px).
- **Di chuyển task:** kéo–thả HTML5 trên desktop; trên cảm ứng dùng nút `←`/`→` trên mỗi thẻ (không phụ thuộc long-press). Cả hai đều optimistic: đổi cột ngay, API lỗi thì hoàn tác + toast.
- **Sửa tiêu đề tại chỗ:** double-click hoặc nút `✎`; `Enter` lưu, `Esc` huỷ, blur cũng lưu; PATCH chỉ gửi `title`.
- **Trạng thái tải:** skeleton ở mỗi cột; nếu request > 2 s hiện “Đang kết nối cơ sở dữ liệu…”; nút bị disable khi đang gửi.
- **Phản hồi:** toast thành công/lỗi tự tắt; xoá phải xác nhận trong `<dialog>` (Esc = giữ lại).
- **Tìm & phím tắt:** đếm task mỗi cột (theo bộ lọc hiện tại), lọc theo tiêu đề, `N` mở form thêm, `/` focus ô tìm.
- **A11y:** mọi nút icon có `aria-label`, `focus-visible` rõ, `<dialog>` native (giữ focus/Esc), `aria-live` cho toast và banner, skip-link tới bảng.
- **Dark mode:** tự theo `prefers-color-scheme` hoặc nút đổi theme 3 trạng thái `auto → light → dark` (lưu `localStorage`).
- **Không footer:** trạng thái kết nối không còn hiển thị ở cuối trang; lỗi mạng/DB báo bằng toast và banner “Đang kết nối cơ sở dữ liệu…” khi chậm.
- **Cache asset:** `app.css`/`app.js` gắn `?v=` mỗi lần đổi build (cơ chế chính); origin trả `Cache-Control: no-cache` cho 2 file này, trang/API dùng `no-store`. Lưu ý: Cloudflare có thể vẫn cache asset tĩnh ~4 h (`max-age=14400`), nên khi sửa CSS/JS **phải tăng `?v=`** trong cả `index.html`, `login.html` và `register.html` (hiện tại `?v=20261110f`).

Ảnh: `evidence/ui-login-light.png`, `ui-register-light.png`, `ui-empty-light.png`, `ui-desktop-light.png`, `ui-desktop-dark.png`, `ui-menu-light.png` (menu tài khoản mở), `ui-mobile-light.png`, `ui-mobile-dark.png` (chụp bằng `infra/ui-shots.mjs` qua Chrome CDP; script tự đăng ký rồi chụp, đúng 1440px và 375px); metadata ở `evidence/ui-shots.json`.

## 6. Domain & HTTPS

| Mục | Giá trị |
|---|---|
| Domain | `kanban.akaine.io.vn` (A/AAAA do Cloudflare proxy) |
| SSL mode Cloudflare | Full / Full (strict) |
| Cert origin | Let's Encrypt `CN=kanban.akaine.io.vn`, SAN đúng 1 tên, hiệu lực `2026-11-09` → `2027-02-07` |
| Giao thức | TLS 1.2 + 1.3 (ưu tiên 1.3), HTTP/2 qua `listen 443 ssl http2;`; edge Cloudflare `min_tls_version = 1.2` (TLS 1.0/1.1 bị từ chối) |
| Cloudflare | `ssl = strict` (xác minh cert origin), `always_use_https = on`, `automatic_https_rewrites = on`, HTTP/3 + Brotli bật |
| Header bảo mật | HSTS `max-age=15552000` (không includeSubDomains/preload), `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy` |
| Redirect | `http://kanban.akaine.io.vn/` → 301 → HTTPS; `http://20.48.104.156/` → 301 về domain; ACME path được miễn redirect |
| Gia hạn | `certbot.timer` (systemd) + `certbot renew --dry-run` đã PASS; deploy hook `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` tự `nginx -t` + `systemctl reload nginx` sau khi gia hạn |
| ACME | HTTP-01 qua webroot `/var/www/letsencrypt`, location `^~ /.well-known/acme-challenge/` |
| Endpoint | <https://kanban.akaine.io.vn/> (qua Cloudflare) · <http://20.48.104.156/> (IP trực tiếp, không TLS) |

Kiểm chứng thật (xem `evidence/https.md`):

- `GET https://kanban.akaine.io.vn/` → **200**, `Server: cloudflare`.
- `GET https://kanban.akaine.io.vn/api/health` → `{"db_user":"app_user","ok":true,"status":"ok"}` (rút gọn); chi tiết `db_host`/`database`/`sslmode` chỉ ở `?detail=1` từ localhost.
- Bắt tay trực tiếp origin: `Verify return code: 0 (ok)`, `TLSv1.3`, `TLS_AES_256_GCM_SHA384`.
- Trước khi có cert: Cloudflare trả **521**; sau khi thêm 443 → 200.

## 7. Quyết định tự chọn

1. **Vùng:** giữ `rg-demo` ở **japaneast** (đã tồn tại từ trước, chứa vnet/nsg/pip/nic do lần demo trước tạo). Đã thử `southeastasia` ở tầng SKU: toàn bộ B-series trả `NotAvailableForSubscription` → bị policy chặn.
2. **Size:** `Standard_B2ats_v2` bị chặn cho subscription này; `B1s/B1ms/B2s` hết capacity ở japaneast. Chọn **Standard_B2pls_v2 (Arm64)** + image Ubuntu arm64 — cùng phân khúc burstable, 4 GiB RAM đủ cho Docker + Postgres + Flask.
3. **Neon:** org do Vercel quản lý nên API tạo project bị chặn; dùng project sẵn có và **chỉ thêm database `studydb`** (không đụng `neondb`).
4. **Mật khẩu `app_user`:** local dùng `\password` (đúng đề); Neon từ chối SCRAM verifier nên dùng `ALTER ROLE ... PASSWORD :'pw'` qua psql variable (plaintext, không nằm trong file).
5. **CA:** `sslrootcert=system` không dùng được với libpq bundled của `psycopg[binary]` → trỏ `DB_SSLROOTCERT` vào bundle CA của Ubuntu. Vẫn là `verify-full`, **không tắt xác minh**.
6. **Bổ sung `/api/users`** để dropdown hoạt động; **bổ sung `DB_SSLMODE`/`DB_SSLROOTCERT`** vì Neon bắt buộc TLS.
7. **HTTPS ở origin:** đề chỉ yêu cầu nginx proxy cổng 80, nhưng domain `kanban.akaine.io.vn` đi qua Cloudflare (SSL mode Full/Full strict) nên origin phải có 443. Nguyên nhân lỗi **521** ban đầu: nginx chỉ listen 80, không có dịch vụ TLS ở 443 → Cloudflare không bắt tay được. Cách xử lý: xin cert Let's Encrypt bằng `certbot --webroot` qua HTTP-01 (đi xuyên Cloudflare vì `/.well-known/acme-challenge/` được proxy về origin), thêm server block `listen 443 ssl http2;` với TLS 1.2/1.3, bật `certbot.timer`. nginx 1.24 **không** hỗ trợ directive `http2 on;` (phải dùng tham số trên `listen`).
8. **Pool resilience:** Neon Free scale-to-zero có thể đóng backend `AdminShutdown`; thêm `max_idle=120`, `max_lifetime=1800`, `check=ConnectionPool.check_connection`, `reconnect_timeout=30` và retry 1 lần khi `OperationalError` (2 lần thử) để tránh 500 thoáng qua.
9. **`/api/health` hai mức:** bản công khai chỉ `{status, db_user, ok}` để không lộ endpoint/database/sslmode; bản `?detail=1` chỉ cho `127.0.0.1`/`::1` (kiểm tra sau ProxyFix) phục vụ vận hành.
10. **IP thật:** dùng `ngx_http_realip_module` với danh sách dải Cloudflare + `CF-Connecting-IP`, rồi mới set `X-Forwarded-For`; app không tin header thô từ client (chống giả IP làm sai log).
11. **Không rate limit:** theo yêu cầu, đã bỏ cả giới hạn ghi, login và đăng ký; đánh đổi là không có chống spam/dò mật khẩu phía app. Giảm rủi ro bằng Cloudflare (WAF/rate limiting có thể bật ở edge nếu cần), mật khẩu tối thiểu 8 ký tự + scrypt, log request để theo dõi bất thường; đây là phạm vi demo.
12. **DELETE dùng query string** (`?user_id=`) vì body trên DELETE không được mọi proxy/client xử lý nhất quán; PATCH nhận thêm `title` để sửa tại chỗ mà không cần endpoint mới.
13. **Login bằng mật khẩu + session cookie** thay vì PIN/dropdown: thêm cột `users.password_hash` (nullable, scrypt của werkzeug), cookie ký `cdb_session` (`HttpOnly`, `SameSite=Lax`, `Secure`, 12 h) để không phải thêm bảng session; `user_id` client gửi lên vẫn bị đối chiếu với session. Migration + rollback nằm ở `infra/migration-2026-11-10-login*.sql`.

## 8. Khác so với đề bài

| Đề | Đã làm | Lý do |
|---|---|---|
| `tasks.done boolean` | `tasks.status text` + `CHECK (status IN ('todo','doing','done'))` | Đề GĐ4 yêu cầu Kanban 3 cột Todo/Doing/Done, một cột boolean không biểu diễn được trạng thái `doing`; đổi sang `status` để kéo–thả 3 cột. Vẫn giữ `CHECK` nên miền giá trị bị chặn ở DB. |
| `users(id, email)` | thêm `password_hash text` (nullable) | Cần chỗ lưu hash để có login thật; cột nullable nên user cũ vẫn hợp lệ (chỉ không đăng nhập được cho tới khi seed mật khẩu). Không đổi cột/index cũ. |
| `region: southeastasia` | japaneast | Policy/SKU chặn B-series ở southeastasia (xem mục 7). |
| `Standard_B2ats_v2` | `Standard_B2pls_v2` (Arm64) | SKU không khả dụng cho subscription + hết capacity các size B nhỏ. |
| Tạo project Neon mới | thêm DB vào project có sẵn | Org do Vercel quản lý, API tạo project bị khoá. |

## 9. Bảo mật

- Không dùng `postgres`/owner cho app: app kết nối bằng `app_user` (không superuser, không CREATEDB/CREATEROLE/BYPASSRLS).
- 5432 không mở ra Internet: container chỉ publish `127.0.0.1:55432`.
- SSH chỉ từ 1 IP; đăng nhập bằng key, `PasswordAuthentication` tắt (Azure `--authentication-type ssh`).
- Secret: `.env*` + `/etc/cdb/*.env` quyền 600; `.gitignore` chặn `.env*`, `*.dump`, `*.pem`, `login-azure.ps1` (file này hardcode Azure client secret — nếu từng bị chia sẻ/push thì phải rotate).
- HTTPS: Cloudflare `ssl=strict` → origin Let's Encrypt; `min_tls_version=1.2`; HTTP/2; HSTS + `nosniff` + `SAMEORIGIN` + `Referrer-Policy` + `Permissions-Policy`; HTTP (kể cả theo IP) redirect 301 về HTTPS. Private key ở `/etc/letsencrypt/live/.../privkey.pem` (root 600).
- SSH chỉ cho IP hiện tại; khi IP nhà đổi phải cập nhật rule `Allow-SSH` (đã xảy ra trong phiên này: `123.24.61.51` → `118.70.140.18`).
- App trả lỗi validation rõ ràng; không log mật khẩu/body/header (đã kiểm chứng 0 lần xuất hiện secret trong journal/nginx log). Lỗi 500 trả message chung, stack trace chỉ vào journald.
- **Mật khẩu:** lưu hash scrypt (`werkzeug`, salt riêng từng user), không lưu plaintext; user chưa có hash bị từ chối; so sánh với hash giả khi email không tồn tại để giảm lộ thông tin qua thời gian.
- **Session:** cookie ký `cdb_session` (`Secure`, `HttpOnly`, `SameSite=Lax`, 12 h) — JS không đọc được; `APP_SECRET_KEY` chỉ nằm trong `/etc/cdb/app.env` (600 root). Logout xoá cookie; đổi key = mọi session cũ mất hiệu lực.
- **Đăng ký công khai:** email + mật khẩu ≥ 8 ký tự, hash scrypt; **không giới hạn số tài khoản** (theo yêu cầu); trùng email → 409. Không có mã mời.
- **Phân quyền dữ liệu:** API đối chiếu `user_id` với session (403 nếu lệch); task của user khác trả 404 để không lộ sự tồn tại.
- Header bảo mật do app set cho mọi response: `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`, `Content-Security-Policy` (`default-src 'self'`, không `unsafe-inline`); HSTS giữ ở nginx.
- IP thật lấy qua `real_ip_header CF-Connecting-IP` chỉ tin dải Cloudflare; nginx ghi đè `X-Forwarded-For` bằng IP đã xác thực nên client không giả được IP trong log.
- `/api/health` công khai không lộ host/database/sslmode; chi tiết chỉ mở cho localhost.
- **Không rate limit (đánh đổi đã chấp nhận):** app không chặn spam ghi, không khoá sau nhiều lần sai mật khẩu, không giới hạn đăng ký. Nếu cần bảo vệ, bật rate limiting/WAF ở Cloudflare hoặc thêm lại limiter phía app; log request vẫn ghi IP để phát hiện bất thường.

## 10. Bằng chứng

`evidence/`: `constraints.md`, `transaction.md`, `index.md`, `persistence.md`, `backup-restore.md`, `cloud.md`, `monitoring.md`, `diagram.md`, `cost.md` — mỗi file ghi lệnh đã chạy và output thật. Thêm `https.md` (domain/chứng chỉ/TLS), `https-hardening.md` (Cloudflare settings, header, TLS 1.1 bị chặn, redirect), `app-tests.md` (46 test API trước login, lịch sử), `app-tests-auth.md` (67 test có session dùng seed, lịch sử), `app-tests-register.md` (82 test có rate limit, lịch sử), `app-tests-nolimit.md` (**86 test hiện tại**, tự đăng ký/tự dọn, không rate limit), `login.md` (migration + rollback + ma trận lỗi + kiểm chứng browser), `cleanup-register.md` (backup + purge demo Neon + đăng ký), `ui.md` + `ui-shots.json` và 8 ảnh `ui-*.png` (login/register/board trống/desktop/menu/mobile × light/dark).

## 11. Giới hạn đã biết

- Chưa test mất toàn máy/PITR/failover; backup hiện nằm cùng VM với database.
- Chứng chỉ Let's Encrypt hết hạn **2027-02-07**; `certbot.timer` đã bật và `certbot renew --dry-run` thành công, nhưng nếu VM tắt quá lâu thì cert có thể hết hạn (bật VM để timer chạy lại, hoặc chạy `sudo certbot renew`).
- Cloudflare đang proxy nên IP thật của origin bị ẩn; đổi IP VM phải cập nhật DNS trong Cloudflare (hoặc dùng Origin Rule) — `http://20.48.104.156/` giờ chỉ còn redirect 301 về domain.
- HSTS đã bật 180 ngày trên browser đã truy cập: nếu sau này bỏ HTTPS, các browser đó vẫn ép HTTPS đến khi hết hạn (hoặc xoá HSTS cache). Không bật `includeSubDomains`/`preload` để giữ khả năng rollback.
- `ssl=strict` là setting của cả zone `akaine.io.vn`: apex `akaine.io.vn` đang 522 (origin `167.254.69.146` không truy cập được); nếu sau này trỏ apex về origin khác thì origin đó phải có cert hợp lệ, nếu không sẽ thành 526.
- Neon Free scale-to-zero sau 5 phút → request đầu tiên sau khi idle chậm hơn; pool có `check_connection` + `reconnect_timeout` + retry 1 lần nên không trả 500. Đo lại sau purge: request đầu **1.86 s**, sau đó 0.74 s / 0.31 s (chi tiết `evidence/app-tests-register.md`).
- **Không rate limit:** đã bỏ toàn bộ limiter (ghi/login/đăng ký) theo yêu cầu; không còn bộ đếm in-memory, restart service không ảnh hưởng. Đánh đổi: không chống spam/dò mật khẩu ở tầng app; nên bật rate limiting ở Cloudflare nếu triển khai thật.
- Kéo–thả cảm ứng: dùng nút `←`/`→` thay vì long-press drag (đề cho phép); kéo bằng chuột vẫn là HTML5 drag & drop.
- CSP không cho inline script/style: nếu sau này nhúng script/style trực tiếp vào HTML phải thêm hash/nonce hoặc chuyển ra file, nếu không browser sẽ chặn.
- `/api/health?detail=1` chỉ mở cho localhost; muốn xem từ xa phải SSH vào VM hoặc dùng `ssh -L`.
- Session là cookie ký phía client: logout chỉ xoá cookie ở browser hiện tại, **không** thu hồi được session đã bị copy; muốn vô hiệu hoá toàn bộ phải đổi `APP_SECRET_KEY` trong `/etc/cdb/app.env` rồi restart (mọi người phải đăng nhập lại). Chưa có bảng session/refresh token.
- Không còn limiter login/register/ghi; chưa có khoá tài khoản, CAPTCHA hay luồng đổi/quên mật khẩu.
- Trang login/register không có CAPTCHA/2FA/xác thực email; phù hợp phạm vi demo, không dùng cho dữ liệu thật.
