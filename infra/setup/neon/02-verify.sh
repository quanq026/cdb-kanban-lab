#!/usr/bin/env bash
set -euo pipefail
set -a; . /etc/cdb/secrets.env; set +a

OWNER_URI="postgresql://${NEON_OWNER_USER}:${NEON_OWNER_PASSWORD}@${NEON_HOST}/studydb"
APP_URI="postgresql://app_user:${NEON_APP_PASSWORD}@${NEON_HOST}/studydb"
SSLPARAMS="sslmode=verify-full&sslrootcert=system&channel_binding=require"

echo "=== set app_user password (plaintext, via psql variable ??? Neon rejects SCRAM verifier from \\password) ==="
echo "ALTER ROLE app_user PASSWORD :'pw';" | PGPASSWORD="$NEON_OWNER_PASSWORD" \
  psql "$OWNER_URI?sslmode=verify-full&sslrootcert=system" -v pw="$NEON_APP_PASSWORD"

PGPASSWORD="$NEON_OWNER_PASSWORD" psql "$OWNER_URI?sslmode=verify-full&sslrootcert=system" \
  -c "GRANT CONNECT ON DATABASE studydb TO app_user" \
  -c "GRANT USAGE ON SCHEMA public TO app_user" \
  -c "GRANT SELECT, INSERT, UPDATE, DELETE ON users, tasks TO app_user" \
  -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user"

echo "=== app_user connection with verify-full ==="
export PGPASSWORD="$NEON_APP_PASSWORD"
psql "$APP_URI?$SSLPARAMS" -c '\conninfo'
psql "$APP_URI?$SSLPARAMS" -c "SELECT current_user, session_user, current_database(), inet_server_addr() AS backend_ip"
psql "$APP_URI?$SSLPARAMS" -c "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls, rolcanlogin FROM pg_roles WHERE rolname='app_user'"
psql "$APP_URI?$SSLPARAMS" -c "SELECT count(*) AS users FROM users" -c "SELECT count(*) AS tasks FROM tasks"

echo "=== CRUD as app_user on Neon ==="
psql "$APP_URI?$SSLPARAMS" -v ON_ERROR_STOP=1 \
  -c "INSERT INTO tasks(user_id,title) VALUES (1,'kiem tra tren neon') RETURNING id, status" \
  -c "UPDATE tasks SET status='done' WHERE title='kiem tra tren neon' RETURNING id, status" \
  -c "DELETE FROM tasks WHERE title='kiem tra tren neon' RETURNING id"

echo "=== checksums: local studydb vs Neon ==="
docker exec cdb-study psql -U postgres -d studydb -tAc "SELECT 'local users '||md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users"
psql "$APP_URI?$SSLPARAMS" -tAc "SELECT 'neon  users '||md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users"
docker exec cdb-study psql -U postgres -d studydb -tAc "SELECT 'local tasks '||md5(string_agg(id||'|'||user_id||'|'||title||'|'||status, ',' ORDER BY id)) FROM tasks"
psql "$APP_URI?$SSLPARAMS" -tAc "SELECT 'neon  tasks '||md5(string_agg(id||'|'||user_id||'|'||title||'|'||status, ',' ORDER BY id)) FROM tasks"

echo "=== pooled endpoint (PgBouncer-style, transaction mode) ==="
psql "postgresql://app_user:${NEON_APP_PASSWORD}@${NEON_POOLER_HOST}/studydb?$SSLPARAMS" \
  -c "SELECT current_user" -c "SELECT count(*) AS tasks FROM tasks" 2>&1 | tail -8

echo "=== must fail on Neon: read pg_authid / create table ==="
psql "$APP_URI?$SSLPARAMS" -c "SELECT count(*) FROM pg_authid" 2>&1 | tail -2 || true
psql "$APP_URI?$SSLPARAMS" -c "CREATE TABLE hack(x int)" 2>&1 | tail -2 || true

echo "=== wrong password must fail authentication ==="
PGPASSWORD="wrong-password-xyz" psql "$APP_URI?$SSLPARAMS" -c "SELECT 1" 2>&1 | tail -2 || true

