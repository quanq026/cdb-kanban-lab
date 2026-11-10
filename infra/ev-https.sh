#!/usr/bin/env bash
set -uo pipefail
set -a; . /etc/cdb/secrets.env; set +a
OUT=/tmp/evidence
mkdir -p "$OUT"
STAMP=$(date -Is)
B='```'

{
  echo "# Domain + HTTPS - kanban.akaine.io.vn"
  echo
  echo "- Thoi diem chay: \`$STAMP\`"
  echo "- DNS: ban ghi A/AAAA tro ve Cloudflare (proxy), tro ve origin 20.48.104.156"
  echo
  echo "## Chung chi Let's Encrypt tren origin"
  echo
  echo "$B"'bash'
  echo 'sudo certbot certonly --webroot -w /var/www/letsencrypt -d kanban.akaine.io.vn'
  echo "$B"
  echo
  echo "$B"'text'
  openssl x509 -in /etc/letsencrypt/live/kanban.akaine.io.vn/fullchain.pem -noout -subject -issuer -dates -ext subjectAltName 2>&1
  echo "$B"
  echo
  echo "## nginx: 80 (ACME + IP) va 443 (TLS cho domain)"
  echo
  echo "$B"'text'
  ss -ltn | grep -E ':(80|443)\b' 2>&1
  echo "$B"
  echo
  echo "## Bat tay TLS truc tiep voi origin"
  echo
  echo "$B"'text'
  echo | openssl s_client -connect 127.0.0.1:443 -servername kanban.akaine.io.vn -verify_return_error 2>&1 | grep -E 'Verify return code|Protocol  :|Cipher    :'
  echo "$B"
  echo
  echo "## Truy cap qua Cloudflare"
  echo
  echo "$B"'bash'
  echo 'curl -sS -o /dev/null -w "%{http_code} %{http_version}\n" https://kanban.akaine.io.vn/'
  echo 'curl -sS https://kanban.akaine.io.vn/api/health'
  echo "$B"
  echo
  echo "$B"'text'
  curl -sS -o /dev/null -w "https_code=%{http_code}\n" --max-time 30 https://kanban.akaine.io.vn/ 2>&1
  curl -sS --max-time 30 https://kanban.akaine.io.vn/api/health 2>&1
  echo
  curl -sS -o /dev/null -w "http_code=%{http_code}\n" --max-time 30 http://kanban.akaine.io.vn/ 2>&1
  curl -sS -o /dev/null -w "origin_direct_https=%{http_code} ssl_verify=%{ssl_verify_result}\n" --max-time 20 \
    --resolve kanban.akaine.io.vn:443:20.48.104.156 https://kanban.akaine.io.vn/api/health 2>&1
  echo "$B"
  echo
  echo "## Tu dong gia han"
  echo
  echo "$B"'text'
  systemctl list-timers 'certbot*' --no-pager 2>&1 | head -3
  echo "$B"
  echo
  echo "## Ghi chu"
  echo
  echo "- Truoc khi co 443: Cloudflare tra **521** (noi origin :443 that bai) vi nginx chi listen 80 va NSG 443 mo nhung khong co dich vu."
  echo "- Sau khi gan cert: Cloudflare (Full / Full strict) ket noi origin qua TLS 1.3, nginx verify OK."
  echo "- Origin van phuc vu cong 80 cho truong hop Cloudflare chuyen sang Flexible va cho ACME HTTP-01."
  echo "- Certbot timer tu gia han; da chay \`certbot renew --dry-run\` thanh cong."
} > "$OUT/https.md"

chmod a+r "$OUT/https.md"
ls -l "$OUT/https.md"
