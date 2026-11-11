-- Rollback migration GĐ C (schema): bỏ position + timestamps, trả index cũ.
-- Chỉ đụng bảng tasks; users/password_hash giữ nguyên.
BEGIN;

DROP TRIGGER IF EXISTS trg_tasks_updated_at ON tasks;
DROP FUNCTION IF EXISTS tasks_touch_updated_at();

DROP INDEX IF EXISTS idx_tasks_user_status_position;
CREATE INDEX IF NOT EXISTS idx_tasks_user_status ON tasks (user_id, status);

ALTER TABLE tasks DROP COLUMN IF EXISTS updated_at;
ALTER TABLE tasks DROP COLUMN IF EXISTS created_at;
ALTER TABLE tasks DROP COLUMN IF EXISTS position;

COMMIT;
