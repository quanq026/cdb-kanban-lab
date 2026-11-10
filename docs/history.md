# Lịch sử

Nhật ký các mốc, quyết định và lỗi thực tế. Output chi tiết nằm ở `docs/evidence/`; bản
đầy đủ trước khi gộp nằm trong git history commit `6d3a2b7` (`PROGRESS.md`).

## 1. Tổng quan

| Mốc | Nội dung | Kết quả |
|---|---|---|
| GĐ 1 | Azure VM, swap, Docker, nginx, psql 17, venv | `vm-cdb` chạy, 2 vCPU/4 GiB |
| GĐ 2 | Postgres local trong Docker | 2 user + 5 task, `app_user` least privilege, persistence, dump/restore trùng khớp |
| GĐ 3 | Restore sang Neon | `studydb` + `app_user`, TLS verify-full |
| GĐ 4 | Web Kanban Flask | HTTPS 200, health trả `app_user` |
| GĐ 5 | Evidence | 10 file lệnh + output thật |
| GĐ 6 | Tổng kết | README + cleanup |
| + | Domain/HTTPS | Let's Encrypt, TLS 1.3, Cloudflare 521 → 200 |
| GĐ A | Backend bền | pool check/reconnect/retry, JSON error, log, health 2 mức (khi đó còn rate limit) |
| GĐ B | UI/UX | 1 CSS + 1 JS, responsive, optimistic, inline edit, a11y, dark mode |
| GĐ B+ | Thiết kế | chọn **B: warm neutral + teal**, token light/dark |
| GĐ C | Login/logout | `users.password_hash` scrypt + session cookie |
| GĐ C | Đăng ký + purge demo | `/api/register`, Neon sạch, 82 test |
| GĐ C | Bỏ rate limit + top bar gọn + bỏ footer | 86 test, 8 ảnh |
| GĐ C | Schema còn lại | `tasks.position`, `created_at`, `updated_at` + trigger; 108 test |

## 2. 2026-11-09 — dựng nền

### GĐ 1 — Azure (16:23–16:30)

- `az vm create` fail 4 lần vì SKU/capacity; chốt `Standard_B2pls_v2` (Arm64) + Ubuntu
  24.04 arm64. VM private `10.0.1.4`, public `20.48.104.156`.
- NSG: SSH 22 ← IP nhà; 80/443 public; **không 5432**.
- Provision: swap 2 G, Docker 29.1.3, nginx 1.24.0, psql 17.11, Python 3.12.3.

### GĐ 2 — Postgres local (16:31–16:42)

- Container `cdb-study`, volume `cdb-study-data`, `127.0.0.1:55432`, DB `studydb`.
- `app_user` tạo bằng `CREATE ROLE ... LOGIN` + `\password` (stdin): không superuser,
  không đọc `pg_authid`, không `DROP TABLE`.
- Persistence: xoá container giữ volume → tạo lại → users=2, tasks=5, md5 trùng.
- Backup: dump 6101 B / 125 ms; restore 228 ms exit 0; count + md5 + index trùng.

### GĐ 3 — Neon (16:39–16:45)

- Project `icy-sound-48483515`, branch `br-silent-darkness-a1gqqmlj`, endpoint
  `ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech`.
- Chỉ thêm DB `studydb` (không đụng `neondb`); `pg_restore --no-owner --no-privileges`
  3107 ms; md5 trùng local.
- TLS: cert `CN=*.ap-southeast-1.aws.neon.tech`, `verify-full` OK; app dùng endpoint trực tiếp.

### GĐ 4 — Web (16:45–16:52)

- Flask 3.1.3 + psycopg 3.3.8 + psycopg_pool 3.3.3, gunicorn 2 worker, nginx :80.
- Health ban đầu trả cả `db_host`/`database`/`sslmode` (sau này tách 2 mức).

### GĐ 5–6 — Evidence & tổng kết (16:48–17:00)

- 10 file evidence từ lệnh chạy thật: constraints, transaction, index, persistence,
  backup-restore, cloud, monitoring, https, diagram + cost.
