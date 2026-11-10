#!/usr/bin/env bash
set -euo pipefail
set -a; . /etc/cdb/secrets.env; set +a

docker exec cdb-study psql -U postgres -d studydb -v ON_ERROR_STOP=1 -c "CREATE ROLE app_user LOGIN" 2>/dev/null || echo "role exists"

printf '%s\n%s\n' "$LOCAL_APP_PASSWORD" "$LOCAL_APP_PASSWORD" \
  | docker exec -i cdb-study psql -U postgres -d studydb -c '\password app_user'

docker exec cdb-study psql -U postgres -d studydb -v ON_ERROR_STOP=1 <<'SQL'
GRANT CONNECT ON DATABASE studydb TO app_user;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON users, tasks TO app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;
SQL

echo "--- roles ---"
docker exec cdb-study psql -U postgres -d studydb -c "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolcanlogin FROM pg_roles WHERE rolname IN ('postgres','app_user')"

echo "--- connect as app_user ---"
PGPASSWORD="$LOCAL_APP_PASSWORD" psql "host=127.0.0.1 port=55432 dbname=studydb user=app_user sslmode=disable" \
  -c "SELECT current_user, session_user" -c "SELECT count(*) AS visible_tasks FROM tasks" \
  -c "INSERT INTO tasks(user_id,title) VALUES (1,'kiem tra quyen insert') RETURNING id" \
  -c "DELETE FROM tasks WHERE title='kiem tra quyen insert'" \
  -c "SELECT count(*) AS tasks_after FROM tasks"

echo "--- app_user must NOT be superuser / cannot read pg_authid ---"
PGPASSWORD="$LOCAL_APP_PASSWORD" psql "host=127.0.0.1 port=55432 dbname=studydb user=app_user sslmode=disable" \
  -c "SELECT count(*) FROM pg_authid" 2>&1 | tail -3 || true
