# Bộ test API sau khi bỏ rate limit — 86 PASS / 0 FAIL

- Ngày chạy: `2026-11-10`
- Build: GĐ A + B + B+ + login/register, **đã bỏ toàn bộ rate limit**, top bar gọn + bỏ footer.
- Script: `infra/app-tests.sh` (chạy trên VM bằng `sudo bash /tmp/app-tests.sh`), **không cần tài khoản seed**: tự gọi `POST /api/register` tạo tài khoản `test-<ts>-a|b@example.test` + 6 tài khoản burst, rồi tự xoá ở cuối (kể cả khi fail, nhờ `trap`).
- Đường test: `https://kanban.akaine.io.vn` qua nginx/Cloudflare (`curl --resolve ...:443:127.0.0.1 -k`); riêng `?detail=1` gọi thẳng `http://127.0.0.1:8000`.
- Không còn bước restart `cdb-kanban`/`CDB_RESET_LIMITER` vì app không giữ bộ đếm limiter.
- Lịch sử: `evidence/app-tests-register.md` (82 case, còn rate limit), `app-tests-auth.md` (67 case dùng seed), `app-tests.md` (46 case gốc).

## Tổng hợp

| Nhóm | PASS | Ghi chú |
|---|---|---|
| Chưa đăng nhập (401/302, /register 200) | 6 | OK |
| Đăng ký: validate (email, mật khẩu, JSON) | 5 | OK |
| Đăng ký: tạo user 1 + tự đăng nhập + board rỗng | 6 | OK |
| Đăng ký: trùng email (409) | 2 | OK |
| Đăng ký: tạo user 2 | 1 | OK |
| Đăng ký: burst 6 tài khoản liên tiếp | 2 | 6×201, 0×429 |
| Đăng nhập (sai/thiếu/đúng/session) | 13 | OK |
| Health 2 mức + chống giả IP | 6 | OK |
| Scope theo session (403) | 3 | OK |
| Tạo + validate | 7 | OK |
| PATCH (status/title/404) | 11 | OK |
| Quyền sở hữu 2 session (404) | 4 | OK |
| DELETE query string | 6 | OK |
| Header + cookie flags | 9 | OK |
| Logout | 2 | OK |
| Burst ghi 70 POST liên tiếp | 2 | 70×400, 0×429, 0×5xx |
| **Tổng** | **86 PASS / 0 FAIL** | |

- Đăng ký: email sai/<8 ký tự/thiếu field/body không phải JSON → `400 invalid_request`; trùng email → `409 unique_violation`; thành công → `201` + tự set session, board rỗng.
- **Không còn 429:** 6 lần đăng ký liên tiếp đều `201`; 70 `POST /api/tasks` liên tiếp (body `{}`) đều `400 invalid_request`, không có `429` và không có `5xx`.
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
PASS | register tra email                             | test-1794293754-a@example.test
PASS | register set session -> GET /api/me 200        | 200
PASS | me.id = user1                                  | 42
PASS | board user moi rong                            | 0
PASS | GET /register (da dang nhap) -> 302            | 302

== dang ky: trung email ==
PASS | register trung email -> 409                    | 409
PASS | register trung code                            | unique_violation

== dang ky: tao tai khoan 2 ==
PASS | register user2 -> 201                          | 201

== dang ky: khong con gioi han ==
register-burst       6 201
PASS | 6 dang ky lien tiep deu 201                    | 6
PASS | 6 dang ky khong co 429                         | 0

== dang nhap ==
PASS | logout truoc khi test login -> 200             | 200
PASS | login sai mat khau -> 401                      | 401
PASS | login sai code                                 | invalid_credentials
PASS | login email la -> 401                          | 401
PASS | login thieu password -> 400                    | 400
PASS | login dung -> 200                              | 200
PASS | login tra email                                | test-1794293754-a@example.test
PASS | GET /api/me -> 200                             | 200
PASS | me.id = u1                                     | 42
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
id1=56
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
PASS | PATCH title value                              | api test renamed 1794293754
PASS | PATCH status+title -> 200                      | 200
PASS | PATCH status+title value                       | both 1794293754
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
PASS | DELETE user_id khong phai so -> 400             | 400
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

== khong con rate limit ghi: 70 POST lien tiep ==
PASS | login lai user1 -> 200                         | 200
burst      70 400
PASS | 70 POST lien tiep khong co 429                 | 0
PASS | 70 POST lien tiep khong co 5xx                 | 0

== don tai khoan test ==
leftover_test_users=0

== summary ==
pass=86 fail=0
leftover_test_users=0
```

## Ghi chú

- Tài khoản test chỉ tồn tại trong lúc chạy; script xoá task trước rồi mới xoá user (FK) và in `leftover_test_users=0`.
- Production sau lần chạy + purge: `users=1` (tài khoản thật của chủ demo) `tasks=0`; không còn tài khoản `test-*`/`shot+*`/`verify+*`.
- Không còn burst 429 như bộ test cũ; burst bây giờ dùng để chứng minh limiter đã bị bỏ và app không trả 5xx dưới tải nhỏ.
