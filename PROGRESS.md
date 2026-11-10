# PROGRESS — Cloud Database Lab (PostgreSQL 17 + Docker + Azure + Neon)

Bắt đầu: 2026-11-09 16:23 +07:00 · Kết thúc GĐ1–GĐ6: 17:00 · Bổ sung Domain + HTTPS: 17:12

## Quyết định nền tảng (tự chọn, ghi lại)
- RG `rg-demo` đã tồn tại ở **japaneast** (vnet-demo, nsg-demo, pip-demo, nic-demo do lần demo trước tạo, không phải tôi tạo) → **dùng lại**, không xoá tài nguyên lạ.
- Đề yêu cầu thử `southeastasia`: kiểm tra Microsoft.Compute SKUs → **toàn bộ B-series bị `NotAvailableForSubscription`** ở southeastasia → giữ japaneast.
- **Size VM:** `Standard_B2ats_v2` → `NotAvailableForSubscription`; `B1s`/`B1ms`/`B2s` → `SkuNotAvailable` (capacity). Chốt **Standard_B2pls_v2 (Arm64, 2 vCPU / 4 GiB)** + image `server-arm64`.
- Neon: org do Vercel quản lý → API tạo project bị chặn ("action restricted"), dùng project sẵn có và **chỉ tạo thêm database `studydb`**.
- Neon từ chối SCRAM verifier của `\password` → dùng `ALTER ROLE ... PASSWORD :'pw'` (plaintext, qua psql variable).

## Trạng thái cuối

| GĐ | Trạng thái | Bằng chứng |
|----|-----------|------------|
| 1 Azure | ✅ xong | VM `vm-cdb` running, swap 2G, docker/nginx/psql17/venv |
| 2 Postgres local | ✅ xong | 2 users + 5 tasks, app_user least-privilege, persistence, dump/restore trùng khớp |
| 3 Neon | ✅ xong | restore `studydb`, app_user, TLS verify-full TLSv1.3 |
| 4 Web Kanban | ✅ xong | `https://kanban.akaine.io.vn/` 200, health trả `app_user` |
| 5 Evidence | ✅ xong | `evidence/` 10 file (9 theo đề + `https.md`) |
| 6 Tổng kết | ✅ xong | `README.md`, `cleanup.md`, báo cáo cuối |
| + Domain/HTTPS | ✅ xong | Let's Encrypt 2027-02-07, TLS 1.3, Cloudflare 521 → 200 |
| + GĐ A (backend bền) | ✅ xong | pool check/reconnect_timeout/retry, JSON error, log request, rate limit, health 2 mức, 46 test API |
| + GĐ B (UI/UX) | ✅ xong | `app.css`/`app.js`, responsive 375px, optimistic + rollback, inline edit, toast/confirm, a11y, dark mode, 4 ảnh |
| GĐ B+ (thiết kế) | ✅ xong | chọn hướng **B (warm neutral + teal)**, token light/dark, chip trạng thái, chip tài khoản, theme toggle, 5 ảnh |
| GĐ C (login) | ✅ login/logout | `users.password_hash` (scrypt) + session cookie, chặn API khi chưa đăng nhập, 67 test PASS |
| GĐ C (đăng ký + purge demo) | ✅ xong | `POST /api/register` + `/register`, Neon sạch `users=0 tasks=0`, 82 test PASS, 7 ảnh |
| GĐ C (schema còn lại) | ⏸ chờ duyệt | `tasks.position`, `created_at`, `updated_at` — chưa làm |

## Nhật ký chi tiết

