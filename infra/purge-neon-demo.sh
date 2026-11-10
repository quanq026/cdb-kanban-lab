set -euo pipefail

STAMP=$(date +%F-%H%M%S)
OUT="/home/azureuser/neon-demo-purge-$STAMP.sql"
PG_DUMP=$(command -v pg_dump || true)
if [ -z "$PG_DUMP" ]; then PG_DUMP=/usr/lib/postgresql/17/bin/pg_dump; fi

set -a
. /etc/cdb/secrets.env
set +a
export PGPASSWORD="$NEON_OWNER_PASSWORD"
DSN="host=$NEON_HOST port=5432 dbname=studydb user=$NEON_OWNER_USER sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt"

echo "== backup truoc khi xoa =="
"$PG_DUMP" "$DSN" -t users -t tasks --data-only --column-inserts --no-owner > "$OUT"
test -s "$OUT"
stat -c '%s bytes %n' "$OUT"

echo "== truoc khi xoa =="
psql "$DSN" -At -c "select 'users=' || count(*) from users;"
psql "$DSN" -At -c "select 'tasks=' || count(*) from tasks;"

echo "== xoa (tasks truoc de khong vi pham FK) =="
psql "$DSN" -v ON_ERROR_STOP=1 -c "DELETE FROM tasks;"
psql "$DSN" -v ON_ERROR_STOP=1 -c "DELETE FROM users;"

echo "== sau khi xoa (owner) =="
psql "$DSN" -At -c "select 'users=' || count(*) from users;"
psql "$DSN" -At -c "select 'tasks=' || count(*) from tasks;"
unset PGPASSWORD

echo "== app_user nhin thay =="
set -a
. /etc/cdb/app.env
set +a
export PGPASSWORD="$DB_PASSWORD"
DSN2="host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=verify-full sslrootcert=$DB_SSLROOTCERT"
psql "$DSN2" -At -c "select 'users=' || count(*) from users;"
psql "$DSN2" -At -c "select 'tasks=' || count(*) from tasks;"
unset PGPASSWORD

rm -f /etc/cdb/demo-login.txt
echo "demo-login.txt=removed"
echo "purge_backup=$OUT"
