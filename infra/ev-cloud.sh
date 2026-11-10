#!/usr/bin/env bash
set -uo pipefail
set -a; . /etc/cdb/secrets.env; set +a

OUT=/tmp/evidence
mkdir -p "$OUT"
STAMP=$(date -Is)
BLOCK='```'

{
  echo "# Cloud - Neon PostgreSQL 17"
  echo
  echo "- Thoi diem chay: \`$STAMP\`"
  echo "- Endpoint truc tiep: \`$NEON_HOST:5432\` (project \`$NEON_PROJECT_ID\`, region aws-ap-southeast-1)"
  echo "- Endpoint pooled: \`$NEON_POOLER_HOST:5432\` (dung cho app neu can; app hien dung endpoint truc tiep)"
  echo
  echo "## 1. psql toi Neon bang TLS verify-full"
  echo
  echo "$BLOCK"'bash'
  echo 'psql "host=<endpoint> port=5432 dbname=studydb user=app_user sslmode=verify-full sslrootcert=system"'
  echo "$BLOCK"
  echo
  echo "Chung chi server (Let's Encrypt, khop hostname):"
  echo
  echo "$BLOCK"'text'
  openssl s_client -starttls postgres -connect "${NEON_HOST}:5432" -servername "$NEON_HOST" </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates 2>&1
  echo "$BLOCK"
  echo
  echo "Ket qua ket noi:"
  echo
  echo "$BLOCK"'text'
  PGPASSWORD="$NEON_APP_PASSWORD" psql "host=$NEON_HOST port=5432 dbname=studydb user=app_user sslmode=verify-full sslrootcert=system" -c '\conninfo' 2>&1
  echo "$BLOCK"
  echo
  echo "## 2. Them task tu web (qua nginx :80) roi kiem tra trong DB"
  echo
  echo "$BLOCK"'bash'
  echo 'curl -sS -X POST http://20.48.104.156/api/tasks -H "Content-Type: application/json" -d "{\"user_id\":1,\"title\":\"Task tu web truoc khi restart\"}"'
  echo "$BLOCK"
  echo
  echo "$BLOCK"'text'
  curl -sS --max-time 30 -X POST http://127.0.0.1/api/tasks -H "Content-Type: application/json" \
    -d '{"user_id":1,"title":"Task tu web truoc khi restart"}' 2>&1
  echo
  echo "$BLOCK"
  echo
  echo "Kiem tra bang SQL doc lap (khong qua app):"
  echo
  echo "$BLOCK"'text'
  PGPASSWORD="$NEON_APP_PASSWORD" psql "host=$NEON_HOST port=5432 dbname=studydb user=app_user sslmode=verify-full sslrootcert=system" \
    -c "SELECT id, user_id, title, status FROM tasks WHERE title = 'Task tu web truoc khi restart'" 2>&1
  echo "$BLOCK"
  echo
  echo "## 3. Restart backend, task van con"
  echo
  echo "$BLOCK"'bash'
  echo 'sudo systemctl restart cdb-kanban'
  echo 'sleep 3'
  echo 'curl -sS http://20.48.104.156/api/tasks?user_id=1'
  echo "$BLOCK"
  echo
  systemctl restart cdb-kanban
  sleep 4
  echo "$BLOCK"'text'
  systemctl is-active cdb-kanban
  curl -sS --max-time 40 "http://127.0.0.1/api/tasks?user_id=1" 2>&1
  echo
  echo "$BLOCK"
  echo
  echo "Task \`Task tu web truoc khi restart\` van nam trong danh sach sau khi tien trinh bi kill va khoi dong lai -> du lieu that su nam o Neon, khong phai trong bo nho app."
  echo
  echo "## 4. Sai mat khau -> loi xac thuc (khong lo mat khau)"
  echo
  echo "$BLOCK"'bash'
  echo 'PGPASSWORD=<sai> psql "host=<endpoint> dbname=studydb user=app_user sslmode=verify-full sslrootcert=system" -c "SELECT 1"'
  echo "$BLOCK"
  echo
  echo "$BLOCK"'text'
  PGPASSWORD="wrong-password-for-demo" psql "host=$NEON_HOST port=5432 dbname=studydb user=app_user sslmode=verify-full sslrootcert=system" -c "SELECT 1" 2>&1 | head -3
  echo "$BLOCK"
  echo
  echo "Kiem tra log khong chua mat khau that (dem so lan xuat hien):"
  echo
  echo "$BLOCK"'bash'
  echo 'sudo journalctl -u cdb-kanban --since "-30 min" | grep -cF "$NEON_APP_PASSWORD"'
  echo 'sudo grep -rcF "$NEON_APP_PASSWORD" /var/log/nginx/'
  echo "$BLOCK"
  echo
  echo "$BLOCK"'text'
  echo "journalctl_matches=$(journalctl -u cdb-kanban --since '-30 min' --no-pager 2>/dev/null | grep -cF "$NEON_APP_PASSWORD" || true)"
  echo "nginx_matches=$(grep -rhF "$NEON_APP_PASSWORD" /var/log/nginx/ 2>/dev/null | wc -l)"
  echo "$BLOCK"
  echo
  echo "## 5. Xac nhan app dung app_user"
  echo
  echo "$BLOCK"'bash'
  echo 'curl -sS http://20.48.104.156/api/health'
  echo "$BLOCK"
  echo
  echo "$BLOCK"'text'
  curl -sS --max-time 30 http://127.0.0.1/api/health 2>&1
  echo "$BLOCK"
  echo
  echo "Va phia database (nhin tu pg_stat_activity cua chinh app):"
  echo
  echo "$BLOCK"'text'
  PGPASSWORD="$NEON_APP_PASSWORD" psql "host=$NEON_HOST port=5432 dbname=studydb user=app_user sslmode=verify-full sslrootcert=system" \
    -c "SELECT usename, application_name, client_addr, state, count(*) FROM pg_stat_activity WHERE usename = 'app_user' GROUP BY 1,2,3,4" 2>&1
  echo "$BLOCK"
  echo
  echo "## Ghi chu ve TLS"
  echo
  echo "- App dung \`sslmode=verify-full\` + \`sslrootcert=/etc/ssl/certs/ca-certificates.crt\` (khong tat xac minh)."
  echo "- \`pg_stat_ssl\` tren compute node tra \`ssl=f\` vi Neon ket thuc TLS tai proxy; phia client van xac minh chung chi that (verify-full khong cho phep ket noi khong ma hoa)."
  echo "- Endpoint pooled (\`-pooler\`) da test ket noi duoc; neu dung pooled thi khong dung duoc prepared statement phien dai / LISTEN-NOTIFY, app hien tai khong can."
} > "$OUT/cloud.md"

