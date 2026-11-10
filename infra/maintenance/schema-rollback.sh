#!/usr/bin/env bash
# Rollback GĐ C schema: bỏ tasks.position/created_at/updated_at, trả index cũ.
# Bản canonical: infra/maintenance/sql/2026-11-10-task-order-rollback.sql.
set -euo pipefail

SQL=$(cat <<'SQL'
BEGIN;

DROP TRIGGER IF EXISTS trg_tasks_updated_at ON tasks;
DROP FUNCTION IF EXISTS tasks_touch_updated_at();

DROP INDEX IF EXISTS idx_tasks_user_status_position;
CREATE INDEX IF NOT EXISTS idx_tasks_user_status ON tasks (user_id, status);

ALTER TABLE tasks DROP COLUMN IF EXISTS updated_at;
ALTER TABLE tasks DROP COLUMN IF EXISTS created_at;
ALTER TABLE tasks DROP COLUMN IF EXISTS position;

COMMIT;
SQL
)

echo "== rollback local docker =="
printf '%s\n' "$SQL" | docker exec -i cdb-study psql -U postgres -d studydb -v ON_ERROR_STOP=1

echo "== rollback neon =="
set -a
. /etc/cdb/secrets.env
set +a
export PGPASSWORD="$NEON_OWNER_PASSWORD"
NEON_DSN="host=$NEON_HOST port=5432 dbname=studydb user=$NEON_OWNER_USER sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt"
printf '%s\n' "$SQL" | psql "$NEON_DSN" -v ON_ERROR_STOP=1
unset PGPASSWORD

echo "== verify =="
docker exec cdb-study psql -U postgres -d studydb -Atc \
  "select count(*) from information_schema.columns
    where table_name = 'tasks' and column_name in ('position','created_at','updated_at');"
