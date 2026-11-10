#!/usr/bin/env bash
set -euo pipefail
set -a; . /etc/cdb/secrets.env; set +a

DUMP=/home/azureuser/studydb-lab.dump
OWNER_URI="postgresql://${NEON_OWNER_USER}:${NEON_OWNER_PASSWORD}@${NEON_HOST}/studydb"
APP_URI="postgresql://app_user:${NEON_APP_PASSWORD}@${NEON_HOST}/studydb"

echo "=== TLS: server certificate chain (openssl starttls postgres) ==="
openssl s_client -starttls postgres -connect "${NEON_HOST}:5432" -servername "$NEON_HOST" -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || echo "openssl check skipped"

echo "=== TLS verify-full with system CA store ==="
if PGPASSWORD="$NEON_OWNER_PASSWORD" psql "$OWNER_URI?sslmode=verify-full&sslrootcert=system" \
     -c "SELECT current_user, version()" -c "SELECT ssl, version, cipher, bits FROM pg_stat_ssl WHERE pid = pg_backend_pid()" 2>/tmp/tls.err; then
  ROOTMODE="sslrootcert=system"
else
  echo "system store failed, pinning chain root:"
  cat /tmp/tls.err
  openssl s_client -starttls postgres -connect "${NEON_HOST}:5432" -servername "$NEON_HOST" -showcerts </dev/null 2>/dev/null \
    | awk '/BEGIN CERTIFICATE/{n++} n>0{print > ("/tmp/c" n ".pem")} /END CERTIFICATE/{if(n>0 && !f[n]++){}}'
  last=$(ls -1 /tmp/c*.pem | sort -V | tail -1)
  cp "$last" /etc/cdb/neon-ca.pem
  chmod 644 /etc/cdb/neon-ca.pem
  ROOTMODE="sslrootcert=/etc/cdb/neon-ca.pem"
  PGPASSWORD="$NEON_OWNER_PASSWORD" psql "$OWNER_URI?sslmode=verify-full&sslrootcert=/etc/cdb/neon-ca.pem" \
    -c "SELECT current_user" -c "SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
fi
echo "rootmode=$ROOTMODE"

echo "=== RESTORE dump into Neon studydb (managed service: --no-owner --no-privileges) ==="
start=$(date +%s%N)
PGPASSWORD="$NEON_OWNER_PASSWORD" pg_restore --exit-on-error --no-owner --no-privileges \
  -d "$OWNER_URI?sslmode=verify-full&sslrootcert=system" "$DUMP"
end=$(date +%s%N)
echo "neon_restore_ms=$(( (end - start) / 1000000 ))"

echo "=== create app_user on Neon with \\password (never written to SQL files) ==="
PGPASSWORD="$NEON_OWNER_PASSWORD" psql "$OWNER_URI?sslmode=verify-full&sslrootcert=system" \
  -c "CREATE ROLE app_user LOGIN"
printf '%s\n%s\n' "$NEON_APP_PASSWORD" "$NEON_APP_PASSWORD" \
  | PGPASSWORD="$NEON_OWNER_PASSWORD" psql "$OWNER_URI?sslmode=verify-full&sslrootcert=system" -c '\password app_user'

PGPASSWORD="$NEON_OWNER_PASSWORD" psql "$OWNER_URI?sslmode=verify-full&sslrootcert=system" \
  -c "GRANT CONNECT ON DATABASE studydb TO app_user" \
  -c "GRANT USAGE ON SCHEMA public TO app_user" \
  -c "GRANT SELECT, INSERT, UPDATE, DELETE ON users, tasks TO app_user" \
  -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user"

echo "=== app_user: verify-full connection, privileges, CRUD ==="
export PGPASSWORD="$NEON_APP_PASSWORD"
psql "$APP_URI?sslmode=verify-full&sslrootcert=system" \
  -c "SELECT current_user, session_user, current_database()" \
  -c "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls FROM pg_roles WHERE rolname='app_user'" \
  -c "SELECT count(*) AS users FROM users" -c "SELECT count(*) AS tasks FROM tasks" \
  -c "SELECT ssl, version, cipher, bits FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
psql "$APP_URI?sslmode=verify-full&sslrootcert=system" -v ON_ERROR_STOP=1 \
  -c "INSERT INTO tasks(user_id,title) VALUES (1,'kiem tra tren neon') RETURNING id" \
  -c "DELETE FROM tasks WHERE title='kiem tra tren neon' RETURNING id"

echo "=== content checksums: local studydb vs Neon ==="
docker exec cdb-study psql -U postgres -d studydb -tAc "SELECT 'local users '||md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users"
psql "$APP_URI?sslmode=verify-full&sslrootcert=system" -tAc "SELECT 'neon  users '||md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users"
docker exec cdb-study psql -U postgres -d studydb -tAc "SELECT 'local tasks '||md5(string_agg(id||'|'||user_id||'|'||title||'|'||status, ',' ORDER BY id)) FROM tasks"
psql "$APP_URI?sslmode=verify-full&sslrootcert=system" -tAc "SELECT 'neon  tasks '||md5(string_agg(id||'|'||user_id||'|'||title||'|'||status, ',' ORDER BY id)) FROM tasks"

echo "=== pooled endpoint note ==="
psql "postgresql://app_user:${NEON_APP_PASSWORD}@${NEON_POOLER_HOST}/studydb?sslmode=verify-full&sslrootcert=system" \
  -c "SELECT current_user, inet_server_addr() AS backend_addr, count(*) OVER () AS rows_per_pooler" -c "SELECT count(*) FROM tasks" 2>&1 | tail -6 || true

echo "=== must fail on Neon: read pg_authid / create table ==="
psql "$APP_URI?sslmode=verify-full&sslrootcert=system" -c "SELECT count(*) FROM pg_authid" 2>&1 | tail -2 || true
psql "$APP_URI?sslmode=verify-full&sslrootcert=system" -c "CREATE TABLE hack(x int)" 2>&1 | tail -2 || true
