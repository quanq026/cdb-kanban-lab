#!/usr/bin/env bash
# Local PostgreSQL 17 in Docker, for dump/restore practice.
#
# Creates container cdb-study on 127.0.0.1:55432, applies the schema, creates a
# least-privilege app_user, and verifies access. Idempotent: re-running keeps the
# existing volume and data.
#
# Usage (on the VM): sudo SCHEMA=/path/to/schema.sql bash infra/setup/local-db.sh
# `schema.sql` is infra/setup/schema.sql from this repo. Default path:
# /opt/cdb/schema.sql.
set -euo pipefail

SECRETS=/etc/cdb/secrets.env
SCHEMA="${SCHEMA:-/opt/cdb/schema.sql}"

set -a
. "$SECRETS"
set +a

if [ ! -f "$SCHEMA" ]; then
  echo "schema not found: $SCHEMA (copy infra/setup/schema.sql there or set SCHEMA=)" >&2
  exit 2
fi

# 1. Volume + container.
docker volume create cdb-study-data >/dev/null
docker rm -f cdb-study >/dev/null 2>&1 || true
docker run -d --name cdb-study --restart unless-stopped \
  -e POSTGRES_PASSWORD="$PG_SUPER_PASSWORD" \
  -e POSTGRES_DB=studydb \
  -p 127.0.0.1:55432:5432 \
  -v cdb-study-data:/var/lib/postgresql/data \
  postgres:17 >/dev/null

for _ in $(seq 1 60); do
  docker exec cdb-study pg_isready -U postgres -d studydb >/dev/null 2>&1 && break
  sleep 2
done

# 2. Schema.
docker exec -i cdb-study psql -v ON_ERROR_STOP=1 -U postgres -d studydb -f - < "$SCHEMA"

# 3. Least-privilege app_user.
docker exec cdb-study psql -U postgres -d studydb -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE app_user LOGIN" 2>/dev/null || echo "role app_user exists"

printf '%s\n%s\n' "$LOCAL_APP_PASSWORD" "$LOCAL_APP_PASSWORD" \
  | docker exec -i cdb-study psql -U postgres -d studydb -c '\password app_user'

docker exec cdb-study psql -U postgres -d studydb -v ON_ERROR_STOP=1 <<'SQL'
GRANT CONNECT ON DATABASE studydb TO app_user;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON users, tasks TO app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;
SQL

# 4. Verify: connect as app_user, CRUD, and least-privilege boundaries.
CONN="host=127.0.0.1 port=55432 dbname=studydb user=app_user sslmode=disable"
echo "--- identity ---"
PGPASSWORD="$LOCAL_APP_PASSWORD" psql "$CONN" -c "SELECT current_user, session_user, current_database()"
echo "--- privileges ---"
PGPASSWORD="$LOCAL_APP_PASSWORD" psql "$CONN" -c "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname='app_user'"
echo "--- CRUD ---"
PGPASSWORD="$LOCAL_APP_PASSWORD" psql "$CONN" -v ON_ERROR_STOP=1 \
  -c "INSERT INTO tasks(user_id,title) VALUES (1,'kiem tra quyen insert') RETURNING id" \
  -c "UPDATE tasks SET status='done' WHERE title='kiem tra quyen insert' RETURNING id, status" \
  -c "DELETE FROM tasks WHERE title='kiem tra quyen insert' RETURNING id"
echo "--- must fail: read pg_authid / create table / drop table ---"
PGPASSWORD="$LOCAL_APP_PASSWORD" psql "$CONN" -c "SELECT count(*) FROM pg_authid" 2>&1 | tail -2 || true
PGPASSWORD="$LOCAL_APP_PASSWORD" psql "$CONN" -c "CREATE TABLE hack(x int)" 2>&1 | tail -2 || true
PGPASSWORD="$LOCAL_APP_PASSWORD" psql "$CONN" -c "DROP TABLE tasks" 2>&1 | tail -2 || true

echo "--- counts ---"
docker exec cdb-study psql -U postgres -d studydb -c \
  "SELECT count(*) AS users FROM users; SELECT count(*) AS tasks FROM tasks;"
