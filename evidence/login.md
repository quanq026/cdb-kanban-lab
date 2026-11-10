# Đăng nhập / đăng xuất thật — session, migration, kiểm chứng

- Ngày: `2026-11-10`
- Phạm vi được duyệt: **login/logout** (GĐ C) + **đăng ký công khai** (yêu cầu bổ sung 2026-11-10). Các cột `tasks.position`, `created_at`, `updated_at` **chưa** làm.
- Web: <https://kanban.akaine.io.vn/> · trang đăng nhập: <https://kanban.akaine.io.vn/login>

> **Cập nhật sau file này (2026-11-10):** app đã **bỏ toàn bộ rate limit**, bỏ footer, thay chip tài khoản bằng **avatar menu** (email + Đăng xuất), bỏ subtitle/ghi chú 12 h trên trang auth. Các bảng 429/limiter và dòng footer trong file này là trạng thái lịch sử; bộ test hiện tại ở `evidence/app-tests-nolimit.md`, giao diện ở `evidence/ui.md`.

## 1. Thiết kế đã chọn

| Hạng mục | Cách làm |
|---|---|
| Lưu mật khẩu | `users.password_hash text` (nullable). Hash bằng `werkzeug.security.generate_password_hash` — thuật toán thực tế **scrypt `32768:8:1`** (mặc định werkzeug 3.x), có salt riêng mỗi user |
| User chưa có hash | `password_hash IS NULL` → mọi mật khẩu đều sai (trả 401), không có đường đăng nhập ẩn |
| Phiên | Cookie ký `cdb_session` của Flask (`itsdangerous`), **không** lưu session server-side; `HttpOnly`, `SameSite=Lax`, `Secure`, hết hạn 12 giờ |
| Chống dò mật khẩu | So sánh với `DUMMY_HASH` khi email không tồn tại để thời gian phản hồi tương đương; đếm **chỉ lần sai** — 8 lần / 5 phút / IP → 429 |
| Chặn API | `before_request`: mọi `/api/*` (trừ `/api/login`, `/api/health`) và mọi trang (trừ `/login`, asset tĩnh) yêu cầu session; thiếu → API 401 JSON, trang → 302 `/login` |
| Chủ sở hữu dữ liệu | `user_id` trong body/query **phải khớp** `session.uid` → lệch trả 403 `forbidden_user`; task của user khác trả 404 (không lộ tồn tại) |
| Secret | `APP_SECRET_KEY` thêm vào `/etc/cdb/app.env` (600 root); không in giá trị, không nằm trong repo |
| Đăng ký | `POST /api/register` công khai: email hợp lệ + mật khẩu ≥ 8 ký tự, hash scrypt, tạo user rồi **tự đăng nhập**; 5 tài khoản thành công/giờ/IP → 429; trùng email → 409 |
| Dữ liệu demo | **Đã xoá toàn bộ** user/task demo trên Neon (production sạch, board trống cho user mới). Local docker vẫn giữ seed làm mốc lab |

## 2. Migration & rollback

File chuẩn: `infra/migration-2026-11-10-login.sql` và `infra/migration-2026-11-10-login-rollback.sql`; chạy tự động bằng `infra/login-migrate.sh` / `infra/login-rollback.sh` (DDL chạy bằng role owner trên Neon lấy từ `/etc/cdb/secrets.env`).

```sql
-- up
BEGIN;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash text;
COMMENT ON COLUMN users.password_hash IS 'scrypt (werkzeug) - NULL = chua dat mat khau';
COMMIT;

-- down
BEGIN;
ALTER TABLE users DROP COLUMN IF EXISTS password_hash;
COMMIT;
```

Đã áp dụng **giống nhau** trên local docker (`cdb-study` / `studydb`) và Neon (`studydb`). `app_user` giữ nguyên quyền mức bảng nên đọc/ghi được cột mới, **không** cấp thêm quyền nào:

