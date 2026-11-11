# Kiểm thử

## 1. CI smoke — 57 case

| | |
|---|---|
| Workflow | `.github/workflows/ci.yml` (push/PR `main`, `workflow_dispatch`) |
| Runner | `ubuntu-latest` + service `postgres:17`, DB `studydb` |
| Chuẩn bị | cài `app/requirements.txt`, apply `infra/setup/schema.sql`, tạo `app_user` LOGIN least-privilege (assert `rolsuper=f`) |
| Static | `py_compile`, `node --check app/app.js`, `bash -n` + `shellcheck`, `ruff check app .github/scripts` |
| Test | `python .github/scripts/ci-smoke.py` — **57 PASS / 0 FAIL** |

`ci-smoke.py` dùng Flask test client (không cần gunicorn/nginx): auth 401/302, register
201 + trùng 409, `/api/me`, tạo task `position=0,1,2`, reorder trong cột, đổi cột,
validate (title rỗng/201 ký tự, status sai, position âm, thiếu field), timestamp
(`updated_at` tăng, `created_at` giữ), delete 200/404, logout/login, health 2 mức, và
tự dọn `ci-*` (kết thúc `no leftover ci-* users`).

Chạy local (cần Postgres đã apply schema và env `DB_*` trỏ tới DB đó):

```bash
python .github/scripts/ci-smoke.py
```

Deploy tự chạy sau CI xanh trên `main` qua self-hosted runner `cdb-vm`; xem
[operations.md](operations.md) §2.

## 2. Kiểm thử giao diện (thủ công)

| Bước | Kỳ vọng |
|---|---|
| `/` chưa đăng nhập | 302 `/login`, không lộ board |
| Đăng ký mật khẩu 7 ký tự / nhập lại sai | chặn ở client, không gửi request |
| Đăng ký hợp lệ | 201 → `/`, board trống `0/0/0` + 3 empty state |
| Footer | `#footer` = `null` |
| Menu avatar | mở email + Đăng xuất; click ngoài/Esc đóng, Esc trả focus |
| Theme | `auto → light → dark → auto`; nền `rgb(251,250,247)` ↔ `rgb(22,21,19)` |
| `N` / `/` | mở dialog thêm việc / focus tìm kiếm |
| Thêm/sửa/chuyển/xoá | optimistic, toast, dialog xác nhận; lỗi thì hoàn tác |
| Sắp thứ tự trong cột | nút `↑`/`↓` (ẩn tác dụng khi đang lọc) + kéo–thả; reload vẫn giữ thứ tự |
| Kéo–thả | có ô chèn nhấp nháy đúng vị trí, các thẻ bên dưới trượt ra; thả là chèn đúng index |
| Chuyển cột `←`/`→` hoặc kéo | append cuối cột đích, `position` do server cấp |
| Đăng xuất | về `/login`; `/api/me`, `/api/tasks` = 401 |
| Console | 0 error |

## 3. Kiểm thử hạ tầng (thủ công)

| Việc | Cách kiểm | Kỳ vọng |
|---|---|---|
| DB local | `docker run ... postgres:17` + `psql -f infra/setup/schema.sql` | schema áp dụng, `app_user` CRUD được |
| Least privilege | `psql` bằng `app_user` | không đọc được `pg_authid`, không `CREATE/DROP TABLE` |
| Restore Neon | `pg_restore --exit-on-error --no-owner` | TLS `verify-full`, `app_user` CRUD OK |
| TLS Neon | `psql "sslmode=verify-full ..."` | TLSv1.3, cert hợp lệ |
| 5432 từ Internet | `Test-NetConnection` | `TcpTestSucceeded=False` |
| HTTPS origin | `openssl s_client` | `Verify return code: 0`, TLSv1.3 |
| TLS 1.1 | `openssl s_client -tls1_1` | handshake failure (đúng) |
| Cert renew | `certbot renew --dry-run` | PASS, deploy hook reload nginx |
| Neon cold start | `curl /api/health` sau 5 phút idle | không 503 sau scale-to-zero |

## 4. Nguyên tắc khi sửa

1. Sửa hành vi → chạy `ci-smoke.py` + kiểm tay các luồng chính.
2. Sửa UI → kiểm browser thật (desktop/mobile, light/dark, kéo–thả); `?v=` tự sinh từ
   nội dung asset, không sửa tay.
3. Sửa schema → migration up/down + diễn tập rollback trong transaction + smoke test.
4. Test/seed phải tự dọn dữ liệu; không để lại tài khoản test trên production.
5. Không đưa secret vào test; không in mật khẩu/hash ra output.
