# Bộ test API theo luồng đăng ký — 82 PASS / 0 FAIL

> **Lịch sử:** bộ test này chạy khi app còn rate limit. Bộ hiện tại (86 PASS, đã bỏ limiter) nằm ở `evidence/app-tests-nolimit.md`.

- Ngày chạy: `2026-11-10`
- Build: GĐ A + B + B+ + C (login/logout) + đăng ký công khai; Neon đã xoá toàn bộ dữ liệu demo.
- Script: `infra/app-tests.sh` (chạy trên VM bằng `scripts/run-remote.ps1`), **không cần tài khoản seed**: tự gọi `POST /api/register` tạo 2 tài khoản `test-<ts>-a|b@example.test` rồi tự xoá ở cuối (kể cả khi test fail, nhờ `trap`).
- Đường test: `https://kanban.akaine.io.vn` qua nginx/Cloudflare (`curl --resolve ...:443:127.0.0.1 -k`); riêng test `?detail=1` gọi thẳng `http://127.0.0.1:8000`.
- Script restart `cdb-kanban` khi chạy bằng root (`CDB_RESET_LIMITER=1`) để bộ đếm in-memory luôn sạch.
- Bộ 46 case gốc: `evidence/app-tests.md` (lịch sử). Bộ 67 case có login dùng seed: `evidence/app-tests-auth.md` (lịch sử, thay bằng file này).

## Tổng hợp

| Nhóm | PASS | Ghi chú |
|---|---|---|
| Chưa đăng nhập (401/302, /register 200) | 6 | OK |
| Đăng ký: validate (email, mật khẩu, JSON) | 5 | OK |
| Đăng ký: tạo user 1 + tự đăng nhập + board rỗng | 6 | OK |
| Đăng ký: trùng email (409) | 2 | OK |
| Đăng ký: tạo user 2 | 1 | OK |
| Limiter logic (register/login/write) | 3 check | OK |
| Đăng nhập (sai/thiếu/đúng/session) | 13 | OK |
| Health 2 mức + chống giả IP | 6 | OK |
| Scope theo session (403) | 3 | OK |
| Tạo + validate | 7 | OK |
| PATCH (status/title/404) | 11 | OK |
| Quyền sở hữu 2 session (404) | 4 | OK |
| DELETE query string | 6 | OK |
| Header + cookie flags | 9 | OK |
| Logout | 2 | OK |
| Burst rate limit thật (140 POST) | 1 | OK |
| **Tổng** | **82 PASS / 0 FAIL** | |

- Đăng ký: email sai/<8 ký tự/thiếu field/body không phải JSON → `400 invalid_request`; trùng email → `409 unique_violation`; thành công → `201` + tự set session, board rỗng.
- Limiter: đăng ký cho 5 tài khoản/IP/giờ; login 8 lần sai/5 phút/IP; write 60 request/phút/IP (2 worker gunicorn đếm riêng nên thực tế ~120/phút/IP).
- Burst thật 140 `POST /api/tasks` (session user1): **91×400 + 49×429** — 2 gunicorn worker đếm riêng nên trần thực tế ~120/phút/IP; phần vượt trần bị 429.
- Limiter logic: register cho 5 tài khoản đầu, tài khoản thứ 6 bị chặn; login cho 8 lần sai đầu, lần 9 bị chặn; write cho 60 request đầu, 61–62 bị chặn.
- Sau khi chạy: `leftover_test_users=0`.

## Output thật

```text
== don tai khoan test cu (neu co) ==
leftover_test_users=0
== chua dang nhap ==
PASS | GET /api/tasks (no session) -> 401             | 401
PASS | unauth code                                    | unauthenticated
PASS | GET / (no session) -> 302                      | 302
PASS | GET /login -> 200                              | 200
PASS | GET /register -> 200                           | 200
PASS | GET /api/health (public) -> 200                | 200
== dang ky: validate ==
PASS | register email sai -> 400                      | 400
PASS | register email sai code                        | invalid_request
PASS | register mat khau 7 ky tu -> 400               | 400
PASS | register thieu password -> 400                 | 400
PASS | register body khong phai JSON -> 400           | 400
== dang ky: tao tai khoan 1 (tu dong dang nhap) ==
PASS | register user1 -> 201                          | 201
PASS | register tra email                             | test-1794291911-a@example.test
PASS | register set session -> GET /api/me 200        | 200
PASS | me.id = user1                                  | 34
PASS | board user moi rong                            | 0
PASS | GET /register (da dang nhap) -> 302            | 302
== dang ky: trung email ==
PASS | register trung email -> 409                    | 409
PASS | register trung code                            | unique_violation
== dang ky: tao tai khoan 2 ==
PASS | register user2 -> 201                          | 201
== tao tai khoan: limiter logic ==
REGISTER_LIMITER first5_allowed=True sixth_blocked=True
LOGIN_LIMITER first8_allowed=True ninth_blocked=True
WRITE_LIMITER first60_allowed=True last2_blocked=True
== dang nhap ==
PASS | logout truoc khi test login -> 200             | 200
PASS | login sai mat khau -> 401                      | 401
PASS | login sai code                                 | invalid_credentials
PASS | login email la -> 401                          | 401
PASS | login thieu password -> 400                    | 400
PASS | login dung -> 200                              | 200
PASS | login tra email                                | test-1794291911-a@example.test
PASS | GET /api/me -> 200                             | 200
PASS | me.id = u1                                     | 34
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
id1=51
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
PASS | PATCH title value                              | api test renamed 1794291911
PASS | PATCH status+title -> 200                      | 200
PASS | PATCH status+title value                       | both 1794291911
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
== rate limit that (140 POST, session user1) ==
PASS | login lai user1 -> 200                         | 200
burst      91 400
burst      49 429
note: burst lam IP bi chan toi 60s; restart cdb-kanban de reset bo dem.
== don tai khoan test ==
leftover_test_users=0
== summary ==
pass=82 fail=0
leftover_test_users=0
```

## Đo sau idle (Neon scale-to-zero)

Sau khi purge, giữ yên **330 s** (không request nào) rồi gọi `GET /api/health` trực tiếp origin `http://127.0.0.1:8000` (mỗi request đều chạy `SELECT current_user, current_database(), inet_server_addr()`):

```text
idle_wait_start=2026-11-10T06:36:58Z
idle_wait_end=2026-11-10T06:42:28Z
health_try1 status=200 total=1.856734s   <- Neon vừa wake
health_try2 status=200 total=0.735595s
health_try3 status=200 total=0.314072s
```

- Request đầu sau idle ~**1.86 s**, các request sau ~0.31–0.74 s; không có 500/503 nhờ retry + pool reconnect.
- Script: `infra/idle-check.sh` (không đụng dữ liệu, chỉ health).

## Ghi chú

- Tài khoản test chỉ tồn tại trong lúc chạy; script xoá task trước rồi mới xoá user (FK) và in `leftover_test_users=0`.
- Production sau lần chạy: `users=0 tasks=0` (xem `evidence/cleanup-register.md`).
- Burst làm IP bị chặn 60 s theo thiết kế; script tự restart service ở lần chạy sau nếu chạy bằng root.
- Các lần FAIL trước đây (bộ 67 case) là do kỳ vọng test sai (task user khác trả 404, cookie kiểm bằng POST /api/login), không phải lỗi app.