```text
== local docker: cot users ==
id:bigint:NO
email:text:NO
password_hash:text:YES
== neon: cot users + hash prefix (khong in hash) ==
id:bigint:NO
email:text:NO
password_hash:text:YES
scrypt:32768:8:1
scrypt:32768:8:1
0                      <- so user chua dat mat khau

== neon: quyen cua app_user tren users/tasks ==
tasks:DELETE / tasks:INSERT / tasks:SELECT / tasks:UPDATE
users:DELETE / users:INSERT / users:SELECT / users:UPDATE
app_user super=false createdb=false createrole=false
```

> Các dòng hash `scrypt:32768:8:1` ở trên là **trước khi purge demo**. Hiện production `users=0`; hash scrypt vẫn là cơ chế dùng cho tài khoản đăng ký mới.

Rollback đã được diễn tập **trong transaction rồi ROLLBACK** trên local để không phá dữ liệu đang demo:

```text
after_drop=0        <- sau khi DROP COLUMN, cột biến mất
ROLLBACK
after_rollback=1    <- ROLLBACK khôi phục nguyên trạng
```

Muốn rollback thật: `powershell -File scripts\run-remote.ps1 -Path infra\login-rollback.sh` rồi xoá `APP_SECRET_KEY` khỏi `/etc/cdb/app.env`, restart `cdb-kanban` (xem `cleanup.md` §3d).

## 3. Ma trận lỗi xác thực (đã test thật)

| Tình huống | HTTP | `code` |
|---|---|---|
| Chưa đăng nhập, gọi `/api/*` | 401 | `unauthenticated` |
| Chưa đăng nhập, mở `/` | 302 → `/login` | – |
| Đã đăng nhập, mở `/login` hoặc `/register` | 302 → `/` | – |
| Đăng ký email sai định dạng / thiếu field / body không phải JSON | 400 | `invalid_request` |
| Đăng ký mật khẩu < 8 ký tự (hoặc > 200) | 400 | `invalid_request` |
| Đăng ký email đã tồn tại | 409 | `unique_violation` |
| Đăng ký thành công | 201 | – (set session, vào board rỗng) |
| Đăng ký quá 5 tài khoản/IP/giờ | 429 | `rate_limited` (+ `Retry-After: 3600`) |
| Sai email hoặc sai mật khẩu / user chưa có hash | 401 | `invalid_credentials` |
| Thiếu `email`/`password` trong body | 400 | `invalid_request` |
| `user_id` khác user trong session | 403 | `forbidden_user` |
| Task không tồn tại **hoặc** thuộc user khác | 404 | `not_found` |
| Sai mật khẩu 9 lần / 5 phút / IP | 429 | `rate_limited` (+ `Retry-After: 300`) |
| Sau logout, gọi `/api/me` | 401 | `unauthenticated` |

Cookie thật trả về (đã che giá trị):

```text
set-cookie: cdb_session=<redacted>; Expires=Tue, 10 Nov 2026 16:05:55 GMT; Secure; HttpOnly; Path=/; SameSite=Lax
```

## 4. Kiểm chứng trên browser thật

Tab Chromium thật (OpenCode browser tool), dữ liệu Neon:

> Mục này ghi lần kiểm chứng **trước khi xoá demo** (tài khoản seed `an@example.test`). Sau khi purge + thêm đăng ký, luồng mới được kiểm chứng lại ở §4b.

| Bước | Kết quả |
|---|---|
| Mở `/` khi chưa đăng nhập | 302 → `/login`, thấy form đăng nhập, không lộ board |
| Gửi sai mật khẩu (fetch) | 401 `invalid_credentials`, form hiện lỗi, không đổi trang |
| Đăng nhập đúng | 200, chuyển về `/`, board render 5 việc, đếm `3/1/1` |
| Chip tài khoản | `an@example.test`, avatar chữ `a` |
| Footer | `Kết nối database: OK · user: app_user` |
| Theme toggle | `auto → light → dark → auto`, đổi màu nền `rgb(251,250,247)` ↔ `rgb(22,21,19)` |
| Thêm / sửa / chuyển cột / lọc / `N` / `/` / xoá có xác nhận | Tất cả OK, toast `Đã thêm việc` và `Đã xoá việc` (đo được sau ~500 ms) |
| Đăng xuất | 200 → `location.replace("/login")`; gọi lại `/api/me` = 401, `/api/tasks` = 401 |
| Console | **0 error** |

