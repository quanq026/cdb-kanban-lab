#!/usr/bin/env bash
# Restore the newest dump from the bucket into a scratch database and verify it.
#
# Required env: NEON_BACKUP_DSN, RESTORE_TEST_DSN, R2_ENDPOINT, R2_BUCKET,
#               R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY.
# Optional env: BACKUP_PREFIX (default cdb).
#
# RESTORE_TEST_DSN must point at a throwaway Neon branch/database owned by a
# role that can create/drop objects. The script refuses to run when the test
# DSN matches the production DSN, or shares its host, or shares its database
# name (a Neon branch normally reuses the production database name, so create a
# dedicated database such as restoretest inside the branch).
set -euo pipefail

need() {
  local name=$1
  if [ -z "${!name:-}" ]; then
    echo "missing env: $name" >&2
    exit 2
  fi
}

need NEON_BACKUP_DSN
need RESTORE_TEST_DSN
need R2_ENDPOINT
need R2_BUCKET
need R2_ACCESS_KEY_ID
need R2_SECRET_ACCESS_KEY

# postgresql://[user[:pass]@][host][:port][/dbname][?params]
dsn_host() {
  local rest=${1#*://}
  rest=${rest##*@}
  rest=${rest%%/*}
  rest=${rest%%\?*}
  rest=${rest%:*}
  printf '%s' "$rest" | tr '[:upper:]' '[:lower:]'
}

dsn_db() {
  local rest=${1#*://}
  rest=${rest##*@}
  if [ "$rest" = "${rest#*/}" ]; then
    printf ''
    return 0
  fi
  rest=${rest#*/}
  rest=${rest%%\?*}
  printf '%s' "$rest"
}

refuse() {
  echo "$1" >&2
  exit 2
}

if [ "$RESTORE_TEST_DSN" = "$NEON_BACKUP_DSN" ]; then
  refuse "RESTORE_TEST_DSN must not be the production database"
fi

PROD_HOST="$(dsn_host "$NEON_BACKUP_DSN")"
TEST_HOST="$(dsn_host "$RESTORE_TEST_DSN")"
PROD_DB="$(dsn_db "$NEON_BACKUP_DSN")"
TEST_DB="$(dsn_db "$RESTORE_TEST_DSN")"

if [ -n "$PROD_HOST" ] && [ "$PROD_HOST" = "$TEST_HOST" ]; then
  refuse "RESTORE_TEST_DSN uses the production host ($PROD_HOST)"
fi
if [ -n "$PROD_DB" ] && [ "$PROD_DB" = "$TEST_DB" ]; then
  refuse "RESTORE_TEST_DSN uses the production database name ($PROD_DB); use a dedicated database"
fi

PREFIX="${BACKUP_PREFIX:-cdb}"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
AWS=(aws --endpoint-url "$R2_ENDPOINT")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LAST_DUMP="$(
  "${AWS[@]}" s3 ls "s3://$R2_BUCKET/$PREFIX/" |
    awk '{print $4}' |
    grep -E '^cdb-.*\.dump$' |
    sort -r |
    head -n1
)"
if [ -z "$LAST_DUMP" ]; then
  echo "no dump found under s3://$R2_BUCKET/$PREFIX/" >&2
  exit 1
fi
echo "restoring=$LAST_DUMP"

DUMP_FILE="$WORK/$LAST_DUMP"
MANIFEST_FILE="$WORK/${LAST_DUMP%.dump}.json"
"${AWS[@]}" s3 cp "s3://$R2_BUCKET/$PREFIX/$LAST_DUMP" "$DUMP_FILE" --only-show-errors
"${AWS[@]}" s3 cp "s3://$R2_BUCKET/$PREFIX/${LAST_DUMP%.dump}.json" "$MANIFEST_FILE" \
  --only-show-errors 2>/dev/null || rm -f "$MANIFEST_FILE"

pg_restore --exit-on-error --no-owner --no-privileges --clean --if-exists \
  -d "$RESTORE_TEST_DSN" "$DUMP_FILE"

q() { psql "$RESTORE_TEST_DSN" -tAc "$1"; }

FAILED=0
check() {
  local label=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then
    echo "PASS $label: $got"
  else
    echo "FAIL $label: want=$want got=$got" >&2
    FAILED=1
  fi
}

USERS="$(q 'SELECT count(*) FROM users')"
TASKS="$(q 'SELECT count(*) FROM tasks')"

if [ -s "$MANIFEST_FILE" ] && command -v jq >/dev/null; then
  check "users (manifest)" "$(jq -r '.users' "$MANIFEST_FILE")" "$USERS"
  check "tasks (manifest)" "$(jq -r '.tasks' "$MANIFEST_FILE")" "$TASKS"
else
  echo "no manifest/jq; checking tables are non-empty only"
  if [ "$USERS" -gt 0 ]; then
    echo "PASS users > 0: $USERS"
  else
    echo "FAIL users is 0" >&2
    FAILED=1
  fi
  if [ "$TASKS" -gt 0 ]; then
    echo "PASS tasks > 0: $TASKS"
  else
    echo "FAIL tasks is 0" >&2
    FAILED=1
  fi
fi

check "index idx_tasks_user_status_position" t \
  "$(q "SELECT to_regclass('public.idx_tasks_user_status_position') IS NOT NULL")"
check "trigger trg_tasks_updated_at" 1 \
  "$(q "SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_tasks_updated_at' AND NOT tgisinternal")"

if [ "$FAILED" -ne 0 ]; then
  echo "restore test FAILED" >&2
  exit 1
fi
echo "restore test PASSED"
