set -euo pipefail

DDL="ALTER TABLE users DROP COLUMN IF EXISTS password_hash;"

echo "== rollback local docker =="
docker exec -i cdb-study psql -U postgres -d studydb -v ON_ERROR_STOP=1 -c "$DDL"

echo "== rollback neon =="
set -a
. /etc/cdb/secrets.env
set +a
export PGPASSWORD="$NEON_OWNER_PASSWORD"
psql "host=$NEON_HOST port=5432 dbname=studydb user=$NEON_OWNER_USER sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt" \
  -v ON_ERROR_STOP=1 -c "$DDL"
unset PGPASSWORD

echo "== verify =="
docker exec cdb-study psql -U postgres -d studydb -Atc \
  "select count(*) from information_schema.columns where table_name='users' and column_name='password_hash';"
