#!/usr/bin/env bash
# One-time HTTPS setup: Let's Encrypt certificate, nginx TLS server, renewal hook.
#
# Assumes DNS for the domain already points at this VM and ports 80/443 are open.
# Idempotent: re-running renews/reuses the certificate and rewrites the config.
#
# Usage (on the VM): sudo bash infra/setup/https.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

DOMAIN="${DOMAIN:-kanban.akaine.io.vn}"
WEBROOT=/var/www/letsencrypt
SITE=/etc/nginx/sites-available/cdb-kanban
ENABLED=/etc/nginx/sites-enabled/cdb-kanban

# 1. ACME webroot + temporary HTTP server (also proxies to the app).
install -d -m 755 "$WEBROOT/.well-known/acme-challenge"
echo "acme-probe-ok" > "$WEBROOT/.well-known/acme-challenge/probe"

cat > "$SITE" <<CONF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 1m;

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 35s;
    }
}
CONF
ln -sf "$SITE" "$ENABLED"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# 2. Certificate.
apt-get update -qq
apt-get install -y -qq certbot >/dev/null
certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
  --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring
openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -subject -issuer -dates

# 3. Hardened TLS server: 80 redirects, 443 proxies with security headers.
cat > "$SITE" <<CONF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    server_tokens off;

    client_max_body_size 1m;

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
    }

    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
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
        root $WEBROOT;
        default_type text/plain;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 35s;
    }
}
CONF
nginx -t
systemctl reload nginx

# 4. Reload nginx after each renewal.
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
nginx -t
systemctl reload nginx
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
chown root:root /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# 5. Verify: TLS 1.2/1.3, redirect, headers, ACME, renewal dry-run.
echo "--- listening ---"
ss -ltn | grep -E ':(80|443|8000)\b' | sort || true
echo "--- HTTP -> HTTPS ---"
curl -sS -o /dev/null -D - --max-time 15 -H "Host: $DOMAIN" http://127.0.0.1/api/health 2>&1 | grep -Ei 'HTTP/|location:' || true
echo "--- HTTPS health + headers ---"
curl -sS -o /dev/null -D - --max-time 20 --resolve "$DOMAIN:443:127.0.0.1" \
  "https://$DOMAIN/api/health" 2>&1 | grep -Ei 'HTTP/|strict-transport|x-content-type|x-frame|referrer-policy|permissions-policy|server:' || true
curl -sS --max-time 20 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/health"; echo
echo "--- renewal dry-run ---"
certbot renew --dry-run --non-interactive 2>&1 | tail -5
