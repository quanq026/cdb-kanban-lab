#!/usr/bin/env bash
set -euo pipefail

# Don sach tai khoan do test/evidence tao ra. Khong dung vao tai khoan that.
#   test-%@example.test   -> app-tests.sh (da xoa khoi repo)
#   shot+%@local.test     -> ui-shots.mjs (da xoa khoi repo)
#   verify+%@local.test   -> kiem tra tay tren trinh duyet
#
# Chay: sudo bash /tmp/step.sh

set -a
. /etc/cdb/app.env
set +a
export PGPASSWORD="$DB_PASSWORD"
DSN="host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=verify-full sslrootcert=$DB_SSLROOTCERT"

FILTER="email LIKE 'test-%@example.test' OR email LIKE 'shot+%@local.test' OR email LIKE 'verify+%@local.test'"

echo "== truoc khi xoa =="
psql "$DSN" -At -c "SELECT 'test_users=' || count(*) FROM users WHERE $FILTER;"
psql "$DSN" -At -c "SELECT 'all_users=' || count(*) FROM users;"
psql "$DSN" -At -c "SELECT 'all_tasks=' || count(*) FROM tasks;"

psql "$DSN" -q -v ON_ERROR_STOP=1 -c \
  "DELETE FROM tasks WHERE user_id IN (SELECT id FROM users WHERE $FILTER);"
psql "$DSN" -q -v ON_ERROR_STOP=1 -c \
  "DELETE FROM users WHERE $FILTER;"

echo "== sau khi xoa =="
psql "$DSN" -At -c "SELECT 'test_users=' || count(*) FROM users WHERE $FILTER;"
psql "$DSN" -At -c "SELECT 'all_users=' || count(*) FROM users;"
psql "$DSN" -At -c "SELECT 'all_tasks=' || count(*) FROM tasks;"
unset PGPASSWORD
echo "purge_test_accounts=done"
