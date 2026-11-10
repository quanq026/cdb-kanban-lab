# Evidence — Domain & HTTPS

- Ngày: `2026-11-09` (domain/cert) và `2026-11-10` (hardening).
- Domain: `kanban.akaine.io.vn` → Cloudflare proxy (A/AAAA) → origin `20.48.104.156`.
- Zone Cloudflare: `akaine.io.vn` (chỉ zone này; 2 zone khác không đụng).
- Token Cloudflare đọc từ file ngoài repo, không in ra output.

## 1. Cert Let's Encrypt trên origin

```bash
sudo certbot certonly --webroot -w /var/www/letsencrypt -d kanban.akaine.io.vn
```

```text
subject=CN = kanban.akaine.io.vn
issuer=C = US, O = Let's Encrypt, CN = YE1
notBefore=Nov  9 09:07:25 2026 GMT
notAfter=Feb  7 09:07:24 2027 GMT
X509v3 Subject Alternative Name:
    DNS:kanban.akaine.io.vn
```

## 2. nginx 80 + 443

```text
LISTEN 0 511 0.0.0.0:443 0.0.0.0:*
LISTEN 0 511 0.0.0.0:80  0.0.0.0:*
LISTEN 0 511 [::]:443    [::]:*
LISTEN 0 511 [::]:80     [::]:*
```

- `:80` giữ cho ACME HTTP-01 và redirect; `:443` TLS 1.2/1.3, HTTP/2.
- nginx 1.24 không hỗ trợ `http2 on;` → dùng `listen 443 ssl http2;`.

## 3. Bắt tay TLS trực tiếp origin

```text
Verify return code: 0 (ok)
Protocol : TLSv1.3
Cipher   : TLS_AES_256_GCM_SHA384
```

## 4. Cloudflare settings (đọc lại từ API)

```text
ssl = strict
min_tls_version = 1.2
always_use_https = on
automatic_https_rewrites = on
tls_1_3 = on
http3 = on
brotli = on
```

## 5. HTTP → HTTPS

```bash
curl -sS -o /dev/null -D - http://kanban.akaine.io.vn/
```

```text
HTTP/1.1 301 Moved Permanently
Location: https://kanban.akaine.io.vn/
```

`http://20.48.104.156/` cũng 301 về domain; ACME path được miễn redirect.

## 6. Security header (xuyên Cloudflare)

```bash
curl -sS -o /dev/null -D - https://kanban.akaine.io.vn/
```

```text
HTTP/1.1 200 OK
Server: cloudflare
strict-transport-security: max-age=15552000
x-content-type-options: nosniff
x-frame-options: SAMEORIGIN
referrer-policy: strict-origin-when-cross-origin
permissions-policy: geolocation=(), microphone=(), camera=()
```

## 7. Health sau hardening

```text
{"db_user":"app_user","ok":true,"status":"ok"}   (rút gọn)
```

Chi tiết `db_host`/`database`/`sslmode` chỉ ở `?detail=1` từ localhost.

## 8. ACME vẫn hoạt động

```text
GET http://kanban.akaine.io.vn/.well-known/acme-challenge/probe → 200
certbot renew --dry-run → PASS
deploy hook /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh → nginx -t + reload
```

## 9. TLS negotiation tại edge

```text
TLS 1.2: New, TLSv1.2, Cipher is ECDHE-ECDSA-CHACHA20-POLY1305, Verify return code: 0
TLS 1.1: handshake failure (bị từ chối, đúng)
```

Chứng chỉ edge (Cloudflare Universal SSL):

```text
subject=CN=akaine.io.vn
issuer=C=US, O=Google Trust Services, CN=WE1
notBefore=Oct  7 11:39:58 2026 GMT
notAfter=Jan  5 12:37:40 2027 GMT
```

## 10. Ghi chú

- `ssl=strict` xác minh cert origin (Let's Encrypt của `kanban`). Apex `akaine.io.vn` đang
  522 vì origin `167.254.69.146` không truy cập được; nếu trỏ apex về origin khác, origin
  đó phải có cert hợp lệ (nếu không → 526).
- `min_tls_version=1.2` áp cho cả zone; TLS 1.0/1.1 bị từ chối.
- HSTS đặt ở nginx cho riêng `kanban`, `max-age=15552000`, không `includeSubDomains`/`preload`.
- Rollback Cloudflare: `PATCH /settings/ssl {value:full}`,
  `PATCH /settings/min_tls_version {value:1.0}`; trên VM bỏ `add_header`/`return 301` nếu cần.
- Ở thời điểm đo hardening, UI còn footer và dropdown user; nay UI đã đổi (bỏ footer, avatar
  menu) — phần UI hiện tại xem [ui.md](ui.md).
- Lỗi 521 ban đầu: origin chỉ listen 80, Cloudflare strict không bắt tay TLS được → thêm
  cert + 443.
