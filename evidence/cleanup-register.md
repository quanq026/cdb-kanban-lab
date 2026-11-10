# Dọn dữ liệu demo trên Neon + bật đăng ký công khai

- Ngày: `2026-11-10`
- Phạm vi: **chỉ Neon (production)**. Local docker `cdb-study` vẫn giữ seed 2 user + 5 task làm mốc lab/evidence.
- Lý do: yêu cầu "xoá hết những thứ kiểu demo" để web sạch, người dùng tự đăng ký.

> **Cập nhật sau purge:** production hiện `users=1` (tài khoản thật của chủ demo) `tasks=0`; tài khoản `test-*`/`shot+*`/`verify+*` đã purge (`test_users=0`). App đã bỏ rate limit, nên các dòng `429`/giới hạn 5 tài khoản ở mục 3 là lịch sử — xem `evidence/app-tests-nolimit.md`.

## 1. Backup trước khi xoá

```
pg_dump ... -t users -t tasks --data-only --column-inserts --no-owner
→ /home/azureuser/neon-demo-purge-2026-11-10-062210.sql (2594 bytes)
```

Lần chạy lại (idempotent, dữ liệu đã sạch) tạo thêm `neon-demo-purge-2026-11-10-062240.sql` (1137 bytes, không còn row).

## 2. Trước / sau khi xoá

```text
== truoc khi xoa ==
users=2
tasks=7
== sau khi xoa (owner) ==
users=0
tasks=0
== app_user nhin thay ==
users=0
tasks=0
demo-login.txt=removed
purge_backup=/home/azureuser/neon-demo-purge-2026-11-10-062210.sql
```

- Xoá theo thứ tự `tasks` → `users` (FK `tasks.user_id`).
- `/etc/cdb/demo-login.txt` (mật khẩu seed) đã xoá; không còn đường đăng nhập demo.
- Script: `infra/purge-neon-demo.sh` (dùng role owner trong `/etc/cdb/secrets.env`, không in secret).

## 3. Đăng ký công khai

- Endpoint `POST /api/register`: `{email, password}` → `201` + session; trùng email `409`; email sai/<8 ký tự/thiếu field `400`; quá 5 tài khoản thành công/giờ/IP `429`.
- Trang `/register` (link qua lại với `/login`), tự đăng nhập sau khi tạo.
- Hash scrypt (`werkzeug`), cùng cơ chế session/cookie với login.
- Trang login không còn ghi chú tài khoản demo.
- Asset tăng version `?v=20261110d` cho `app.css`/`app.js` (bắt buộc vì Cloudflare cache 4 h).

## 4. Dọn tài khoản do test/evidence tạo

`infra/purge-test-accounts.sh` xoá các email:

| Pattern | Nguồn |
|---|---|
| `test-%@example.test` | `infra/app-tests.sh` (tự xoá bằng trap, script này dọn phần sót) |
| `shot+%@local.test` | `infra/ui-shots.mjs` |
| `verify+%@local.test` | kiểm tra tay trên browser |

Kết quả lần chạy cuối:

```text
== truoc khi xoa ==
test_users=1
all_users=1
all_tasks=0
== sau khi xoa ==
test_users=0
all_users=0
all_tasks=0
purge_test_accounts=done
```

Production hiện tại: **0 user, 0 task** — board trống cho người đăng ký mới.

## 5. Rollback

Khôi phục dữ liệu demo (chỉ khi thật sự cần):

```bash
sudo -i
set -a; . /etc/cdb/secrets.env; set +a
export PGPASSWORD="$NEON_OWNER_PASSWORD"
psql "host=$NEON_HOST port=5432 dbname=studydb user=$NEON_OWNER_USER sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt" \
  -v ON_ERROR_STOP=1 -f /home/azureuser/neon-demo-purge-2026-11-10-062210.sql
```

Tắt đăng ký công khai (nếu cần): xoá route `/api/register` khỏi `app.py` và deploy lại bằng `scripts/deploy-app.ps1` (có backup + auto-rollback trong `infra/app-deploy.sh`).