### GĐ1 — Azure (16:23–16:30)
- `az vm create` fail 4 lần (SKU/capacity) rồi OK với `Standard_B2pls_v2` + Ubuntu 24.04 arm64.
- VM: private 10.0.1.4, public **20.48.104.156**, Ubuntu 24.04.5 LTS, 2 vCPU / 3893 MiB, đĩa StandardSSD 30 GB.
- NSG: `Allow-SSH` 22 ← `123.24.61.51/32` (priority 1000), `Allow-HTTP-Public` 80 ← `*` (1010), `Allow-HTTPS` 443 ← `*` (1020). Không có 5432.
- Provision OK: swap 2G, docker 29.1.3, nginx 1.24.0, psql 17.11, python 3.12.3.

### GĐ2 — Postgres local (16:31–16:42)
- Volume `cdb-study-data`, container `cdb-study`, `127.0.0.1:55432`, DB `studydb`, PG 17.11.
- `app_user` tạo bằng `CREATE ROLE ... LOGIN` + `\password` (stdin) — rolsuper=f, không đọc được `pg_authid`, không `DROP TABLE`.
- **Lỗi 1:** block `GRANT ... <<'SQL'` qua `docker exec -i` không được áp dụng (stdin bị chiếm sau lệnh `\password`) → tách thành nhiều `-c`, OK.
- Persistence: xoá container giữ volume → tạo lại → users=2, tasks=5, md5 trùng, app_user login OK.
- Backup: dump 6101 B / 125 ms; restore 228 ms, exit 0; count + md5 + index trùng.
- **Lỗi 2:** so sánh kiểu `studydb_restore.users` (cross-database) — PostgreSQL không hỗ trợ → query riêng từng DB.

