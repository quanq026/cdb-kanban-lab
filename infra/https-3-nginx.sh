#!/usr/bin/env bash
set -euo pipefail

cat > /etc/nginx/sites-available/cdb-kanban <<'CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

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
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 35s;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name kanban.akaine.io.vn;

    ssl_certificate     /etc/letsencrypt/live/kanban.akaine.io.vn/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/kanban.akaine.io.vn/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_prefer_server_ciphers off;

    client_max_body_size 1m;

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
ss -ltn | grep -E ':(80|443|8000)\b'
echo "--- direct origin TLS ---"
curl -sS --max-time 20 --resolve kanban.akaine.io.vn:443:127.0.0.1 https://kanban.akaine.io.vn/api/health; echo
echo "--- cert seen by client ---"
echo | openssl s_client -connect 127.0.0.1:443 -servername kanban.akaine.io.vn 2>/dev/null | openssl x509 -noout -subject -issuer -dates

