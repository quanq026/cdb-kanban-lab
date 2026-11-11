#!/usr/bin/env bash
# Restore a local dump into Neon and prepare the least-privilege app role.
#
# Reads credentials from /etc/cdb/secrets.env and the dump from
# /home/azureuser/studydb-lab.dump (created by pg_dump -Fc on the local container).
# Idempotent enough to re-run: role creation and grants are guarded.
#
# Usage (on the VM): sudo bash infra/setup/neon.sh
set -euo pipefail

SECRETS=/etc/cdb/secrets.env
DUMP="${DUMP:-/home/azureuser/studydb-lab.dump}"

set -a
. "$SECRETS"
set +a

OWNER_URI="postgresql://${NEON_OWNER_USER}:${NEON_OWNER_PASSWORD}@${NEON_HOST}/studydb"
APP_URI="postgresql://app_user:${NEON_APP_PASSWORD}@${NEON_HOST}/studydb"
SSL="sslmode=verify-full&sslrootcert=system"

if [ ! -f "$DUMP" ]; then
  echo "dump not found: $DUMP" >&2
  exit 2
fi

# 1. TLS sanity: verify-full against Neon with the system CA store.
echo "--- TLS verify-full ---"
PGPASSWORD="$NEON_OWNER_PASSWORD" psql "$OWNER_URI?$SSL" \
  -c "SELECT current_user, version()" \
  -c "SELECT ssl, version, cipher, bits FROM pg_stat_ssl WHERE pid = pg_backend_pid()"

# 2. Restore (managed service: no owners/privileges).
echo "--- restore ---"
PGPASSWORD="$NEON_OWNER_PASSWORD" pg_restore --exit-on-error --no-owner --no-privileges \
  -d "$OWNER_URI?$SSL" "$DUMP"

# 3. app_user + grants. Plaintext password via psql variable; never written to SQL files.
echo "--- app_user ---"
PGPASSWORD="$NEON_OWNER_PASSWORD" psql "$OWNER_URI?$SSL" \
  -c "CREATE ROLE app_user LOGIN" 2>/dev/null || echo "role app_user exists"
echo "ALTER ROLE app_user PASSWORD :'pw';" \
  | PGPASSWORD="$NEON_OWNER_PASSWORD" psql "$OWNER_URI?$SSL" -v pw="$NEON_APP_PASSWORD"
PGPASSWORD="$NEON_OWNER_PASSWORD" psql "$OWNER_URI?$SSL" \
  -c "GRANT CONNECT ON DATABASE studydb TO app_user" \
  -c "GRANT USAGE ON SCHEMA public TO app_user" \
  -c "GRANT SELECT, INSERT, UPDATE, DELETE ON users, tasks TO app_user" \
  -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user"

# 4. Verify as app_user: TLS, privileges, CRUD.
echo "--- verify as app_user ---"
export PGPASSWORD="$NEON_APP_PASSWORD"
psql "$APP_URI?$SSL" \
  -c "SELECT current_user, session_user, current_database()" \
  -c "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname='app_user'" \
  -c "SELECT count(*) AS users FROM users" \
  -c "SELECT count(*) AS tasks FROM tasks" \
  -c "SELECT ssl, version, cipher, bits FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
psql "$APP_URI?$SSL" -v ON_ERROR_STOP=1 \
  -c "INSERT INTO tasks(user_id,title) VALUES (1,'kiem tra tren neon') RETURNING id" \
  -c "DELETE FROM tasks WHERE title='kiem tra tren neon' RETURNING id"
