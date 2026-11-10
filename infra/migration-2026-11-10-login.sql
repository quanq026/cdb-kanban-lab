-- Migration GĐ C (login): thêm hash mật khẩu cho user.
-- Chạy giống hệt trên local (docker cdb-study) và Neon (studydb).
BEGIN;

ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash text;

COMMENT ON COLUMN users.password_hash IS 'scrypt (werkzeug) - NULL = chua dat mat khau';

COMMIT;
