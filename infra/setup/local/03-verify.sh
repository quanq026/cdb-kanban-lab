#!/usr/bin/env bash
set -euo pipefail
set -a; . /etc/cdb/secrets.env; set +a
export PGPASSWORD="$LOCAL_APP_PASSWORD"
CONN="host=127.0.0.1 port=55432 dbname=studydb user=app_user sslmode=disable"

echo "--- identity ---"
psql "$CONN" -c "SELECT current_user, session_user, current_database()"

echo "--- privileges ---"
psql "$CONN" -c "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname='app_user'"

echo "--- CRUD as app_user ---"
psql "$CONN" -c "SELECT count(*) AS visible_tasks FROM tasks"
psql "$CONN" -v ON_ERROR_STOP=1 -c "INSERT INTO tasks(user_id,title) VALUES (1,'kiem tra quyen insert') RETURNING id"
psql "$CONN" -v ON_ERROR_STOP=1 -c "UPDATE tasks SET status='done' WHERE title='kiem tra quyen insert' RETURNING id, status"
psql "$CONN" -v ON_ERROR_STOP=1 -c "DELETE FROM tasks WHERE title='kiem tra quyen insert' RETURNING id"
psql "$CONN" -c "SELECT count(*) AS tasks_after FROM tasks"

echo "--- must fail: read pg_authid (not superuser) ---"
psql "$CONN" -c "SELECT count(*) FROM pg_authid" 2>&1 | tail -2 || true

echo "--- must fail: create table in public schema ---"
psql "$CONN" -c "CREATE TABLE hack(x int)" 2>&1 | tail -2 || true

echo "--- must fail: drop table ---"
psql "$CONN" -c "DROP TABLE tasks" 2>&1 | tail -2 || true
