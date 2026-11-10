#!/usr/bin/env bash
set -euo pipefail
set -a; . /etc/cdb/secrets.env; set +a

install -d -o azureuser -g azureuser /opt/cdb/app
install -m 644 -o azureuser -g azureuser /tmp/app.py /opt/cdb/app/app.py
install -m 644 -o azureuser -g azureuser /tmp/index.html /opt/cdb/app/index.html

if [ ! -x /opt/cdb/venv/bin/python ]; then
  python3 -m venv /opt/cdb/venv
fi
/opt/cdb/venv/bin/pip install --quiet --upgrade pip
/opt/cdb/venv/bin/pip install --quiet flask gunicorn "psycopg[binary,pool]"
/opt/cdb/venv/bin/pip freeze | sort

umask 077
cat > /etc/cdb/app.env <<ENV
DB_HOST=${NEON_HOST}
DB_PORT=5432
DB_NAME=studydb
DB_USER=app_user
DB_PASSWORD=${NEON_APP_PASSWORD}
DB_SSLMODE=verify-full
DB_SSLROOTCERT=system
ENV
chown root:root /etc/cdb/app.env
chmod 600 /etc/cdb/app.env

install -m 644 /tmp/cdb-kanban.service /etc/systemd/system/cdb-kanban.service
install -m 644 /tmp/nginx-cdb.conf /etc/nginx/sites-available/cdb-kanban
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/cdb-kanban /etc/nginx/sites-enabled/cdb-kanban

systemctl daemon-reload
systemctl enable cdb-kanban >/dev/null
systemctl restart cdb-kanban
nginx -t
systemctl restart nginx

sleep 3
echo "=== service state ==="
systemctl is-active cdb-kanban nginx
echo "=== health on loopback ==="
curl -sS --max-time 25 http://127.0.0.1/api/health; echo
echo "=== index title ==="
curl -sS --max-time 15 http://127.0.0.1/ | grep -o '<title>.*</title>'
