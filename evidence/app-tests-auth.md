# Bộ test API có đăng nhập — 67 PASS / 0 FAIL

> **Lịch sử:** bộ này dùng seed `an@example.test`/`binh@example.test`, đã bị thay bởi bộ tự đăng ký **82 PASS** ở `evidence/app-tests-register.md` sau khi Neon purge demo. Giữ lại để đối chiếu.

- Ngày chạy: `2026-11-10`
- Build: bản cuối GĐ A + B + B+ + C (login), service vừa `systemctl restart cdb-kanban` để xoá bộ đếm rate limit.
- Script: `infra/app-tests.sh` (chạy trên VM bằng `scripts/run-remote.ps1`, đọc mật khẩu demo từ `/etc/cdb/demo-login.txt`, không in ra output).
- Đường test: `https://kanban.akaine.io.vn` qua nginx (`curl --resolve ...:443:127.0.0.1 -k`); riêng test `?detail=1` gọi thẳng `http://127.0.0.1:8000` để mô phỏng localhost/không localhost.
- Bộ test cũ 46 case (trước login) vẫn nằm ở `evidence/app-tests.md`; file này là bộ mở rộng thay thế khi chạy lại.

## Tổng hợp

| Nhóm | Số case | Kết quả |
|---|---|---|
| Chưa đăng nhập (401/302) | 6 | PASS |
| Đăng nhập (sai/thiếu/đúng/session) | 12 | PASS |
| Health 2 mức + chống giả IP | 6 | PASS |
| Scope theo session (403) | 3 | PASS |
| Tạo + validate | 7 | PASS |
| PATCH (status/title/404) | 11 | PASS |
| Quyền sở hữu 2 session (404) | 4 | PASS |
| DELETE query string | 6 | PASS |
| Header + cookie flags | 9 | PASS |
| Logout | 2 | PASS |
| Limiter logic + burst thật | 3 (1 PASS + 2 log) | PASS |
| **Tổng** | **67 PASS / 0 FAIL** | |

- Burst thật: 140 `POST /api/tasks` (session user1) → **98×400 + 42×429** (2 gunicorn worker đếm riêng nên trần ~120/phút/IP; phần dư bị 429).
- Limiter logic: login cho 8 lần sai đầu, lần 9 bị chặn; write cho 60 request đầu, 61–62 bị chặn.

## Output thật

```text
u1=1 u2=2

== chua dang nhap ==
PASS | GET /api/tasks (no session) -> 401             | 401
PASS | unauth code                                    | unauthenticated
PASS | GET / (no session) -> 302                      | 302
PASS | POST /api/tasks (no session) -> 401            | 401
PASS | GET /login -> 200                              | 200
PASS | GET /api/health (public) -> 200                | 200

== dang nhap ==
PASS | login sai mat khau -> 401                      | 401
PASS | login sai code                                 | invalid_credentials
PASS | login email la -> 401                          | 401
PASS | login thieu password -> 400                    | 400
PASS | login dung -> 200                              | 200
PASS | login tra email                                | an@example.test
PASS | GET /api/me -> 200                             | 200
PASS | me.id = u1                                     | 1
PASS | GET /api/users -> 200                          | 200
PASS | users chi tra chinh minh                       | 1
PASS | GET / (da dang nhap) -> 200                    | 200
PASS | GET /login (da dang nhap) -> 302               | 302

== health 2 muc (public, khong can session) ==
PASS | health short keys                              | db_user,ok,status
PASS | health short ok                                | True
PASS | health?detail=1 (local) -> 200                 | 200
PASS | detail co db_host                              | True
PASS | detail spoofed remote -> 403                   | 403
PASS | detail spoofed code                            | forbidden

== scope theo session ==
PASS | GET tasks user1 -> 200                         | 200
PASS | GET tasks user2 bang session user1 -> 403      | 403
PASS | 403 code                                       | forbidden_user

== tao + validate ==
PASS | POST task -> 201                               | 201
id1=50
PASS | POST title rong -> 400                         | 400
PASS | empty title code                               | invalid_request
PASS | POST title 201 ky tu -> 400                    | 400
PASS | POST thieu title -> 400                        | 400
PASS | POST body khong phai JSON -> 400               | 400
PASS | POST user_id khac session -> 403               | 403

== patch ==
PASS | PATCH status -> 200                            | 200
PASS | PATCH status value                             | doing
PASS | PATCH title -> 200                             | 200
PASS | PATCH title value                              | api test renamed 1794283454
PASS | PATCH status+title -> 200                      | 200
PASS | PATCH status+title value                       | both 1794283454
PASS | PATCH khong co field -> 400                    | 400
PASS | PATCH status sai -> 400                        | 400
PASS | PATCH title rong -> 400                        | 400
PASS | PATCH task khong ton tai -> 404                | 404
PASS | PATCH 404 code                                 | not_found

== quyen so huu (2 session) ==
PASS | login user2 -> 200                             | 200
PASS | user2 PATCH task user1 -> 404                  | 404
PASS | user2 DELETE task user1 -> 404                 | 404
PASS | user1 van PATCH duoc task cua minh -> 200      | 200

== delete (query string) ==
PASS | DELETE thieu user_id -> 400                    | 400
PASS | DELETE user_id khong phai so -> 400            | 400
PASS | DELETE task cua minh -> 200                    | 200
PASS | DELETE lai -> 404                              | 404
PASS | GET tasks sau delete -> 200                    | 200
PASS | task da bi xoa                                 | False

== headers ==
PASS | header x-content-type-options                 | present
PASS | header x-frame-options                        | present
PASS | header referrer-policy                        | present
PASS | header content-security-policy                | present
PASS | header cache-control                          | present
PASS | session cookie duoc set                        | present
PASS | cookie httponly                               | present
PASS | cookie samesite=lax                           | present
PASS | cookie secure                                 | present

== logout ==
PASS | POST /api/logout -> 200                        | 200
PASS | GET /api/me sau logout -> 401                  | 401

== limiter (logic in-process) ==
LOGIN_LIMITER first8_allowed=True ninth_blocked=True
WRITE_LIMITER first60_allowed=True last2_blocked=True

== rate limit that (140 POST, session user1) ==
PASS | login lai user1 -> 200                         | 200
burst      98 400
burst      42 429
note: burst lam IP bi chan toi 60s; restart cdb-kanban de reset bo dem.

== summary ==
pass=67 fail=0
```

## Ghi chú

- Task test (`id=50`) được tạo rồi xoá trong cùng script; dữ liệu seed không đổi (đếm `3/1/1`).
- Sau burst, IP bị chặn 60 s theo thiết kế; script ghi chú rõ, lần chạy sau cần `systemctl restart cdb-kanban` hoặc chờ hết cửa sổ.
- Hai case từng FAIL trong lần chạy đầu là do **kỳ vọng test sai**, không phải lỗi app: task của user khác trả `404` (không lộ sự tồn tại) và cookie phải kiểm bằng `POST /api/login`; đã sửa test và chạy lại.
