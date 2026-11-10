#!/usr/bin/env bash
set -euo pipefail

sed -i 's|^DB_SSLROOTCERT=.*|DB_SSLROOTCERT=/etc/ssl/certs/ca-certificates.crt|' /etc/cdb/app.env
grep -E '^DB_(HOST|PORT|NAME|USER|SSLMODE|SSLROOTCERT)=' /etc/cdb/app.env
ls -l /etc/ssl/certs/ca-certificates.crt

systemctl restart cdb-kanban
sleep 4
echo "=== health ==="
curl -sS --max-time 30 http://127.0.0.1/api/health; echo
echo "=== users ==="
curl -sS --max-time 30 http://127.0.0.1/api/users; echo
echo "=== tasks user 1 ==="
curl -sS --max-time 30 "http://127.0.0.1/api/tasks?user_id=1"; echo
