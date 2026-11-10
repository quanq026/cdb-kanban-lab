# Evidence — Auth, migration, purge

Phạm vi: login/logout (GĐ C), đăng ký công khai, migration `users.password_hash`, purge dữ
liệu demo. Schema `tasks.position`/`created_at`/`updated_at` đã làm — xem
[schema.md](schema.md).

## 1. Thiết kế

| Hạng mục | Cách làm |
|---|---|
| Lưu mật khẩu | `users.password_hash text` (nullable), scrypt `32768:8:1` của werkzeug, salt riêng |
| User chưa có hash | `password_hash IS NULL` → mọi mật khẩu sai (401), không có đường đăng nhập ẩn |
| Phiên | Cookie ký `cdb_session` (itsdangerous), không session server-side; `HttpOnly`, `SameSite=Lax`, `Secure`, 12 h |
| Chống dò thời gian | so sánh `DUMMY_HASH` khi email không tồn tại |
| Chặn | `before_request`: API thiếu session → 401 JSON; trang → 302 `/login` |
| Chủ sở hữu | `user_id` phải khớp `session.uid` → 403; task người khác → 404 |
| Secret | `APP_SECRET_KEY` trong `/etc/cdb/app.env` (600 root), không in |
| Đăng ký | `POST /api/register` công khai, email hợp lệ + mật khẩu 8–200, tự đăng nhập; trùng → 409 |
| Rate limit | **Đã bỏ toàn bộ** (login/ghi/đăng ký) — xem [../security.md](../security.md) §6 |

## 2. Migration

File: `infra/maintenance/sql/2026-11-10-login.sql` và `...-login-rollback.sql`; chạy bằng
`infra/maintenance/auth-migrate.sh` / `auth-rollback.sh` (role owner từ `secrets.env`).

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

Áp dụng **giống nhau** trên local docker và Neon:

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

Các dòng hash trên là **trước purge demo**; hiện production `users=1` (tài khoản thật).
`app_user` giữ nguyên quyền mức bảng, không cấp thêm.

### Rollback diễn tập

Chạy trong transaction rồi `ROLLBACK` trên local để không phá dữ liệu demo:

```text
after_drop=0        <- sau DROP COLUMN, cột biến mất
ROLLBACK
after_rollback=1    <- ROLLBACK khôi phục nguyên trạng
```

Rollback thật: chạy `auth-rollback.sh`, xoá `APP_SECRET_KEY` khỏi `/etc/cdb/app.env`,
xoá `login.html`, khôi phục `app.py`/`index.html` từ backup, restart.

## 3. Ma trận lỗi (đã test)

| Tình huống | HTTP | `code` |
|---|---|---|
| Chưa đăng nhập, gọi `/api/*` | 401 | `unauthenticated` |
| Chưa đăng nhập, mở `/` | 302 → `/login` | – |
| Đã đăng nhập, mở `/login` hoặc `/register` | 302 → `/` | – |
| Đăng ký email sai / thiếu field / body không JSON | 400 | `invalid_request` |
| Đăng ký mật khẩu < 8 hoặc > 200 | 400 | `invalid_request` |
| Đăng ký email đã tồn tại | 409 | `unique_violation` |
| Đăng ký thành công | 201 | – (set session) |
| Sai email/mật khẩu / user chưa có hash | 401 | `invalid_credentials` |
| Thiếu `email`/`password` | 400 | `invalid_request` |
| `user_id` khác session | 403 | `forbidden_user` |
| Task không tồn tại hoặc của user khác | 404 | `not_found` |
| Sau logout, `/api/me` | 401 | `unauthenticated` |

> Các dòng `429` (login 8 lần/5 phút, đăng ký 5/giờ) trong tài liệu cũ là **lịch sử**;
> app hiện không còn limiter.

Cookie thật (đã che giá trị):

```text
set-cookie: cdb_session=<redacted>; Expires=Tue, 10 Nov 2026 16:05:55 GMT; Secure; HttpOnly; Path=/; SameSite=Lax
```

## 4. Kiểm chứng browser