Ảnh: `evidence/ui-login-light.png` (trang đăng nhập), `ui-desktop-light/dark.png`, `ui-mobile-light/dark.png`; metadata thật ở `evidence/ui-shots.json`.

## 4b. Đăng ký → board trống → thêm/chuyển/xoá → đăng xuất (Neon sạch)

Chạy trên production sau khi purge, tài khoản `verify+<ts>@local.test` tạo rồi xoá ngay sau test:

| Bước | Kết quả |
|---|---|
| Mở `/register` | 200, form 3 field (Email, Mật khẩu, Nhập lại), link "Đã có tài khoản? Đăng nhập" |
| Mật khẩu 7 ký tự | Chặn ở client: `Mật khẩu phải có ít nhất 8 ký tự.`, không gửi request |
| Nhập lại mật khẩu sai | `Mật khẩu nhập lại không khớp.` |
| Đăng ký hợp lệ | 201 → tự đăng nhập, chuyển `/`, **board trống** (0/0/0, 3 empty state), footer `Kết nối database: OK · user: app_user` |
| Tạo việc qua nút "Thêm việc" | `POST /api/tasks` 201, Todo = 1, toast `Đã thêm việc` |
| Chuyển cột bằng nút → | `PATCH /api/tasks/55` → Doing = 1, chip `Doing` |
| Xoá việc | Dialog xác nhận `#55 — Việc kiểm thử đăng ký (Doing)`; bấm Xoá → `DELETE /api/tasks/55?user_id=38` → 0/0/0, 3 empty state |
| Đăng xuất | 200 → `/login`, form đăng nhập hiện lại |
| Đăng ký trùng email qua form | 409, inline `du lieu da ton tai` |
| API đăng ký (fetch trên trang thật) | email sai → 400 `invalid_request`; mật khẩu 7 ký tự → 400; email trùng → 409 `unique_violation` |
| Console | **0 error** |

Sau test: `infra/purge-test-accounts.sh` xoá các tài khoản `test-*`/`shot+*`/`verify+*`; production còn `users=0 tasks=0`.

## 5. Lỗi gặp trong lúc làm

1. **Cache asset cũ:** Cloudflare/browser vẫn phục vụ `app.js` bản trước nên HTML mới chạy JS cũ → `TypeError: ... addEventListener of null`, màn hình trắng. Sửa: gắn `?v=20261110c` cho `app.css`/`app.js` trong cả 2 trang; origin trả `Cache-Control: no-cache` cho 2 file này (trang `/`, `/login`, `/api/*` vẫn `no-store`). Đo thật: origin `no-cache`, nhưng qua Cloudflare vẫn thấy `cache-control: max-age=14400` → **tăng `?v=` là bắt buộc** mỗi lần đổi build.
2. **Test kỳ vọng sai (không phải lỗi app):** lần chạy đầu 4 FAIL vì (a) mong task của user khác trả 403 nhưng app trả 404 để không lộ tồn tại, (b) kiểm cookie bằng `GET /api/login` thay vì `POST`. Đã sửa test → 67/67.
3. **PowerShell + `||`:** câu SQL có `||` bị PowerShell hiểu là toán tử → phải đưa vào file `.sh` chạy qua `run-remote.ps1`, không nhét vào chuỗi `ssh "..."`.

## 6. File liên quan

- `app/app.py` — login/logout/me/register, guard session, `same_user`, login/register limiter, cache header cho asset.
- `app/login.html`, `app/register.html`, `app/app.css` (`.auth-*`, `.auth-alt`), `app/app.js` (`initLogin`, `initRegister`, logout, chip tài khoản, theme).
- `infra/login-migrate.sh`, `login-rollback.sh`, `login-secret.sh`, `migration-2026-11-10-login*.sql`.
- `infra/app-tests.sh` (82 case, tự tạo/tự xoá tài khoản) → output ở `evidence/app-tests-register.md`.
- `infra/ui-shots.mjs` (tự đăng ký `shot+<ts>@local.test`, không cần mật khẩu seed).
- `infra/purge-neon-demo.sh`, `infra/purge-test-accounts.sh` — dọn demo và tài khoản test.