- Quét secret: chỉ tên host/user/ID, không có mật khẩu/API key.
- 5432 từ ngoài: `TcpTestSucceeded=False`; 80/22: True.

## 3. Domain + HTTPS (10:04–10:12)

- DNS `kanban` → Cloudflare proxy → origin. `https://` trả **521** vì origin chỉ listen 80.
- Khắc phục: webroot ACME → certbot HTTP-01 → nginx 443 TLS 1.2/1.3.
- `http://20.48.104.156/` vẫn 200 (sau hardening chuyển 301).
- Thêm deploy hook để cert gia hạn xong reload nginx.

## 4. Hardening (2026-11-10 08:40–08:55)

- IP nhà đổi `123.24.61.51` → `118.70.140.18` → SSH timeout; cập nhật NSG, OK lại.
- Cloudflare (chỉ zone `akaine.io.vn`): `ssl full → strict`, `min_tls_version 1.0 → 1.2`;
  đọc lại `always_use_https`, `automatic_https_rewrites`, `tls_1_3`, `http3`, `brotli` đều bật.
- nginx: redirect 80 → HTTPS (chừa ACME), thêm ACME ở 443, `server_tokens off`, header
  HSTS/nosniff/SAMEORIGIN/Referrer-Policy/Permissions-Policy.
- Kiểm chứng: HTTP 301 → 200; header xuyên Cloudflare; TLS 1.1 bị từ chối;
  `certbot renew --dry-run` PASS.
- `.gitignore` thêm `.env*`, `login-azure.ps1`; quét lại repo chỉ file đó chứa secret Azure.

## 5. GĐ A — backend bền (10:00–10:20)

- Backup trước sửa: `/opt/cdb/app/backup-2026-11-10/`.
- Pool: `min=1 max=5 timeout=20 max_idle=120 max_lifetime=1800`,
  `check_connection`, `reconnect_timeout=30`, retry 1 lần khi `OperationalError`.
- `DELETE` chuyển sang query string; `PATCH` nhận `status` và/hoặc `title`.
- Error handler thống nhất `{error, code}`: 400/409/404/503/500.
- Log request ra journald; `ProxyFix` + `real_ip_header CF-Connecting-IP` chỉ tin Cloudflare.
- `/api/health` 2 mức; CSP không `unsafe-inline`.
- Test 46 case; rate limit khi đó 60/phút.

## 6. GĐ B — giao diện (10:20–10:45)

- Tách `index.html` + `app.css` + `app.js`; bỏ inline để CSP chặt.
- Desktop 3 cột; ≤760px snap ngang ~86vw (chụp đúng 375px).
- Drag & drop chuột; nút `←`/`→` cho cảm ứng; cả hai optimistic + rollback.
- Inline edit, skeleton, banner chậm > 2 s, toast, `<dialog>` xác nhận, đếm/lọc, `N`, `/`.
- A11y: `aria-label`, `focus-visible`, skip-link, `aria-live`.
- Dark mode theo `prefers-color-scheme`; khi đó còn footer.

## 7. GĐ B+ — design B + login (11:00–12:10)

- Chọn hướng **B: warm neutral + teal** (`#fbfaf7`/`#161513`, accent `#0f766e`/`#2dd4bf`),
  token CSS, chip trạng thái, radius 10–14 px, motion 150–200 ms + `prefers-reduced-motion`.
- Login/logout thật: `users.password_hash` nullable, scrypt; cookie ký `cdb_session`
  (Secure/HttpOnly/SameSite=Lax/12 h); `APP_SECRET_KEY` trong `/etc/cdb/app.env`.
- `before_request` chặn trang + API; `same_user()` chống lộ dữ liệu; task người khác 404.
- Migration chạy giống local + Neon; rollback diễn tập trong transaction.
- Test 67 case; browser thật OK, 0 console error.

## 8. Đăng ký + purge demo (12:10–13:40)

- `POST /api/register` công khai, email chuẩn hoá + regex, mật khẩu 8–200, scrypt, 201 +
  tự đăng nhập; trùng email 409.
