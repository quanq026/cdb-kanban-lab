#!/usr/bin/env bash
set -euo pipefail

install -d -m 755 /var/www/letsencrypt/.well-known/acme-challenge
echo "acme-test-ok-9f3a" > /var/www/letsencrypt/.well-known/acme-challenge/probe

cp -n /etc/nginx/sites-available/cdb-kanban /etc/nginx/sites-available/cdb-kanban.bak

if ! grep -q 'acme-challenge' /etc/nginx/sites-available/cdb-kanban; then
python3 - <<'PY'
p = '/etc/nginx/sites-available/cdb-kanban'
s = open(p).read()
block = '''
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type text/plain;
    }
'''
s = s.replace('    location / {', block + '\n    location / {', 1)
open(p, 'w').write(s)
PY
fi

nginx -t
systemctl reload nginx
echo "--- probe file ---"
ls -l /var/www/letsencrypt/.well-known/acme-challenge/probe
echo "--- config ---"
cat /etc/nginx/sites-available/cdb-kanban
