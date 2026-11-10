# HTTPS hardening - kanban.akaine.io.vn

- Thoi diem chay: `2026-11-10T08:50:25+07:00`
- Zone Cloudflare: `akaine.io.vn` (chi zone nay; 2 zone khac khong bi dong toi)
- Token Cloudflare doc tu file ngoai repo, khong in ra output

## 1. Cloudflare zone settings (doc lai tu API)

```bash
GET /zones/fc94e4214166b8219e611c7129d37cf8/settings/<name>
```

```text
ssl = strict
min_tls_version = 1.2
always_use_https = on
automatic_https_rewrites = on
tls_1_3 = on
http3 = on
brotli = on
```

## 2. HTTP -> HTTPS (Cloudflare Always Use HTTPS + nginx redirect)

```bash
curl -sS -o /dev/null -D - http://kanban.akaine.io.vn/
```

```text
HTTP/1.1 301 Moved Permanently
Location: https://kanban.akaine.io.vn/
```

## 3. Security headers tren HTTPS (nginx origin, di xuyen Cloudflare)

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

## 4. Health sau khi doi cau hinh

```bash
curl -sS https://kanban.akaine.io.vn/api/health
```

```text
{"backend_addr":"169.254.254.254/32","database":"studydb","db_host":"ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech","db_user":"app_user","sslmode":"verify-full"}
```

## 5. ACME path van truy cap duoc (de gia han cert)

```bash
curl -o /dev/null -w '%{http_code}' http://kanban.akaine.io.vn/.well-known/acme-challenge/probe
```

```text
code=200
```

## 6. TLS negotiation tai edge Cloudflare

```bash
openssl s_client -connect kanban.akaine.io.vn:443 -servername kanban.akaine.io.vn -tls1_2
```

```text
New, TLSv1.2, Cipher is ECDHE-ECDSA-CHACHA20-POLY1305
Protocol: TLSv1.2
    Protocol  : TLSv1.2
    Verify return code: 0 (ok)
```

```bash
openssl s_client ... -tls1_1
```

```text
TLS1.1 bi tu choi (handshake failure)
```

## 7. Chung chi edge (Cloudflare Universal SSL)

```text
subject=CN=akaine.io.vn
issuer=C=US, O=Google Trust Services, CN=WE1
notBefore=Oct  7 11:39:58 2026 GMT
notAfter=Jan  5 12:37:40 2027 GMT
```

## 8. Kiem tra UI qua HTTPS bang browser that

- Mo `https://kanban.akaine.io.vn/` bang Chromium cua agent.
- `location.protocol = https:`, `location.host = kanban.akaine.io.vn`.
- 3 cot render dung: `todo=3`, `doing=1`, `done=1` (user an@example.test).
- Dropdown: `an@example.test (#1)`, `binh@example.test (#2)`.
- Footer: `DB host: ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech - current_user: app_user - database: studydb - sslmode: verify-full`.
- Console errors: `0`; khong co loi mixed content/CSP.

## Ghi chu

- `ssl=strict`: Cloudflare xac minh cert origin (Let's Encrypt cua kanban.akaine.io.vn). Apex `akaine.io.vn` hien tra 522 vi origin 167.254.69.146 khong truy cap duoc; neu sau nay tro apex ve origin khac thi origin do phai co cert hop le, neu khong se la 526.
- `min_tls_version=1.2` ap dung cho ca zone akaine.io.vn; TLS 1.0/1.1 bi tu choi.
- HSTS dat o nginx (chi server `kanban.akaine.io.vn`) voi `max-age=15552000`, khong `includeSubDomains`/`preload` de khong anh huong subdomain khac va con rollback duoc.
- Rollback: `PATCH /settings/ssl {value:full}`, `PATCH /settings/min_tls_version {value:1.0}`; tren VM bo cac dong `add_header` va `return 301` neu can.
