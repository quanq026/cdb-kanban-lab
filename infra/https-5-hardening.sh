#!/usr/bin/env bash
set -euo pipefail

cat > /etc/nginx/sites-available/cdb-kanban <<'CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    server_tokens off;

    client_max_body_size 1m;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type text/plain;
    }

    location / {
        return 301 https://kanban.akaine.io.vn$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name kanban.akaine.io.vn;
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/kanban.akaine.io.vn/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/kanban.akaine.io.vn/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=15552000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    client_max_body_size 1m;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type text/plain;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 35s;
    }
}
CONF

nginx -t
systemctl reload nginx

echo "--- listening ---"
ss -ltn | grep -E ':(80|443|8000)\b' | sort

echo "--- ACME path: port 80 (must be 200, not redirect) ---"
curl -sS -o /dev/null -w "acme80=%{http_code}\n" --max-time 15 -H "Host: kanban.akaine.io.vn" \
  http://127.0.0.1/.well-known/acme-challenge/probe

echo "--- ACME path: port 443 ---"
curl -sS -o /dev/null -w "acme443=%{http_code}\n" --max-time 15 --insecure \
  --resolve kanban.akaine.io.vn:443:127.0.0.1 https://kanban.akaine.io.vn/.well-known/acme-challenge/probe

echo "--- HTTP by IP -> redirect ---"
curl -sS -o /dev/null -D - --max-time 15 http://127.0.0.1/ 2>&1 | grep -Ei 'HTTP/|location:'

echo "--- HTTP with domain Host -> redirect ---"
curl -sS -o /dev/null -D - --max-time 15 -H "Host: kanban.akaine.io.vn" http://127.0.0.1/api/health 2>&1 | grep -Ei 'HTTP/|location:'

echo "--- HTTPS headers + health ---"
curl -sS -o /dev/null -D - --max-time 20 --resolve kanban.akaine.io.vn:443:127.0.0.1 \
  https://kanban.akaine.io.vn/api/health 2>&1 | grep -Ei 'HTTP/|strict-transport|x-content-type|x-frame|referrer-policy|permissions-policy|server:'
curl -sS --max-time 20 --resolve kanban.akaine.io.vn:443:127.0.0.1 https://kanban.akaine.io.vn/api/health; echo

echo "--- renewal dry-run (ACME must still work with redirect + Always Use HTTPS) ---"
certbot renew --dry-run --non-interactive 2>&1 | tail -5
