#!/usr/bin/env bash
# Nightly logical backup of the Neon database to an S3-compatible bucket.
#
# Required env: NEON_BACKUP_DSN, R2_ENDPOINT, R2_BUCKET,
#               R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY.
# Optional env: BACKUP_PREFIX (default cdb), BACKUP_KEEP (default 14 dumps).
#
# Retention: keep the newest BACKUP_KEEP dumps (daily). 14 dumps covers two
# weeks, so a corrupted backup found within a week still has older copies; a
# separate weekly tier is not worth the extra bookkeeping at this scale.
set -euo pipefail

need() {
  local name=$1
  if [ -z "${!name:-}" ]; then
    echo "missing env: $name" >&2
    exit 2
  fi
}

need NEON_BACKUP_DSN
need R2_ENDPOINT
need R2_BUCKET
need R2_ACCESS_KEY_ID
need R2_SECRET_ACCESS_KEY

PREFIX="${BACKUP_PREFIX:-cdb}"
KEEP="${BACKUP_KEEP:-14}"
if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
  echo "BACKUP_KEEP must be a positive integer" >&2
  exit 2
fi

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
AWS=(aws --endpoint-url "$R2_ENDPOINT")

STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DUMP="$WORK/cdb-$STAMP.dump"
MANIFEST="$WORK/cdb-$STAMP.json"

echo "dump=cdb-$STAMP.dump"
pg_dump -Fc --no-owner -d "$NEON_BACKUP_DSN" -f "$DUMP"
if [ ! -s "$DUMP" ]; then
  echo "dump is empty" >&2
  exit 1
fi
pg_restore -l "$DUMP" >/dev/null

USERS="$(psql "$NEON_BACKUP_DSN" -tAc 'SELECT count(*) FROM users')"
TASKS="$(psql "$NEON_BACKUP_DSN" -tAc 'SELECT count(*) FROM tasks')"
cat >"$MANIFEST" <<JSON
{"dump":"cdb-$STAMP.dump","created_at":"$STAMP","users":$USERS,"tasks":$TASKS}
JSON

"${AWS[@]}" s3 cp "$DUMP" "s3://$R2_BUCKET/$PREFIX/cdb-$STAMP.dump" --only-show-errors
"${AWS[@]}" s3 cp "$MANIFEST" "s3://$R2_BUCKET/$PREFIX/cdb-$STAMP.json" --only-show-errors
echo "uploaded=s3://$R2_BUCKET/$PREFIX/cdb-$STAMP.dump users=$USERS tasks=$TASKS"

mapfile -t DUMPS < <(
  "${AWS[@]}" s3 ls "s3://$R2_BUCKET/$PREFIX/" |
    awk '{print $4}' |
    grep -E '^cdb-.*\.dump$' |
    sort -r
)
if [ "${#DUMPS[@]}" -gt "$KEEP" ]; then
  for OLD in "${DUMPS[@]:KEEP}"; do
    "${AWS[@]}" s3 rm "s3://$R2_BUCKET/$PREFIX/$OLD" --only-show-errors
    "${AWS[@]}" s3 rm "s3://$R2_BUCKET/$PREFIX/${OLD%.dump}.json" --only-show-errors
    echo "pruned=$OLD"
  done
fi
