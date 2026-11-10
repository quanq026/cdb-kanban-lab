# Kiểm thử

## 1. Bộ test hiện tại — 86 case

| | |
|---|---|
| Script | `infra/test/app-tests.sh` |
| Cách chạy | `powershell -File infra\tools\run-remote.ps1 -Path infra\test\app-tests.sh` |
| Đường test | `https://kanban.akaine.io.vn` qua nginx (`curl --resolve ...:443:127.0.0.1 -k`); health chi tiết gọi thẳng `http://127.0.0.1:8000` |
| Dữ liệu | Tự đăng ký `test-<ts>-a|b@example.test` + 6 tài khoản burst; `trap` tự xoá task → user |
| Kết quả | **86 PASS / 0 FAIL**, `leftover_test_users=0` |

Không cần seed, không cần restart service, không còn bước reset limiter (app không giữ
bộ đếm).

> Đã chạy lại **sau khi tái cấu trúc repo** (2026-11-10): 86 PASS / 0 FAIL,
> `leftover_test_users=0` — xác nhận đường dẫn mới `infra/test/app-tests.sh` hoạt động.

### Phạm vi

| Nhóm | Số case | Nội dung |
|---|---:|---|
| Chưa đăng nhập | 6 | API 401, trang 302, `/login` `/register` `/api/health` 200 |
| Đăng ký — validate | 5 | email sai, mật khẩu 7 ký tự, thiếu field, body không JSON |
| Đăng ký — tạo user | 6 | 201, tự set session, board rỗng, `/register` đã đăng nhập → 302 |
| Đăng ký — trùng email | 2 | 409 `unique_violation` |
| Đăng ký — user 2 | 1 | 201 |
| Đăng ký — burst | 2 | 6 lần liên tiếp đều 201, 0 lần 429 |
| Đăng nhập | 13 | sai/thiếu/đúng, `/api/me`, `/api/users`, redirect |
| Health 2 mức + giả IP | 6 | public không lộ field, `?detail=1` localhost, spoof → 403 |
| Scope theo session | 3 | `user_id` lệch → 403 `forbidden_user` |
| Tạo + validate task | 7 | 201, title rỗng/201 ký tự/thiếu, body sai, `user_id` lệch |
| PATCH | 11 | status, title, cả hai, thiếu field, status sai, 404 |
| Quyền sở hữu 2 session | 4 | user2 PATCH/DELETE task user1 → 404 |
| DELETE query string | 6 | thiếu `user_id`, không phải số, xoá, xoá lại 404 |
| Header + cookie | 9 | 5 security header, `Set-Cookie`, `HttpOnly`, `SameSite=Lax`, `Secure` |
| Logout | 2 | 200, `/api/me` sau đó 401 |
| Burst ghi | 3 | 70 POST liên tiếp: 70×400, **0×429**, 0×5xx (kèm login lại) |

Chi tiết output thật: [evidence/api.md](evidence/api.md). Output raw đầy đủ nằm trong git
history commit `6d3a2b7` (`evidence/app-tests-nolimit.md`).

### Chạy lại và đọc kết quả

```bash
# trên VM (run-remote.ps1 đã scp + sudo)
sudo bash /tmp/app-tests.sh
```

Kỳ vọng cuối:

```text
== summary ==
pass=86 fail=0
leftover_test_users=0
```

Nếu fail: script dừng ở case lỗi, vẫn chạy `trap` dọn tài khoản. Không sửa app để chiều
test — kiểm tra lại kỳ vọng trước (đã từng sai ở case task user khác trả 404 thay vì 403).

## 2. Kiểm thử giao diện

### 2.1. Screenshot tự động

```powershell
node infra\test\ui-shots.mjs docs\evidence\images
powershell -File infra\tools\run-remote.ps1 -Path infra\maintenance\purge-test-accounts.sh
```

- Chrome headless qua CDP, emulation đúng `width` (1440/375), `mobile`, `prefers-color-scheme`.
- Tự đăng ký `shot+<ts>@local.test`, chụp board trống, tạo 3 việc mẫu (1 Todo/1 Doing/1
  Done) rồi chụp board + menu tài khoản.
- Chỉ chụp khi `.task` render (hoặc 3 empty state); không chờ footer (đã bỏ).
- 8 ảnh: login, register, empty, desktop light/dark, menu, mobile light/dark.
- Metadata: `docs/evidence/ui-shots.json`.

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
| Đăng xuất | về `/login`; `/api/me`, `/api/tasks` = 401 |
| Console | 0 error |

Chi tiết + ảnh: [evidence/ui.md](evidence/ui.md).

## 3. Lịch sử bộ test

| Bộ | Case | Bối cảnh | Trạng thái |
|---|---:|---|---|
| `app-tests.md` | 46 | GĐ A: backend bền, rate limit, health 2 mức | lịch sử |
| `app-tests-auth.md` | 67 | GĐ C: login/session, dùng seed | lịch sử |
| `app-tests-register.md` | 82 | đăng ký công khai + rate limit 5/giờ | lịch sử |
| `app-tests-nolimit.md` | **86** | bỏ toàn bộ rate limit, top bar mới, bỏ footer | **hiện tại** |

Bộ cũ giữ trong git history (`6d3a2b7`); tóm tắt trong [evidence/api.md](evidence/api.md).

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

1. Sửa hành vi → chạy lại **toàn bộ** 86 case, không chỉ case liên quan.
2. Sửa UI → chụp lại 8 ảnh + kiểm browser thật; bump `?v=` nếu đổi CSS/JS.
3. Sửa schema → migration up/down + diễn tập rollback trong transaction + test.
4. Test phải tự dọn dữ liệu (`trap`), kết thúc bằng `leftover_test_users=0`.
5. Không đưa secret vào test; không in mật khẩu/hash ra output.
