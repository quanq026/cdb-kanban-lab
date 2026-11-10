#!/usr/bin/env bash
set -euo pipefail

DDL="ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash text;"

echo "== local docker (cdb-study / studydb) =="
docker exec -i cdb-study psql -U postgres -d studydb -v ON_ERROR_STOP=1 -c "$DDL"
docker exec cdb-study psql -U postgres -d studydb -Atc \
  "select column_name from information_schema.columns where table_name='users' order by ordinal_position;"

echo "== neon (studydb, owner) =="
set -a
. /etc/cdb/secrets.env
set +a
export PGPASSWORD="$NEON_OWNER_PASSWORD"
psql "host=$NEON_HOST port=5432 dbname=studydb user=$NEON_OWNER_USER sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt" \
  -v ON_ERROR_STOP=1 -c "$DDL"
psql "host=$NEON_HOST port=5432 dbname=studydb user=$NEON_OWNER_USER sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt" \
  -At -c "select column_name from information_schema.columns where table_name='users' order by ordinal_position;"
unset PGPASSWORD

echo "== app_user doc duoc cot moi (table-level GRANT) =="
set -a
. /etc/cdb/app.env
set +a
export PGPASSWORD="$DB_PASSWORD"
psql "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=verify-full sslrootcert=$DB_SSLROOTCERT" \
  -At -c "select current_user || ' ok, rows=' || count(*) from users;"
psql "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=verify-full sslrootcert=$DB_SSLROOTCERT" \
  -At -c "select count(*) as missing_hash from users where password_hash is null;"
