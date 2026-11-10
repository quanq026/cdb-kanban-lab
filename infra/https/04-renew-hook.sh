#!/usr/bin/env bash
set -euo pipefail

install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
nginx -t
systemctl reload nginx
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
chown root:root /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

echo "--- deploy hook ---"
cat /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
ls -l /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

echo "--- dry-run (renewal + hook) ---"
certbot renew --dry-run --non-interactive 2>&1 | tail -6

echo "--- nginx still healthy ---"
nginx -t
curl -sS -o /dev/null -w "health_code=%{http_code}\n" --max-time 20 \
  --resolve kanban.akaine.io.vn:443:127.0.0.1 https://kanban.akaine.io.vn/api/health