### Trước purge (seed `an@example.test`)

| Bước | Kết quả |
|---|---|
| `/` chưa đăng nhập | 302 `/login`, không lộ board |
| Sai mật khẩu | 401, lỗi dưới form |
| Đăng nhập đúng | 200 → `/`, board 5 việc `3/1/1` |
| Theme | `auto → light → dark → auto` |
| Thêm/sửa/chuyển/lọc/`N`/`/`/xoá | OK, toast ~500 ms |
| Đăng xuất | 200 → `/login`; `/api/me`, `/api/tasks` 401 |
| Console | 0 error |

### Sau purge + đăng ký (Neon sạch, `verify+<ts>@local.test`)

| Bước | Kết quả |
|---|---|
| `/register` | 200, 3 field, link qua `/login` |
| Mật khẩu 7 ký tự / nhập lại sai | chặn client, không gửi request |
| Đăng ký hợp lệ | 201 → tự đăng nhập, board trống `0/0/0` |
| Tạo / chuyển / xoá việc | 201 / PATCH 200 / DELETE 200, về 3 empty state |
| Đăng xuất | 200 → `/login` |
| Đăng ký trùng qua form | 409 `du lieu da ton tai` |
| Console | 0 error |

Sau test: `purge-test-accounts.sh` xoá `test-*`/`shot+*`/`verify+*`.

## 5. Purge demo Neon

- Phạm vi: **chỉ Neon**; local docker giữ seed 2 user / 5 task làm mốc lab.
- Backup trước xoá: `pg_dump -t users -t tasks --data-only --column-inserts --no-owner`
  → `/home/azureuser/neon-demo-purge-2026-11-10-062210.sql` (2594 bytes).
- Thứ tự xoá: `tasks` → `users` (FK). `/etc/cdb/demo-login.txt` đã xoá.

```text
== truoc khi xoa ==
users=2  tasks=7
== sau khi xoa (owner) ==
users=0  tasks=0
== app_user nhin thay ==
users=0  tasks=0
purge_backup=/home/azureuser/neon-demo-purge-2026-11-10-062210.sql
```

Chạy lại idempotent tạo thêm `...-062240.sql` (1137 B, không còn row).

### Dọn tài khoản test

| Pattern | Nguồn |
|---|---|
| `test-%@example.test` | `infra/test/app-tests.sh` (trap tự xoá; script dọn phần sót) |
| `shot+%@local.test` | `infra/test/ui-shots.mjs` |
| `verify+%@local.test` | kiểm tra tay trên browser |

```text
== truoc khi xoa ==
test_users=1  all_users=1  all_tasks=0
== sau khi xoa ==
test_users=0  all_users=0  all_tasks=0
purge_test_accounts=done
```

Production hiện: `users=1` (tài khoản thật) `tasks=0`; không còn tài khoản test.

## 6. Phục hồi dữ liệu demo (nếu thật sự cần)

```bash
sudo -i
set -a; . /etc/cdb/secrets.env; set +a
export PGPASSWORD="$NEON_OWNER_PASSWORD"
psql "host=$NEON_HOST port=5432 dbname=studydb user=$NEON_OWNER_USER \
  sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt" \
  -v ON_ERROR_STOP=1 -f /home/azureuser/neon-demo-purge-2026-11-10-062210.sql
```

Purge không đụng schema: `users`/`tasks`/`password_hash`/`position`/timestamp giữ nguyên,
chỉ xoá row. Tải backup về trước khi xoá VM nếu muốn giữ.

## 7. File liên quan

- `app/app.py` — login/logout/me/register, guard session, `same_user`, cache header.
- `app/login.html`, `app/register.html`, `app/app.css` (`.auth-*`), `app/app.js`
  (`initLogin`, `initRegister`, logout, avatar menu, theme).
- `infra/maintenance/auth-{migrate,rollback,secret}.sh` + `sql/2026-11-10-login*.sql`.
- `infra/test/app-tests.sh`, `infra/test/ui-shots.mjs`.
- `infra/maintenance/purge-{neon-demo,test-accounts}.sh`.
