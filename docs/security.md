# Bảo mật

## 1. Nguyên tắc

- **Least privilege** ở mọi tầng: DB role, port, SSH, quyền file secret.
- **Không tin client**: `user_id` luôn đối chiếu session; IP lấy từ header do nginx xác
  thực, không tin `X-Forwarded-For` thô.
- **Không lưu secret trong repo**; không log mật khẩu/body/token.
- **Fail closed**: thiếu session → 401/302; DB lỗi → 503 JSON, không lộ stack trace.

## 2. Database

- App kết nối bằng `app_user`: `rolsuper=false`, `createdb=false`, `createrole=false`,
  không `BYPASSRLS`; chỉ có `SELECT/INSERT/UPDATE/DELETE` trên `users`/`tasks`.
- Role owner chỉ dùng cho migration, lấy từ `/etc/cdb/secrets.env` (600 root).
- `5432` không mở Internet; app chỉ nghe loopback `127.0.0.1:8000`.
- `sslmode=verify-full` + CA bundle Ubuntu (`DB_SSLROOTCERT`), **không** tắt xác minh.
- Mọi SQL tham số hoá; `DELETE`/`PATCH` luôn kèm `user_id` trong `WHERE`.

## 3. Mạng & SSH

- NSG: 22 chỉ từ IP vận hành; 80/443 public; không 5432.
- SSH key-only (`--authentication-type ssh`), `PasswordAuthentication` tắt.
- App chỉ nghe `127.0.0.1:8000`; nginx là entry duy nhất.
- Cloudflare proxy ẩn IP origin; đổi IP phải cập nhật DNS/Origin Rule.

## 4. Secret

| File | Quyền | Nội dung |
|---|---|---|
| `.env` | local, gitignored | biến dev (mẫu ở `.env.example`) |
| `/etc/cdb/app.env` | 600 root | `DB_*`, `APP_SECRET_KEY` |
| `/etc/cdb/secrets.env` | 600 root | mật khẩu owner Neon, mật khẩu superuser khi bootstrap |

- `.gitignore` chặn `.env*` (trừ `.env.example`), `*.dump`, `*.pem`, `__pycache__/`, `.venv/`.
- Không file SQL/script nào chứa secret; không in secret ra output.
- `APP_SECRET_KEY` đổi = mọi session cũ mất hiệu lực.

## 5. TLS & edge

- Cloudflare `ssl=strict` (xác minh cert origin), `min_tls_version=1.2`; TLS 1.0/1.1 bị
  từ chối; HTTP/3 + Brotli bật.
- Origin: Let's Encrypt `CN=kanban.akaine.io.vn`, TLS 1.2/1.3, HTTP/2; private key root 600.
- `http://` (kể cả theo IP) → 301 HTTPS; ACME path được miễn redirect.
- HSTS `max-age=15552000` (không `includeSubDomains`/`preload` để còn rollback).
- Header: `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`,
  `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy`.
- CSP của app: `default-src 'self'`; **không** `unsafe-inline` → mọi script/style phải ở
  file riêng. Thêm inline sẽ bị chặn.

## 6. Xác thực & session

- Mật khẩu hash **scrypt** (`werkzeug`, `32768:8:1`, salt riêng); không lưu plaintext.
- `password_hash IS NULL` → mọi mật khẩu sai (401), không có đường đăng nhập ẩn.
- Email không tồn tại vẫn so sánh với `DUMMY_HASH` để giảm lộ qua thời gian.
- Cookie `cdb_session`: ký `itsdangerous`, `HttpOnly`, `SameSite=Lax`, `Secure`, 12 h;
  không có session server-side.
- Logout xoá cookie hiện tại; **không thu hồi** được cookie đã bị copy. Muốn thu hồi toàn
  bộ: đổi `APP_SECRET_KEY` + restart.
- Đăng ký công khai: email hợp lệ, mật khẩu 8–200 ký tự, trùng email → 409; không mã mời.
- Chưa có CAPTCHA/2FA/xác thực email/đổi-quên mật khẩu/khoá tài khoản.

### Rate limit — đánh đổi đã chấp nhận

App **không** có rate limiter. Hệ quả:

- Không chống spam ghi, dò mật khẩu hay đăng ký hàng loạt ở tầng app.
- Không có bộ đếm in-memory; restart không ảnh hưởng.
- Giảm rủi ro bằng: mật khẩu tối thiểu 8 + scrypt, log request kèm IP thật, và có thể bật
  rate limiting/WAF ở Cloudflare nếu triển khai thật. Đây là phạm vi demo.

## 7. Phân quyền dữ liệu

- `same_user()` so `user_id` client với `session.uid` → lệch: `403 forbidden_user`.
- Task của user khác trả `404` (không lộ sự tồn tại).
- `/api/users` chỉ trả chính user đang đăng nhập.
- `/api/health` công khai không lộ host/database/sslmode; `?detail=1` chỉ localhost.

## 8. Log & quyền riêng tư

- Mỗi request: `METHOD path status Xms ip=...`; không body/header/token/mật khẩu.
- IP thật: nginx `real_ip_header CF-Connecting-IP` chỉ tin dải Cloudflare, ghi đè
  `X-Forwarded-For`; Flask `ProxyFix`. Client không giả được IP trong log.
- Lỗi 500 trả message chung; stack trace chỉ vào journald.

## 9. Giới hạn đã biết

- Demo, không dùng cho dữ liệu thật.
- Không rate limit (mục 6); không CAPTCHA/2FA/xác thực email.
- Session client-side: logout không thu hồi cookie đã copy.
- Chưa test mất toàn máy/PITR/failover; dump nằm cùng VM.
- HSTS 180 ngày: browser đã truy cập vẫn ép HTTPS kể cả khi rollback.
- `ssl=strict` áp cho cả zone `akaine.io.vn`; apex đang 522 vì origin riêng không truy cập
  được. Nếu trỏ apex về origin khác, origin đó phải có cert hợp lệ (nếu không → 526).
- Cert phụ thuộc `certbot.timer`; VM tắt quá lâu có thể hết hạn.
- CSP không cho inline script/style.
- `/api/health?detail=1` chỉ localhost.

## 10. Checklist trước khi chia sẻ/đổi môi trường

- [ ] `git status` không có `.env`, `*.dump`, `*.pem`, hay file credential.
- [ ] Không in secret trong log/CI; rotate nếu nghi ngờ.
- [ ] `APP_SECRET_KEY` mới khi đổi môi trường.
- [ ] NSG SSH đúng IP hiện tại.
- [ ] `certbot renew --dry-run` PASS.
- [ ] CI xanh (`.github/scripts/ci-smoke.py`) và dữ liệu test tự dọn.
