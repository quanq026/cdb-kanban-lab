# API

Base URL: `https://kanban.akaine.io.vn`. Mọi response API là JSON; lỗi luôn có dạng
`{"error": "...", "code": "..."}` (không trả HTML).

## 1. Xác thực

| Trạng thái | Hành vi |
|---|---|
| Chưa đăng nhập, gọi `/api/*` | `401 {"code":"unauthenticated"}` |
| Chưa đăng nhập, mở trang | `302 → /login` |
| Đã đăng nhập, mở `/login` hoặc `/register` | `302 → /` |
| Session | Cookie ký `cdb_session` (`Secure`, `HttpOnly`, `SameSite=Lax`, 12 h) |
| `user_id` không khớp session | `403 {"code":"forbidden_user"}` |
| Task không tồn tại **hoặc** của user khác | `404 {"code":"not_found"}` |

`/api/login`, `/api/register`, `/api/health` là công khai. Mọi endpoint khác cần session.

## 2. Endpoint

| Method | Path | Body / query | Kết quả |
|---|---|---|---|
| POST | `/api/register` | `{email, password}` | `201` + set session; email sai / mật khẩu < 8 hoặc > 200 → `400 invalid_request`; trùng email → `409 unique_violation` |
| POST | `/api/login` | `{email, password}` | `200` + set session; sai → `401 invalid_credentials` |
| POST | `/api/logout` | – | `200 {ok:true}`, xoá cookie |
| GET | `/api/me` | – | `{user:{id,email}}`; chưa đăng nhập → `401` |
| GET | `/api/health` | – | `{status, db_user, ok}` — không lộ host/database/sslmode |
| GET | `/api/health?detail=1` | chỉ `127.0.0.1`/`::1` | thêm `database`, `backend_addr`, `db_host`, `sslmode`; ngoài localhost → `403 forbidden` |
| GET | `/api/users` | – | Chỉ trả chính user đang đăng nhập (giữ để tương thích UI cũ) |
| GET | `/api/tasks?user_id=` | `user_id` khớp session | Danh sách task của user, sắp theo `position, id` |
| POST | `/api/tasks` | `{user_id, title}` | `201`, task mới ở `todo`, append cuối cột (`position = max + 1`) |
| PATCH | `/api/tasks/<id>` | `{user_id, status?, title?, position?}` | `200`; phải có ít nhất một field |
| DELETE | `/api/tasks/<id>?user_id=` | query string, **không body** | `200`; SQL `WHERE id=%s AND user_id=%s` |

Mỗi task trả đủ field:

```json
{
  "id": 42,
  "user_id": 7,
  "title": "Việc mới",
  "status": "todo",
  "position": 0,
  "created_at": "2026-11-10T07:45:00.123456+00:00",
  "updated_at": "2026-11-10T07:45:00.123456+00:00"
}
```

- `position` là thứ tự thủ công **trong từng cột** `(user_id, status)`, 0 = trên cùng.
  Server giữ dãy liên tục `0..n-1` sau mỗi lần di chuyển; giá trị quá lớn bị kẹp về cuối cột.
- `created_at` do `DEFAULT now()`; `updated_at` do trigger DB cập nhật ở mọi `UPDATE`.
- Đổi `status` mà không gửi `position` → task append cuối cột đích.
- Gửi `position` (kèm hoặc không kèm `status`) → chèn vào đúng index của cột đích.

Ví dụ:

```bash
curl -sS -c jar -X POST https://kanban.akaine.io.vn/api/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.test","password":"mot-mat-khau-du-dai"}'

curl -sS -b jar -X POST https://kanban.akaine.io.vn/api/tasks \
  -H 'Content-Type: application/json' \
  -d '{"user_id":42,"title":"Việc mới"}'
```

## 3. Validate

| Field | Luật | Lỗi |
|---|---|---|
| `email` | chuẩn hoá lowercase, regex email hợp lệ | `400 invalid_request` |
| `password` | 8–200 ký tự | `400 invalid_request` |
| `title` | không rỗng/toàn khoảng trắng, ≤ 200 ký tự | `400 invalid_request` (hoặc `check_violation`) |
| `status` | `todo` \| `doing` \| `done` | `400 invalid_request` |
| `position` | số nguyên ≥ 0; lớn hơn độ dài cột → kẹp cuối | `400 invalid_request` |
| `user_id` | số, tồn tại, khớp session | `400` / `403` / FK `400` |
| `id` task | số, thuộc user | `404 not_found` |

Backend validate lại toàn bộ; client chỉ validate để phản hồi nhanh.

## 4. Bảng lỗi

| Tình huống | HTTP | `code` |
|---|---|---|
| Chưa đăng nhập (API) | 401 | `unauthenticated` |
| `user_id` không khớp session | 403 | `forbidden_user` |
| `?detail=1` từ ngoài localhost | 403 | `forbidden` |
| Sai email/mật khẩu, user chưa có hash | 401 | `invalid_credentials` |
| Body/validate sai, `CHECK` violation, FK violation | 400 | `invalid_request`, `check_violation`, `foreign_key_violation` |
| Trùng email khi đăng ký | 409 | `unique_violation` |
| Task không tồn tại / không thuộc user | 404 | `not_found` |
| Không kết nối được DB (Neon ngủ/lỗi mạng) | 503 | `db_unavailable` |
| Lỗi DB khác / lỗi không lường trước | 500 | `db_error`, `internal_error` |

**Không có `429`**: toàn bộ rate limit đã bị bỏ (ghi, login, đăng ký). Xem đánh đổi ở
[security.md](security.md) §6.

## 5. Hành vi phụ

- **Session**: `APP_SECRET_KEY` ký cookie; đổi key = mọi session cũ mất hiệu lực.
- **Health công khai**: `{"db_user":"app_user","ok":true,"status":"ok"}`.
- **Health chi tiết** (localhost): thêm `db_host`, `database`, `backend_addr`, `sslmode`;
  chống giả IP bằng cách kiểm tra `remote_addr` sau `ProxyFix`.
- **Cache**: `/`, `/login`, `/register`, `/api/*` → `no-store`; `app.css`/`app.js` →
  `no-cache` ở origin (Cloudflare vẫn cache; bump `?v=`).
- **Security header** (app): `X-Content-Type-Options`, `X-Frame-Options`,
  `Referrer-Policy`, `Permissions-Policy`, `Content-Security-Policy` (`default-src 'self'`).
  HSTS đặt ở nginx.
- **Log**: một dòng mỗi request, không ghi body/header/mật khẩu.

Bộ test thật của hợp đồng này: `.github/scripts/ci-smoke.py` (57 case, chạy trong CI).
Xem [testing.md](testing.md).
