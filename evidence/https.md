# Domain + HTTPS - kanban.akaine.io.vn

- Thoi diem chay: `2026-11-09T10:10:45+00:00`
- DNS: ban ghi A/AAAA tro ve Cloudflare (proxy), tro ve origin 20.48.104.156

## Chung chi Let's Encrypt tren origin

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

## nginx: 80 (ACME + IP) va 443 (TLS cho domain)

```text
LISTEN 0      511          0.0.0.0:443        0.0.0.0:*          
LISTEN 0      511          0.0.0.0:80         0.0.0.0:*          
LISTEN 0      511             [::]:443           [::]:*          
LISTEN 0      511             [::]:80            [::]:*          
```

## Bat tay TLS truc tiep voi origin

```text
Verify return code: 0 (ok)
    Protocol  : TLSv1.3
    Cipher    : TLS_AES_256_GCM_SHA384
    Verify return code: 0 (ok)
    Protocol  : TLSv1.3
    Cipher    : TLS_AES_256_GCM_SHA384
    Verify return code: 0 (ok)
```

## Truy cap qua Cloudflare

```bash
curl -sS -o /dev/null -w "%{http_code} %{http_version}\n" https://kanban.akaine.io.vn/
curl -sS https://kanban.akaine.io.vn/api/health
```

```text
https_code=200
{"backend_addr":"169.254.254.254/32","database":"studydb","db_host":"ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech","db_user":"app_user","sslmode":"verify-full"}

http_code=200
origin_direct_https=200 ssl_verify=0
```

## Tu dong gia han

```text
NEXT                        LEFT LAST PASSED UNIT          ACTIVATES
Mon 2026-11-09 19:08:55 UTC   8h -         - certbot.timer certbot.service

```

## Ghi chu

- Truoc khi co 443: Cloudflare tra **521** (noi origin :443 that bai) vi nginx chi listen 80 va NSG 443 mo nhung khong co dich vu.
- Sau khi gan cert: Cloudflare (Full / Full strict) ket noi origin qua TLS 1.3, nginx verify OK.
- Origin van phuc vu cong 80 cho truong hop Cloudflare chuyen sang Flexible va cho ACME HTTP-01.
- Certbot timer tu gia han; da chay `certbot renew --dry-run` thanh cong.
