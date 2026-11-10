#!/usr/bin/env bash
# GĐ C schema migration: tasks.position + created_at + updated_at.
# Bản canonical: infra/ops/maintenance/sql/2026-11-10-task-order.sql (giữ đồng bộ).
# run-remote.ps1 chỉ scp 1 file nên SQL được nhúng ở đây.
set -euo pipefail

SQL=$(cat <<'SQL'
BEGIN;

ALTER TABLE tasks ADD COLUMN IF NOT EXISTS position   integer;
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS created_at timestamptz;
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS updated_at timestamptz;

WITH ranked AS (
    SELECT id,
           row_number() OVER (PARTITION BY user_id, status ORDER BY id) - 1 AS pos
    FROM tasks
)
UPDATE tasks AS t
SET position = ranked.pos
FROM ranked
WHERE t.id = ranked.id
  AND t.position IS NULL;

UPDATE tasks SET created_at = now() WHERE created_at IS NULL;
UPDATE tasks SET updated_at = created_at WHERE updated_at IS NULL;

ALTER TABLE tasks ALTER COLUMN position   SET DEFAULT 0;
ALTER TABLE tasks ALTER COLUMN position   SET NOT NULL;
ALTER TABLE tasks ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE tasks ALTER COLUMN created_at SET NOT NULL;
ALTER TABLE tasks ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE tasks ALTER COLUMN updated_at SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tasks_user_status_position
    ON tasks (user_id, status, position);
DROP INDEX IF EXISTS idx_tasks_user_status;

CREATE OR REPLACE FUNCTION tasks_touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tasks_updated_at ON tasks;
CREATE TRIGGER trg_tasks_updated_at
    BEFORE UPDATE ON tasks
    FOR EACH ROW
    EXECUTE FUNCTION tasks_touch_updated_at();

COMMENT ON COLUMN tasks.position   IS 'Thu tu thu cong trong (user_id, status); nho hon = truoc';
COMMENT ON COLUMN tasks.created_at IS 'Thoi diem tao (UTC)';
COMMENT ON COLUMN tasks.updated_at IS 'Thoi diem cap nhat cuoi (trigger)';

COMMIT;
SQL
)

echo "== migrate local docker (cdb-study / studydb) =="
printf '%s\n' "$SQL" | docker exec -i cdb-study psql -U postgres -d studydb -v ON_ERROR_STOP=1
docker exec cdb-study psql -U postgres -d studydb -Atc \
  "select table_name || ':' || string_agg(column_name, ',' order by ordinal_position)
     from information_schema.columns where table_name = 'tasks' group by table_name;"

echo "== migrate neon (studydb, owner) =="
set -a
. /etc/cdb/secrets.env
set +a
export PGPASSWORD="$NEON_OWNER_PASSWORD"
NEON_DSN="host=$NEON_HOST port=5432 dbname=studydb user=$NEON_OWNER_USER sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt"
printf '%s\n' "$SQL" | psql "$NEON_DSN" -v ON_ERROR_STOP=1
psql "$NEON_DSN" -Atc \
  "select table_name || ':' || string_agg(column_name, ',' order by ordinal_position)
     from information_schema.columns where table_name = 'tasks' group by table_name;"
unset PGPASSWORD

echo "== app_user doc/ghi duoc cot moi + trigger (transaction rollback) =="
set -a
. /etc/cdb/app.env
set +a
export PGPASSWORD="$DB_PASSWORD"
APP_DSN="host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=verify-full sslrootcert=$DB_SSLROOTCERT"
psql "$APP_DSN" -v ON_ERROR_STOP=1 <<'APP_SQL'
BEGIN;
SELECT current_user AS db_user,
       count(*) AS tasks,
       count(position) AS with_position,
       count(created_at) AS with_created_at
FROM tasks;
INSERT INTO tasks (user_id, title, position)
SELECT id, 'migrate-check', 0 FROM users ORDER BY id LIMIT 1
RETURNING id, position, created_at IS NOT NULL AS has_created,
          updated_at IS NOT NULL AS has_updated;
UPDATE tasks SET title = 'migrate-check-updated'
WHERE title = 'migrate-check'
RETURNING updated_at IS NOT NULL AS has_updated;
ROLLBACK;
APP_SQL
psql "$APP_DSN" -Atc \
  "select indexname from pg_indexes where tablename = 'tasks' order by 1;"
unset PGPASSWORD