### GĐ3 — Neon (16:39–16:45)
- Project `icy-sound-48483515` / branch `br-silent-darkness-a1gqqmlj` / endpoint `ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech` (aws-ap-southeast-1).
- DB `studydb` tạo qua API (project giữ nguyên `neondb`).
- `pg_restore --no-owner --no-privileges` 3107 ms; md5 users/tasks trùng local; app_user CRUD OK, đọc `pg_authid` bị từ chối.
- TLS: cert `CN=*.ap-southeast-1.aws.neon.tech` (Let's Encrypt), `sslmode=verify-full sslrootcert=system` OK.
- **Lỗi 3:** `\password` trên Neon → control plane trả "Neon only supports being given plaintext passwords" → dùng `ALTER ROLE ... PASSWORD :'pw'`.
- Pooled endpoint `...-pooler...` kết nối được; app dùng endpoint trực tiếp.

### GĐ4 — Web (16:45–16:52)
- Flask 3.1.3 + psycopg 3.3.8 + psycopg_pool 3.3.3; gunicorn 2 worker; nginx :80.
- **Lỗi 4:** `sslrootcert=system` với libpq bundled của psycopg-binary → `certificate verify failed` → `DB_SSLROOTCERT=/etc/ssl/certs/ca-certificates.crt` (vẫn verify-full).
- **Lỗi 5:** `run-remote.ps1` chép file CRLF sang VM → bash lỗi `$'\r'` → chuẩn hoá LF trước khi scp.
- Health: `{"db_user":"app_user","db_host":"…neon.tech","database":"studydb","sslmode":"verify-full"}`.
- Truy cập ngoài: index 200 (8732 B), POST task OK, restart service → task vẫn còn.

### GĐ5–GĐ6 — Evidence & tổng kết (16:48–17:00)
- 10 file evidence sinh từ lệnh chạy thật trên VM: constraints, transaction, index, persistence, backup-restore, cloud, monitoring, https (chạy), diagram + cost (soạn tay).
- `README.md` (kiến trúc, cách chạy lại, quyết định, khác đề), `cleanup.md` (không chạy).
- Kiểm tra secret: không có mật khẩu/API key nào trong repo; chỉ tên host/user/ID xuất hiện (không phải secret).
- 5432 từ ngoài: `TcpTestSucceeded=False`. 80: True. 22: True.

### 10:04–10:12 — Domain + HTTPS (yêu cầu bổ sung sau khi trỏ `kanban.akaine.io.vn`)
- DNS trỏ về Cloudflare (`104.21.95.121`, `172.67.144.193` + AAAA), proxy bật.
- **Lỗi 521:** `https://kanban.akaine.io.vn/` trả **521**; kiểm tra origin → `origin_443_open=False`, nginx chỉ có `listen 80`, chưa cài certbot. Nguyên nhân: Cloudflare SSL mode Full/strict cần TLS ở origin.
- Khắc phục:
  1. `https-1-acme.sh`: tạo webroot `/var/www/letsencrypt`, thêm `location ^~ /.well-known/acme-challenge/` → kiểm tra probe qua Cloudflare = 200.
  2. `https-2-cert.sh`: cài certbot, xin cert `--webroot -d kanban.akaine.io.vn` (HTTP-01 xuyên proxy OK) → LE `CN=kanban.akaine.io.vn`, hạn 2027-02-07, `certbot.timer` bật.
  3. `https-3-nginx.sh`: server block 443 TLS 1.2/1.3 + proxy về 127.0.0.1:8000.
- **Lỗi nginx 1.24:** directive `http2 on;` bị `unknown directive` → đổi thành `listen 443 ssl http2;`.
- **Lỗi 500 thoáng qua (Neon suspend):** `psycopg.errors.AdminShutdown` → thêm `max_idle=120`, `max_lifetime=1800`, `check=ConnectionPool.check_connection`, retry 1 lần cho `OperationalError` trong `q_all`/`q_one`; restart service.
- Kết quả: `https://kanban.akaine.io.vn/` **200**, `/api/health` OK (`app_user`, Neon); origin verify `code 0` TLSv1.3; `http://20.48.104.156/` vẫn 200; `certbot renew --dry-run` PASS.
- Bằng chứng: `evidence/https.md` (sinh bằng `infra/ev-https.sh`). README đã cập nhật URL chính, mục Domain & HTTPS, quyết định 7/8.
- 5432 từ Internet vẫn đóng sau thay đổi.

### 17:15–17:18 — Sau khi bật Always Use HTTPS
- Cloudflare: `http://kanban.akaine.io.vn/` → **301** `Location: https://kanban.akaine.io.vn/`; follow redirect ra **200** (`redirects=1`, `ssl_verify=0`).
- Log nginx cho thấy request từ IP Cloudflare vào **443 với HTTP/2.0** → chứng minh Cloudflare đang đi Full/Full strict tới origin, không phải Flexible.
- Phát hiện thiếu: chưa có deploy hook → cert gia hạn xong nginx vẫn phục vụ cert cũ. Đã thêm `infra/https-4-renew-hook.sh` tạo `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` (nginx -t + reload); `certbot renew --dry-run` PASS, health 200.

### 2026-11-10 08:40–08:55 — Hardening (CF token + nginx)
- IP công cộng đổi `123.24.61.51` → `118.70.140.18` → SSH timeout; cập nhật NSG `Allow-SSH` sang IP mới, SSH OK lại.
- Cloudflare API (chỉ zone `akaine.io.vn`, id `fc94e4214166b8219e611c7129d37cf8`; 2 zone khác không đụng):
  - `ssl`: `full` → **`strict`**
  - `min_tls_version`: `1.0` → **`1.2`**
  - đọc lại: `always_use_https=on`, `automatic_https_rewrites=on`, `tls_1_3=on`, `http3=on`, `brotli=on`
- nginx (`https-5-hardening.sh`): port 80 redirect 301 về `https://kanban.akaine.io.vn` (chừa `/.well-known/acme-challenge/`), thêm ACME location ở cả 443, `server_tokens off`, header HSTS/nosniff/X-Frame-Options/Referrer-Policy/Permissions-Policy.
- Kiểm chứng: `http://kanban...` 301 → 200; header xuất hiện qua Cloudflare; `http://20.48.104.156/` 301; ACME probe 200; `certbot renew --dry-run` PASS; TLS 1.2 OK, **TLS 1.1 bị từ chối**.
- Bảo mật secret: `.gitignore` thêm `.env*` và `login-azure.ps1` (file hardcode Azure client secret). Quét lại toàn repo: chỉ `login-azure.ps1` chứa secret đó, không file nào khác.
- Bằng chứng: `evidence/https-hardening.md` (sinh bằng `infra/ev-https2.ps1`).

### 2026-11-10 — GĐ A: độ bền backend (10:00–10:20)
- Backup trước khi sửa: `/opt/cdb/app/backup-2026-11-10/` (app.py + index.html gốc), lần deploy sau thêm `backup-2026-11-10-HHMMSS/`.
- Pool: `min_size=1`, `max_size=5`, `timeout=20`, `max_idle=120`, `max_lifetime=1800`, `check=ConnectionPool.check_connection`, **`reconnect_timeout=30`**, retry 1 lần (2 attempt) khi `OperationalError` ở `q_all`/`q_one`.
- `DELETE /api/tasks/<id>?user_id=` (bỏ body); `PATCH` nhận `status` và/hoặc `title`.
- Error handler thống nhất, luôn `{error, code}`: ValueError/CheckViolation/FK → 400, UniqueViolation → 409, task không thuộc user → 404, `OperationalError` → 503, còn lại → 500; `HTTPException` của `/api/*` cũng trả JSON.
- Log mỗi request `METHOD path status Xms ip=...` ra journald; không log body/header. Đã thấy log thật trong `journalctl -u cdb-kanban`.
- `ProxyFix(x_for=1, x_proto=1, x_host=1)`; nginx thêm `infra/nginx-cloudflare-realip.conf` (`set_real_ip_from` 15 dải IPv4 + 7 dải IPv6 của Cloudflare, `real_ip_header CF-Connecting-IP`) và ghi đè `X-Forwarded-For` bằng IP đã xác thực → log/rate limit thấy IP người dùng (`118.70.140.18`), không phải IP Cloudflare.
- Rate limit 60 request/phút/IP cho POST/PATCH/DELETE → 429 `{code:"rate_limited"}` + `Retry-After`; test thật: 140 POST → **99×400 + 41×429** (2 worker đếm riêng).
- `/api/health` công khai chỉ `{status, db_user, ok}`; `?detail=1` chỉ localhost (ngoài → 403), có `db_host/database/backend_addr/sslmode`.
- Header bảo mật + CSP set ở app (sau khi tách file: không `unsafe-inline`), HSTS vẫn ở nginx.
- Test: `infra/app-tests.sh` → **46 PASS / 0 FAIL** (health, validate, quyền sở hữu, DELETE query, header, rate limit). Lưu `evidence/app-tests.md`.
- **Lỗi 6:** `deploy-app.ps1` bản đầu health-check qua cổng 80 bằng `Host:` → nginx trả 301 (không phải 4xx nên `curl -f` vẫn coi là OK) → sửa health-check sang `https://...:443 --resolve 127.0.0.1`, đồng thời thêm `health_nginx` vào output.
- **Lỗi 7:** lúc test tay, script browser chạy trước khi `/api/users` xong → POST `user_id=null` → 400; đây là lỗi của test (không chờ init), app đúng. Đã chờ đủ điều kiện rồi test lại.
- Thời gian request đầu sau khi Neon idle 7 phút (qua Cloudflare, cùng đường đo trước/sau):
  - Trước sửa: `2.163 s` (request 2–3: `0.845 s`, `0.883 s`)
  - Sau sửa lần 1: `3.100 s` (request 2–3: `0.697 s`, `0.996 s`); server-side trong journald `2427.1ms`, các request sau `~275–282 ms`
  - Sau sửa lần 2 (sau restart, pool rỗng): `2.122 s` (request 2–3: `1.029 s`, `1.065 s`)
  - Kết luận thật: cold start do Neon scale-to-zero dao động `2.1–3.1 s` (trước sửa `2.163 s`), pool mới **không làm Neon thức nhanh hơn** nhưng không trả 500/503 và tự loại connection chết (`check_connection`) — chi tiết ở `evidence/app-tests.md`.

### 2026-11-10 — GĐ B: giao diện & trải nghiệm (10:20–10:45)
- Tách `index.html` (markup) + `app.css` (1 file) + `app.js` (1 file), bỏ toàn bộ style/script inline → CSP siết được `script-src 'self'; style-src 'self'` (không `unsafe-inline`).
- Desktop 3 cột; ≤760px cuộn ngang snap, mỗi cột ~86vw; đã chụp đúng 375px.
- Kéo–thả HTML5 cho chuột; nút `←`/`→` cho cảm ứng/mobile. Cả hai optimistic: đổi ngay, lỗi thì hoàn tác + toast.
- Sửa tiêu đề tại chỗ: double-click hoặc `✎`, `Enter` lưu, `Esc` huỷ, blur lưu; PATCH chỉ gửi `title`.
- Skeleton mỗi cột; banner “Đang kết nối cơ sở dữ liệu…” chỉ hiện khi request > 2 s; nút disable khi đang gửi.
- Toast thành công/lỗi tự tắt; xoá qua `<dialog>` xác nhận (Esc = giữ lại); đếm task mỗi cột; lọc theo tiêu đề; phím `N` và `/`.
- A11y: `aria-label` cho nút icon, `focus-visible`, `<dialog>` native, `aria-live`, skip-link, thứ tự tab hợp lý.
- Dark mode theo `prefers-color-scheme`; footer chỉ `Kết nối database: OK · user: app_user`.
- Ảnh: `evidence/ui-desktop-light.png`, `ui-desktop-dark.png`, `ui-mobile-light.png`, `ui-mobile-dark.png`; script `infra/ui-shots.mjs` (Chrome CDP, chờ data thật rồi mới chụp). Chi tiết: `evidence/ui.md`.
- **Lỗi 8:** banner `#slow` có `hidden` nhưng `.slow{display:flex}` đè UA style → banner không ẩn. Sửa `.slow[hidden]{display:none}`; phát hiện qua ảnh chụp đầu tiên, đã chụp lại toàn bộ.
- **Lỗi 9 (test):** thao tác chuyển cột ngay sau lưu tiêu đề bị bỏ qua do guard `busy` (chống double-submit) — hành vi đúng, test phải chờ `busy` hết.
- Kiểm tra browser thật: thêm/sửa/chuyển/lọc/phím tắt/xoá đều OK, **0 console error**.
- Dữ liệu seed: trong lúc test tay có xoá nhầm task #1, đã restore đúng từ dump (`Soạn đề cương báo cáo`, user 1, todo); task #35 bị đổi trạng thái cũng đã trả về `todo`.

### 2026-11-10 — GĐ B+ design B + login thật (11:00–12:10)
- Chọn hướng **B: warm neutral + teal** (`--bg #fbfaf7` / `#161513`, accent `#0f766e` / `#2dd4bf`), token CSS cho light/dark, chip trạng thái Todo/Doing/Done, radius 10–14 px, hover/drag effect, motion 150–200 ms + `prefers-reduced-motion`, vẫn **1 CSS + 1 JS**, CSP không `unsafe-inline`.
- Login/logout thật (phạm vi được duyệt): thêm `users.password_hash text` nullable, hash **scrypt** (werkzeug), session cookie ký `cdb_session` (`Secure`, `HttpOnly`, `SameSite=Lax`, 12 h), `APP_SECRET_KEY` trong `/etc/cdb/app.env` (600 root). Trang `/login`, chip tài khoản + avatar, nút Đăng xuất, guard `before_request` cho cả trang và API.
- Đối chiếu quyền: `same_user()` so `user_id` client với `session.uid` → 403 `forbidden_user`; task của user khác vẫn 404 `not_found` (không lộ tồn tại). `/api/users` giờ chỉ trả chính user đăng nhập.
- Limiter login riêng: chỉ đếm **lần sai**, 8 lần/5 phút/IP → 429 `Retry-After: 300`; không chặn người đăng nhập đúng.
- Migration chạy giống nhau trên local docker + Neon bằng role owner (`infra/login-migrate.sh`), `app_user` vẫn chỉ có quyền mức bảng (không cấp thêm); rollback `DROP COLUMN IF EXISTS password_hash` đã diễn tập trong transaction (`after_drop=0` → `ROLLBACK` → `after_rollback=1`). File chuẩn: `infra/migration-2026-11-10-login*.sql`.
- Seed mật khẩu demo ngẫu nhiên 14 ký tự (`infra/login-seed.sh`) → `/etc/cdb/demo-login.txt` (600 root), không in ra output; seed cả local docker.
- Test: viết lại `infra/app-tests.sh` cho có session → **67 PASS / 0 FAIL**; burst 140 POST → 98×400 + 42×429. Lưu `evidence/app-tests-auth.md`.
- Browser thật: login sai → 401 + lỗi dưới form; login đúng → board `3/1/1`, chip `an@example.test`; theme `auto→light→dark→auto`; thêm/sửa/chuyển/lọc/`N`/`/`/xoá có confirm đều OK; toast xoá đo được ~500 ms; logout → `/login` và `/api/me` = 401; **0 console error**.
- Ảnh mới: `ui-login-light.png` + 4 ảnh board; metadata `evidence/ui-shots.json`.
- **Lỗi 10 (cache asset):** HTML mới nhưng Cloudflare/browser dùng `app.js` cũ → `TypeError: ... addEventListener of null`, board trắng. Sửa: `?v=20261110c` cho `app.css`/`app.js` + `Cache-Control: no-cache`; `/`, `/login`, `/api/*` vẫn `no-store`.
- **Lỗi 11 (test kỳ vọng sai):** 4 FAIL đầu tiên do (a) mong task user khác trả 403 trong khi app trả 404 (đúng thiết kế), (b) kiểm cookie bằng `GET /api/login` thay vì `POST`. Sửa test, không sửa app.
- **Lỗi 12 (thao tác đo):** PowerShell hiểu `||` trong câu SQL là toán tử → đưa SQL vào file `.sh` chạy qua `run-remote.ps1`.
- Dọn: xoá `infra/temp-password.sh` sau khi xoay mật khẩu demo; không còn mật khẩu tạm nào trong repo.

### 2026-11-10 — Đăng ký công khai + xoá dữ liệu demo (12:10–13:40)
- Yêu cầu mới: "có tính năng đăng ký tài khoản và xóa hết những thứ kiểu demo". Chốt qua câu hỏi: purge **chỉ Neon**, giữ local docker làm mốc lab; đăng ký **mở công khai + rate limit** (không mã mời).
- Backend: `email` chuẩn hoá lowercase + regex, mật khẩu 8–200 ký tự, hash scrypt; `POST /api/register` trả 201 + tự set session; trùng email 409 `unique_violation`; limiter **5 tài khoản thành công/giờ/IP** (chỉ đếm lần tạo được, lần 400/409 không tiêu quota). `/register` thêm vào `PUBLIC_PATHS`; đã đăng nhập mở `/login` hoặc `/register` → 302 về `/`.
- Frontend: `app/register.html` (3 field, validate client ≥ 8 ký tự + nhập lại khớp), `initRegister()` trong `app.js`; `/login` bỏ ghi chú tài khoản demo, thêm link "Chưa có tài khoản? Đăng ký"; `.auth-alt` trong CSS. Asset tăng `?v=20261110d` ở cả 3 trang.
- Deploy: `app-deploy.sh` + `deploy-app.ps1` upload/rollback thêm `register.html`; health-check thêm `/register`. Kết quả deploy: `login_page=200 register_page=200`, health đủ 3 mức OK.
- Purge Neon: backup `neon-demo-purge-2026-11-10-062210.sql` (2594 B) rồi xoá tasks → users; trước `users=2 tasks=7`, sau `users=0 tasks=0` (owner và `app_user` đều thấy 0); xoá `/etc/cdb/demo-login.txt`.
- Dọn tài khoản test: `infra/purge-test-accounts.sh` xoá `test-*`/`shot+*`/`verify+*`; lần cuối `test_users=1` → `0`, production `users=0 tasks=0`.
- Test: `infra/app-tests.sh` viết lại **không cần seed** (tự đăng ký 2 tài khoản, trap tự xoá) → **82 PASS / 0 FAIL**; burst 140 POST → 91×400 + 49×429. Lưu `evidence/app-tests-register.md`; đánh dấu `app-tests-auth.md` là lịch sử.
- Browser thật trên production: đăng ký → board trống → thêm/chuyển/xoá việc → logout → đăng ký trùng 409; **0 console error**. Ảnh mới: `ui-login`, `ui-register`, `ui-empty` + 4 ảnh board (desktop/mobile × light/dark); `ui-shots.json` 7 mục.
- **Lỗi 13 (script ảnh):** `ui-shots.mjs` đăng ký/tạo task qua `fetch` sau khi trang đã load nên UI không tự render → `waitFor` timeout. Sửa: `Page.navigate` lại sau khi đăng ký và sau khi tạo 3 task.
- **Lỗi 14 (ref browser):** `browser.snapshot` mới làm ref cũ hết hiệu lực; click ref cũ → `stale`. Quy tắc: snapshot và click trong cùng một lượt, hoặc lấy ref từ snapshot mới nhất.
- **Lỗi 15 (thiếu env khi purge):** script purge lần đầu đọc `DB_PASSWORD` mà chưa `source /etc/cdb/app.env` → dừng ở bước kiểm `app_user`. Sửa: source `app.env` trước khi psql.
- Xoá `infra/login-seed.sh` (không còn mật khẩu demo để seed); giữ `login-migrate.sh`/`login-rollback.sh` cho migration.
- Đo lại sau idle 330 s: `/api/health` lần 1 = **1.857 s** (Neon wake), lần 2 = 0.736 s, lần 3 = 0.314 s; không có 503. Script `infra/idle-check.sh`.

### 2026-11-10 — Bỏ rate limit + gọn top bar + bỏ footer (14:45–15:20)
- Yêu cầu: bỏ rate limit; bỏ subtitle ở login/register + "Phiên đăng nhập giữ 12 giờ."; bỏ footer "Kết nối database: OK · user: app_user"; thiết kế lại thanh trên. Chốt qua câu hỏi: bỏ **toàn bộ** limiter (ghi 60/phút, login 8 lần sai/5 phút, đăng ký 5 tài khoản/giờ), top bar gọn **brand · tìm kiếm · theme · avatar menu (email + Đăng xuất) · Thêm việc**, **bỏ footer**.
- Backend `app/app.py`: xoá `threading`/`deque`, các hằng `RATE_LIMIT/RATE_WINDOW/LOGIN_LIMIT/LOGIN_WINDOW/REGISTER_LIMIT/REGISTER_WINDOW`, các hàm `rate_limited/login_blocked/login_failed/register_blocked/register_created` và mọi call; bỏ 429 ở `before_request`/login/register. Giữ validation, `DUMMY_HASH` chống lộ thông tin qua thời gian, session/login/register.
- Frontend: `index.html` top bar mới (search không label, `.topbar-actions`, avatar button + menu email/Đăng xuất), xoá `<footer>`; `login.html`/`register.html` xoá subtitle + note 12 h; `app.js` xoá `loadHealth()`, thêm `initAccountMenu()` (click ngoài/Esc đóng, Esc trả focus); `app.css` topbar 1 hàng, search co giãn, theme/avatar tròn 36 px, menu dropdown, mobile 2 hàng (search full width), xoá `.foot`/`.auth-sub`/`.auth-note`/`.account*`.
- Asset `?v=20261110f` ở cả 3 trang; deploy backup `backup-2026-11-10-065537` và `-065723`, `deploy=ok`, health 3 mức OK.
- Test `infra/app-tests.sh`: bỏ block limiter logic + burst 140 cũ + restart reset; thêm burst 6 đăng ký (đều 201, không 429) và 70 POST (400, không 429/5xx) → **86 PASS / 0 FAIL**, `leftover_test_users=0`.
- Browser thật trên production: menu mở/đóng (click ngoài, Esc trả focus về avatar), email đúng, theme `auto → light → dark → auto`, `N` mở dialog, `/` focus search, `#footer` không tồn tại, không còn `.auth-sub`/`.auth-note`, **0 console error**.
- Ảnh: `ui-shots.mjs` bỏ điều kiện chờ footer, thêm meta `hasFooter/menuOpen/avatar`, thêm ảnh `ui-menu-light.png` → **8 ảnh**; `evidence/ui-shots.json` cập nhật.
- Dọn: purge `test-*`/`shot+*`/`verify+*` → `test_users=0`; production còn `users=1` (tài khoản thật của chủ demo) `tasks=0`.
- Đánh đổi: không còn chống spam ghi/dò mật khẩu/đăng ký hàng loạt phía app; nếu triển khai thật nên bật rate limiting ở Cloudflare hoặc thêm lại limiter.


## Việc chưa làm / giới hạn

- ~~Chưa có đăng nhập~~ → đã có login/logout + **đăng ký công khai** (session cookie 12 h, chặn API/trang khi chưa đăng nhập). Giới hạn còn lại: cookie ký phía client nên logout chỉ xoá cookie ở browser hiện tại, không thu hồi session đã copy; đổi `APP_SECRET_KEY` + restart mới vô hiệu hoá toàn bộ. Chưa có đổi/quên mật khẩu, xác thực email, CAPTCHA/2FA, khoá tài khoản.
- ~~Rate limit~~ → đã bỏ toàn bộ limiter ghi/login/register theo yêu cầu; không còn bộ đếm in-memory, không reset theo restart. Đánh đổi: không chống spam/dò mật khẩu ở tầng app; nên bật rate limiting ở Cloudflare nếu dùng thật.
- ~~Footer trạng thái~~ → đã bỏ; lỗi kết nối chỉ báo bằng toast/banner.
- Kéo–thả trên cảm ứng dùng nút `←`/`→` thay vì long-press drag (đề cho phép phương án thay thế); kéo chuột vẫn là HTML5 drag & drop.
- CSP không cho inline script/style: thêm script/style inline vào HTML sẽ bị chặn, phải để ở file riêng hoặc thêm hash/nonce.
- `/api/health?detail=1` chỉ mở cho localhost (phải SSH vào VM mới xem được).
- Không test mất toàn máy, PITR, failover (single instance, không bật archive_mode).
- Dump nằm cùng VM với DB.
- Cert Let's Encrypt hết hạn 2027-02-07; phụ thuộc `certbot.timer` (đã dry-run PASS, có deploy hook reload nginx). Nếu VM tắt lâu, cert có thể hết hạn.
- HSTS 180 ngày: browser đã truy cập sẽ ép HTTPS đến khi hết hạn kể cả khi rollback.
- `ssl=strict` áp cho cả zone: apex `akaine.io.vn` đang 522 (origin `167.254.69.146` unreachable); origin apex sau này phải có cert hợp lệ.
- Chưa chạy cleanup (đang cần demo).