- Frontend `/register` 3 field, validate client; `/login` thêm link; asset `?v=20261110d`.
- Purge **chỉ Neon**: backup 2594 B → trước `users=2 tasks=7`, sau `users=0 tasks=0`;
  local docker giữ seed.
- Dọn `test-*`/`shot+*`/`verify+*`; test 82 case; ảnh 7 mục.
- Đo lại cold start sau idle 330 s: 1.857 s / 0.736 s / 0.314 s, không 503.

## 9. Bỏ rate limit + top bar gọn + bỏ footer (14:45–15:20)

- Bỏ **toàn bộ** limiter (ghi 60/phút, login 8 lần sai/5 phút, đăng ký 5/giờ); xoá
  `threading`/`deque`/hằng số/hàm limiter và mọi call 429.
- Top bar: brand · tìm kiếm · theme · avatar menu (email + Đăng xuất) · Thêm việc.
- Bỏ footer; bỏ subtitle + ghi chú 12 h ở login/register.
- Asset `?v=20261110f`; deploy backup `backup-2026-11-10-065537`, `-065723`.
- Test **86 PASS / 0 FAIL**; burst 6 đăng ký đều 201, 70 POST đều 400, không 429/5xx.
- 8 ảnh mới gồm `ui-menu-light.png` (menu mở); production `users=1 tasks=0` (tài khoản thật).

## 10. GĐ C schema — position + timestamps (07:35–08:05)

- Migration `sql/2026-11-10-task-order.sql`: thêm `tasks.position integer NOT NULL DEFAULT 0`,
  `created_at`/`updated_at timestamptz NOT NULL DEFAULT now()`; backfill `position` theo
  `row_number() OVER (PARTITION BY user_id, status ORDER BY id)`; index mới
  `idx_tasks_user_status_position`; trigger `trg_tasks_updated_at` (giữ `updated_at` ở DB).
- Rollback `...-task-order-rollback.sql`: bỏ trigger/function/3 cột, tạo lại
  `idx_tasks_user_status`. Diễn tập trong transaction local: up → `position_nulls=0`,
  index/trigger OK → down → `down_columns=0`, index cũ OK → `ROLLBACK`.
- API: task trả thêm `position`, `created_at`, `updated_at` (ISO 8601); GET sắp
  `ORDER BY position, id`; POST append cuối `todo`; PATCH nhận `position`, đổi status thì
  append cuối cột đích; renumber `0..n-1` trong một transaction có `FOR UPDATE`.
- UI: kéo–thả đúng vị trí (không chỉ đổi cột) + nút `↑`/`↓` cho cảm ứng/bàn phím;
  optimistic + rollback; tạm tắt reorder khi đang lọc. Asset `?v=20261110g`.
- Migration chạy thật trên local Docker + Neon; app cũ vẫn healthy trong lúc migrate.
  Deploy backup `backup-2026-11-10-074504`, health 3 mức OK.
- Test **108 PASS / 0 FAIL** (`leftover_test_users=0`); browser headless xác nhận
  `↑` ×2 đưa task cuối lên đầu, `→` sang Doing, reload vẫn giữ thứ tự, 0 console error.
- Production sau purge: `users=1 tasks=0`; schema `id,user_id,title,status,position,created_at,updated_at`,
  index mới + trigger hiện diện.

## 11. Chỉ báo kéo–thả + dữ liệu mẫu (08:09–08:20)

- Seed 16 việc mẫu cho tài khoản thật: Todo 8 / Doing 5 / Done 3, `position` liên tục
  `0..n-1` (script một lần, không commit); production `users=1 tasks=16`.
- Kéo–thả có **ô chèn** đúng index: rê tới đâu, một khối dashed teal cao dần (180 ms) đẩy
  các thẻ bên dưới trượt ra; nhãn `Thả để chèn vào đây`; viền cột sáng khi hover.
