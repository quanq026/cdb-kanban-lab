# Bằng chứng test API — GĐ A (pool, lỗi JSON, quyền sở hữu, rate limit)

> **Lưu ý lịch sử:** đây là bộ 46 test chạy **trước khi có login**. Từ GĐ C, `infra/app-tests.sh` đã được mở rộng thành bộ 67 test có session; kết quả hiện hành ở `evidence/app-tests-auth.md`. File này giữ nguyên làm mốc GĐ A (kèm số đo idle first-request).

- Thời điểm chạy: `2026-11-10` (bản deploy cuối cùng, sau GĐ A + B)
- URL test: `https://kanban.akaine.io.vn` (qua Cloudflare), resolve về `127.0.0.1:443` để đi đúng origin; plain `http://127.0.0.1` bị 301 nên không dùng.
- Script: `infra/app-tests.sh` (46 assertion, dùng `curl` + `python3` có sẵn trên VM).
- Chạy bằng: `powershell -File scripts\run-remote.ps1 -Path infra\app-tests.sh`

## Lệnh

```bash
# trên VM (script tự đọc /etc/cdb/app.env cho phần test rate limiter in-process)
sudo bash /tmp/step.sh
```

## Output thật (nguyên văn)

```text
== users ==
PASS | GET /api/users -> 200                            | 200
u1=1 u2=2

== health ==
PASS | GET /api/health -> 200                           | 200
PASS | health short keys                                | db_user,ok,status
PASS | health short has no db_host                      | None
PASS | health short has no backend_addr                 | None
PASS | health short has no database                     | None
PASS | health short has no sslmode                      | None
PASS | health short ok=true                             | True
PASS | GET /api/health?detail=1 (local) -> 200          | 200
PASS | detail has db_host                               | True
PASS | detail spoofed remote -> 403                     | 403
PASS | detail spoofed code                              | forbidden

== create + validation ==
PASS | POST task -> 201                                 | 201
id1=42
PASS | POST empty title -> 400                          | 400
PASS | empty title code                                 | invalid_request
PASS | POST 201-char title -> 400                       | 400
PASS | POST unknown user_id -> 400                      | 400
PASS | unknown user_id code                             | foreign_key_violation
PASS | POST missing title -> 400                        | 400
PASS | POST bad json -> 400                             | 400

== patch ==
PASS | PATCH status -> 200                              | 200
PASS | PATCH status value                               | doing
PASS | PATCH title -> 200                               | 200
PASS | PATCH title value                                | api test renamed 1794281573
PASS | PATCH status+title -> 200                        | 200
PASS | PATCH status+title value                         | both 1794281573
PASS | PATCH no fields -> 400                           | 400
PASS | PATCH bad status -> 400                          | 400
PASS | PATCH empty title -> 400                         | 400
PASS | PATCH unknown task -> 404                        | 404
PASS | PATCH unknown task code                          | not_found

== ownership ==
PASS | POST task for user2 -> 201                       | 201
PASS | PATCH other user's task -> 404                   | 404
PASS | DELETE other user's task -> 404                  | 404

== delete (query string, no body) ==
PASS | DELETE own task -> 200                           | 200
PASS | DELETE again -> 404                              | 404
PASS | DELETE without user_id -> 400                    | 400
PASS | DELETE user_id not int -> 400                    | 400
PASS | DELETE own task (id1) -> 200                     | 200
PASS | GET tasks -> 200                                 | 200
PASS | deleted task gone                                | False

== headers ==
PASS | header x-content-type-options                   | present
PASS | header x-frame-options                          | present
PASS | header referrer-policy                          | present
PASS | header content-security-policy                  | present
PASS | header cache-control                            | present

== rate limiter (in-process logic) ==
LIMITER first60_allowed=True blocked_last2=True

== rate limiter (live burst, POST 140x invalid body) ==
burst      99 400
burst      41 429
note: burst poisons this IP for up to 60s; restart cdb-kanban to reset the per-worker counters.

== summary ==
pass=46 fail=0
```

Diễn giải:

- `health short keys` = `db_user,ok,status`: bản công khai **không** trả `db_host`/`database`/`backend_addr`/`sslmode`.
- `detail spoofed remote -> 403`: gọi thẳng `127.0.0.1:8000` kèm `X-Forwarded-For: 203.0.113.9` → app vẫn coi là remote (ProxyFix tin 1 hop) và trả 403, nên không ai xem được chi tiết từ ngoài.
- `burst 99 400 + 41 429`: 140 POST liên tiếp, 60 request đầu/IP/worker được xử lý (400 vì body rỗng) rồi bị chặn 429; 2 gunicorn worker nên trần thực tế ~120/phút/IP. Sau test phải `systemctl restart cdb-kanban` để reset bộ đếm trong bộ nhớ.
- Không có 500/503 trong toàn bộ test: mọi lỗi đều là JSON `{error, code}` đúng như thiết kế.

## Thời gian request đầu tiên sau khi Neon idle

Cách đo: gọi `curl` tới `https://kanban.akaine.io.vn/api/tasks?user_id=1` 1 lần cho Neon ngủ lại, đợi **7 phút** (Neon Free scale-to-zero khoảng 5 phút), rồi đo 3 request liên tiếp, cách nhau 1 s. Cùng URL, cùng đường mạng (qua Cloudflare), cùng máy đo.

| Thời điểm | Request 1 (cold) | Request 2 | Request 3 |
|---|---|---|---|
| **Trước GĐ A** (`2026-11-10 10:05:48`) | `2.163 s` | `0.845 s` | `0.883 s` |
| **Sau GĐ A** (`2026-11-10 10:31:25`) | `3.100 s` | `0.697 s` | `0.996 s` |
| **Sau GĐ A, lần 2** (`2026-11-10 10:40:32`, sau `systemctl restart`) | `2.122 s` | `1.029 s` | `1.065 s` |

Nhận xét thật (không tô hồng):

- Thời gian cold **không giảm** mà dao động `2.1–3.1 s`: phần lớn là Neon khởi động compute (scale-to-zero), không phải code Flask. Bản cũ và bản mới đều phải chờ như nhau; khác biệt chính là bản mới **không trả 500** khi connection cũ đã bị Neon đóng.
- Log server (`journalctl -u cdb-kanban`) cho request cold lần 1: `GET /api/tasks 200 2427.1ms` — tức ~2.4 s nằm trong app+DB, còn ~0.67 s là TLS/CDN tới Cloudflare; các request sau chỉ `~275–282 ms` phía server.
- Không thấy log retry/`OperationalError` trong lần đo này: `check=check_connection` loại bỏ connection chết ngay khi checkout nên không cần tới lần thử thứ 2.
- Vì vậy kết luận đúng là: **pool mới chịu được cold start và không lỗi 5xx**; nó không làm Neon thức nhanh hơn.

## Log request (journald)

```text
[2026-11-10 03:31:29,110] INFO in app: GET /api/tasks 200 2427.1ms ip=118.70.140.18
[2026-11-10 03:22:39,445] INFO in app: GET /api/tasks 200 281.2ms ip=118.70.140.18
```

- Có `ip=118.70.140.18` (IP thật của người dùng, không phải IP Cloudflare) → `real_ip_header CF-Connecting-IP` + `ProxyFix` hoạt động.
- Log chỉ có method/path/status/thời gian/IP, không có body, header hay mật khẩu.