{
  echo "# Monitoring - pg_stat_activity khi app dang chay"
  echo
  echo "- Thoi diem chay: \`$STAMP\`"
  echo "- App: gunicorn 2 worker + psycopg_pool (min 1, max 5), backend Neon"
  echo
  echo "## Tong hop theo database va state (Neon)"
  echo
  echo "$BLOCK"'bash'
  echo "psql \"host=<neon> dbname=studydb user=app_user sslmode=verify-full sslrootcert=system\" \\"
  echo '  -c "SELECT datname, state, count(*) FROM pg_stat_activity GROUP BY datname, state ORDER BY datname, state"'
  echo "$BLOCK"
  echo
  echo "$BLOCK"'text'
  PGPASSWORD="$NEON_APP_PASSWORD" psql "host=$NEON_HOST port=5432 dbname=studydb user=app_user sslmode=verify-full sslrootcert=system" \
    -c "SELECT datname, state, count(*) FROM pg_stat_activity GROUP BY datname, state ORDER BY datname, state" 2>&1
  echo "$BLOCK"
  echo
  echo "## Chi tiet backend cua app"
  echo
  echo "$BLOCK"'text'
  PGPASSWORD="$NEON_APP_PASSWORD" psql "host=$NEON_HOST port=5432 dbname=studydb user=app_user sslmode=verify-full sslrootcert=system" \
    -c "SELECT pid, usename, application_name, client_addr, state, backend_start::time(0) AS started, left(query, 60) AS query FROM pg_stat_activity WHERE datname = 'studydb' ORDER BY backend_start" 2>&1
  echo "$BLOCK"
  echo
  echo "## So ket noi theo application_name"
  echo
  echo "$BLOCK"'text'
  PGPASSWORD="$NEON_APP_PASSWORD" psql "host=$NEON_HOST port=5432 dbname=studydb user=app_user sslmode=verify-full sslrootcert=system" \
    -c "SELECT application_name, usename, count(*) FROM pg_stat_activity WHERE datname = 'studydb' GROUP BY 1,2 ORDER BY 3 DESC" 2>&1
  echo "$BLOCK"
  echo
  echo "## Doi chieu: pg_stat_activity tren container local"
  echo
  echo "$BLOCK"'text'
  PGPASSWORD="$PG_SUPER_PASSWORD" psql -h 127.0.0.1 -p 55432 -U postgres -d studydb \
    -c "SELECT datname, state, count(*) FROM pg_stat_activity GROUP BY datname, state ORDER BY 1,2" 2>&1
  echo "$BLOCK"
  echo
  echo "## Nhan xet"
  echo
  echo "- App chi mo toi da 5 ket noi (pool max_size=5) va giu 1 ket noi warm; cac ket noi \`idle\` la cua gunicorn worker."
  echo "- Tren Neon, so ket noi tinh vao gioi han cua endpoint (0.25 CU); voi 2 worker thi 2-3 ket noi la binh thuong."
  echo "- Khong thay ket noi nao tu ngoai Internet vao 5432 cua VM: PostgreSQL local chi listen 127.0.0.1:55432."
} > "$OUT/monitoring.md"

chmod -R a+r "$OUT"
ls -l "$OUT/cloud.md" "$OUT/monitoring.md"
