# Evidence — API

## 1. Bộ hiện tại — 86 PASS / 0 FAIL (2026-11-10)

- Script: `infra/test/app-tests.sh`; chạy `sudo bash /tmp/app-tests.sh` trên VM.
- Đường test: `https://kanban.akaine.io.vn` qua nginx (`curl --resolve ...:443:127.0.0.1 -k`);
  `?detail=1` gọi thẳng `http://127.0.0.1:8000`.
- Không cần seed; tự đăng ký `test-<ts>-a|b@example.test` + 6 tài khoản burst; `trap` tự dọn.
- Build: GĐ A + B + B+ + login/register, **bỏ toàn bộ rate limit**, top bar gọn, bỏ footer.

### Tổng hợp

| Nhóm | PASS | Ghi chú |
|---|---:|---|
| Chưa đăng nhập (401/302, `/register` 200) | 6 | OK |
| Đăng ký — validate | 5 | email/mật khẩu/JSON |
| Đăng ký — tạo user 1 + session + board rỗng | 6 | OK |
| Đăng ký — trùng email | 2 | 409 `unique_violation` |
| Đăng ký — user 2 | 1 | 201 |
| Đăng ký — burst 6 tài khoản | 2 | 6×201, 0×429 |
| Đăng nhập | 13 | sai/thiếu/đúng/session |
| Health 2 mức + chống giả IP | 6 | OK |
| Scope theo session | 3 | 403 `forbidden_user` |
| Tạo + validate | 7 | OK |
| PATCH | 11 | status/title/404 |
| Quyền sở hữu 2 session | 4 | 404 |
| DELETE query string | 6 | OK |
| Header + cookie flags | 9 | OK |
| Logout | 2 | OK |
| Burst ghi 70 POST | 3 | 70×400, 0×429, 0×5xx (kèm login lại) |
| **Tổng** | **86** | **0 FAIL** |

### Output thật

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

- Tài khoản test chỉ tồn tại trong lúc chạy; script xoá task trước rồi user (FK).
- Production sau chạy + purge: `users=1` (tài khoản thật), `tasks=0`; không còn
  `test-*`/`shot+*`/`verify+*`.
- Chạy lại sau tái cấu trúc repo: cùng kết quả **86 PASS / 0 FAIL**.

## 2. Lịch sử các bộ test

| Bộ | Case | Bối cảnh | Burst / ghi chú |
|---|---:|---|---|
| `app-tests.md` | 46 | GĐ A: backend bền, rate limit ghi 60/phút | 140 POST → 99×400 + 41×429 |
| `app-tests-auth.md` | 67 | GĐ C login, dùng seed `an@example.test` | 140 POST → 98×400 + 42×429 |
| `app-tests-register.md` | 82 | đăng ký công khai + limit 5 tài khoản/giờ | 140 POST → 91×400 + 49×429 |
| `app-tests-nolimit.md` | **86** | bỏ rate limit, top bar mới, bỏ footer | 6×201 đăng ký; 70×400 ghi; 0×429 |

Bộ 46/67/82 là lịch sử (giữ trong git `6d3a2b7`), không dùng làm tiêu chí hiện tại.

## 3. Cold start Neon (sau purge)

Sau idle 330 s (`infra/maintenance/idle-check.sh`):

```text
lan 1 = 1.857 s   (Neon wake)
lan 2 = 0.736 s
lan 3 = 0.314 s
503   = 0
```

Kết luận: cold start do Neon scale-to-zero dao động ~1.9–3.1 s; pool không làm Neon thức
nhanh hơn nhưng không trả 500/503 và tự loại connection chết.

## 4. Bằng chứng liên quan

- Hợp đồng API: [../api.md](../api.md)
- Migration/session: [auth.md](auth.md)
- Header/TLS: [https.md](https.md)
- Cách chạy lại: [../testing.md](../testing.md)
