# Kiểm thử

## 1. CI smoke — bộ test duy nhất còn trong repo (57 case)

> Các script test thủ công cũ (`app-tests.sh`, `ui-shots.mjs`, `ui-drag-check.mjs`) đã được
> xoá khỏi repo để tinh gọn. Kết quả lịch sử vẫn giữ trong [evidence](evidence/) và git
> history; bộ 108 case từng đạt **108 PASS / 0 FAIL** trước khi xoá.

| | |
|---|---|
| Workflow | `.github/workflows/ci.yml` (push/PR `main`, `workflow_dispatch`) |
| Runner | `ubuntu-latest` + service `postgres:17`, DB `studydb` |
| Chuẩn bị | apply `infra/setup/db/schema.sql`, tạo `app_user` LOGIN least-privilege (assert `rolsuper=f`) |
| Syntax | `py_compile app/app.py .github/scripts/ci-smoke.py`, `node --check app/app.js`, `bash -n infra/ops/deploy.sh` |
| Test | `python .github/scripts/ci-smoke.py` — **57 PASS / 0 FAIL** |
| Kết quả thật | 57 PASS / 0 FAIL trên Docker Postgres (VM) và trong GitHub Actions |

`ci-smoke.py` dùng Flask test client (không cần gunicorn/nginx): auth 401/302, register
201 + trùng 409, `/api/me`, tạo task `position=0,1,2`, reorder trong cột, đổi cột,
validate (title rỗng/201 ký tự, status sai, position âm, thiếu field), timestamp
(`updated_at` tăng, `created_at` giữ), delete 200/404, logout/login, health 2 mức, và
tự dọn `ci-*` (kết thúc `no leftover ci-* users`).

Chạy local (cần Postgres đã apply schema):

```powershell
python .github\scripts\ci-smoke.py
```

Deploy tự chạy sau CI xanh trên `main` qua self-hosted runner `cdb-vm`; xem
[operations.md](operations.md) §2.2.

## 2. Kiểm thử giao diện

### 2.1. Ảnh UI (đã có sẵn)

Script chụp `ui-shots.mjs` đã được xoá khỏi repo. Bộ 8 ảnh + metadata vẫn nằm trong
`docs/evidence/images/` và `docs/evidence/ui-shots.json`; khi cần chụp lại, dùng Chrome
headless thủ công hoặc khôi phục script từ git history (`5349b16`).

- 8 ảnh: login, register, empty, desktop light/dark, menu, mobile light/dark.
- Ảnh ô chèn kéo–thả: `docs/evidence/images/ui-drag-light.png`.

### 2.2. Browser thật (thủ công)

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

Chi tiết + ảnh: [evidence/ui.md](evidence/ui.md).

## 3. Lịch sử bộ test

| Bộ | Case | Bối cảnh | Trạng thái |
|---|---:|---|---|
| `app-tests.md` | 46 | GĐ A: backend bền, rate limit, health 2 mức | lịch sử |
| `app-tests-auth.md` | 67 | GĐ C: login/session, dùng seed | lịch sử |
| `app-tests-register.md` | 82 | đăng ký công khai + rate limit 5/giờ | lịch sử |
| `app-tests-nolimit.md` | 86 | bỏ toàn bộ rate limit, top bar mới, bỏ footer | lịch sử |
| `app-tests.sh` (+position/timestamps) | **108** | GĐ C schema: `position`, `created_at`, `updated_at` | đã xoá (từng 108 PASS) |
| `ci-smoke.py` | 57 | CI/CD: Flask test client trên Postgres 17 trong GitHub Actions | **hiện tại** |

Bộ cũ giữ trong git history (`6d3a2b7`, `5349b16`); tóm tắt trong
[evidence/api.md](evidence/api.md).

## 4. Kiểm thử hạ tầng (đã chạy, không tự động)

| Việc | Cách kiểm | Kết quả |
|---|---|---|
| Postgres local | `03-verify.sh`, `04-persistence.sh` | users=2 tasks=5, md5 trùng sau khi xoá/tạo lại container |
| Backup/restore | `05-backup-restore.sh` | dump 6101 B, restore exit 0, count + md5 + index trùng |
| Neon restore | `01-restore.sh`, `02-verify.sh` | md5 trùng local, app_user CRUD OK, không đọc được `pg_authid` |
| TLS Neon | `psql sslmode=verify-full` | TLSv1.3, cert Let's Encrypt hợp lệ |
| 5432 từ Internet | `Test-NetConnection` | `TcpTestSucceeded=False` |
| HTTPS origin | `openssl s_client` | `Verify return code: 0`, TLSv1.3 |
| TLS 1.1 | `openssl s_client -tls1_1` | handshake failure (đúng) |
| Cert renew | `certbot renew --dry-run` | PASS, deploy hook reload nginx |
| Neon cold start | `maintenance/idle-check.sh` | 1.86 s / 0.74 s / 0.31 s, không 503 |

## 5. Nguyên tắc khi sửa

1. Sửa hành vi → chạy `ci-smoke.py` + kiểm tay các luồng chính; bộ 108 case đã xoá khỏi repo.
2. Sửa UI → kiểm browser thật (desktop/mobile, light/dark, kéo–thả); bump `?v=` nếu đổi CSS/JS.
3. Sửa schema → migration up/down + diễn tập rollback trong transaction + smoke test.
4. Test/seed phải tự dọn dữ liệu; production giữ `users=1 tasks=16`.
5. Không đưa secret vào test; không in mật khẩu/hash ra output.
