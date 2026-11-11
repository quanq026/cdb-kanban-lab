-- Migration GĐ C (schema): thứ tự thủ công + mốc thời gian cho tasks.
-- Chạy giống hệt trên Postgres local và Neon (studydb).
-- Additive + idempotent: app cũ vẫn chạy được trong lúc migrate.
BEGIN;

ALTER TABLE tasks ADD COLUMN IF NOT EXISTS position   integer;
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS created_at timestamptz;
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS updated_at timestamptz;

-- Backfill thứ tự theo id hiện có trong từng cột (0-based, trùng quy ước app).
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

-- Không có mốc tạo thật cho dữ liệu cũ: dùng thời điểm migrate.
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

-- updated_at do DB đảm bảo, không phụ thuộc mọi đường ghi của app.
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