- Drop lấy index từ chính ô chèn (không đoán lại); kéo sang cột khác cũng hiện ô chèn;
  `dragleave` ra ngoài board thì dọn; tôn trọng `prefers-reduced-motion`.
- Test CDP mới `infra/test/ui-drag-check.mjs`: kéo **d** lên đầu (slot index 0, cao 72 px,
  opacity .99), thả → `[d,a,b,c]`; kéo **c** sang Doing → `[c]`; reload giữ nguyên;
  0 console error. Ảnh `docs/evidence/images/ui-drag-light.png`.
- Asset `?v=20261110i`; deploy backup `backup-2026-11-10-081130`, `-081214`; health 3 mức OK.
- Sau khi dọn tài khoản test: `users=1 tasks=16`, không còn `shot+*`/`test-*`.

## 12. Lỗi đã gặp & cách sửa

| # | Lỗi | Nguyên nhân | Cách sửa |
|---:|---|---|---|
| 1 | `GRANT ... <<SQL` qua `docker exec -i` không áp dụng | stdin bị `\password` chiếm | tách nhiều `-c` |
| 2 | So sánh `studydb_restore.users` | PostgreSQL không hỗ trợ cross-database | query riêng từng DB |
| 3 | `\password` trên Neon bị từ chối | control plane chỉ nhận plaintext | `ALTER ROLE ... PASSWORD :'pw'` qua psql variable |
| 4 | `certificate verify failed` | `sslrootcert=system` không hợp libpq bundled | trỏ CA bundle Ubuntu, vẫn `verify-full` |
| 5 | bash lỗi `$'\r'` | PowerShell scp file CRLF | `run-remote.ps1` chuẩn hoá LF |
| 6 | health-check qua cổng 80 tưởng OK | nginx trả 301, `curl -f` vẫn pass | check `https://...:443 --resolve 127.0.0.1` |
| 7 | POST `user_id=null` khi test tay | test chạy trước `/api/users` | chờ init xong |
| 8 | Banner `#slow` không ẩn | `.slow{display:flex}` đè `[hidden]` | `.slow[hidden]{display:none}` |
| 9 | Test chuyển cột bị bỏ qua | guard `busy` chống double-submit | test chờ `busy` hết |
| 10 | Board trắng, `TypeError ... addEventListener of null` | Cloudflare/browser cache JS cũ | bump `?v=`, origin `no-cache` |
| 11 | 4 FAIL đầu | test kỳ vọng 403 thay vì 404; kiểm cookie bằng GET | sửa test, không sửa app |
| 12 | PowerShell hiểu `\|\|` trong SQL | shell parse | đưa SQL vào `.sh`, chạy qua `run-remote.ps1` |
| 13 | `ui-shots` timeout | fetch ngoài trang không tự render | `Page.navigate` lại sau đăng ký/tạo task |
| 14 | browser ref stale | snapshot mới làm ref cũ hết hiệu lực | snapshot + click cùng lượt |
| 15 | purge thiếu env | chưa source `app.env` | source trước khi psql |
| 16 | `521` Cloudflare | origin không có 443 | ACME + cert + nginx 443 |
| 17 | `http2 on;` unknown directive | nginx 1.24 | `listen 443 ssl http2;` |
| 18 | 500 thoáng qua khi Neon suspend | `AdminShutdown` | pool check + reconnect_timeout + retry |
| 19 | Local test 503 `PoolTimeout` | `sslmode=disable` vẫn kèm `sslrootcert=system` | chỉ thêm `sslrootcert` khi `sslmode` bắt đầu bằng `verify` |
| 20 | UI check báo reorder sai | test bấm `↑` trên "card cuối" sau mỗi lần → trả về thứ tự cũ | bấm theo `data-id` của task mục tiêu |

## 13. Việc chưa làm

- Chưa có đổi/quên mật khẩu, xác thực email, CAPTCHA/2FA, khoá tài khoản.
- Chưa có rate limit (đã bỏ theo yêu cầu).
- Chưa test mất máy/PITR/failover; chưa backup định kỳ ngoài VM.
- Chưa chạy cleanup vì còn demo.
