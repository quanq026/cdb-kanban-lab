#!/usr/bin/env bash
# Nightly logical backup of the Neon database to an S3-compatible bucket.
#
# Required env: NEON_BACKUP_DSN, R2_ENDPOINT, R2_BUCKET,
#               R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY.
# Optional env: BACKUP_PREFIX (default cdb), BACKUP_KEEP (default 14 dumps).
#
# NEON_BACKUP_DSN must use the direct (non-pooler) Neon endpoint: the dump and
# the row counts share an exported REPEATABLE READ snapshot, which needs a real
# session. Retention counts every dump in the bucket, manual dispatch included.
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
HOLDER=""
cleanup() {
  rm -rf "$WORK"
  if [ -n "$HOLDER" ]; then
    kill "$HOLDER" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Previous dump's manifest, read before the new objects land in the bucket.
list_dumps() {
  "${AWS[@]}" s3 ls "s3://$R2_BUCKET/$PREFIX/" >"$WORK/list.txt" || {
    echo "cannot list s3://$R2_BUCKET/$PREFIX/" >&2
    exit 1
  }
  awk '{print $4}' "$WORK/list.txt" | grep -E '^cdb-.*\.dump$' | sort -r \
    >"$WORK/dumps.txt" || true
}

PREV_USERS=""
list_dumps
mapfile -t BEFORE <"$WORK/dumps.txt"
if [ "${#BEFORE[@]}" -gt 0 ]; then
  PREV_JSON="$WORK/prev.json"
  if "${AWS[@]}" s3 cp "s3://$R2_BUCKET/$PREFIX/${BEFORE[0]%.dump}.json" "$PREV_JSON" \
    --only-show-errors 2>/dev/null; then
    PREV_USERS="$(sed -n 's/.*"users":\([0-9][0-9]*\).*/\1/p' "$PREV_JSON" | head -n1)"
  else
    echo "warn: previous manifest missing; skipping the drop check" >&2
  fi
fi

# Hold one REPEATABLE READ transaction open, export its snapshot, and use the
# same snapshot for pg_dump and the counts so the manifest matches the dump.
READY="$WORK/ready"
STOP="$WORK/stop"
export READY STOP
cat >"$WORK/hold.sql" <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ;
\o $WORK/snapshot.txt
SELECT pg_export_snapshot();
\o
\! touch "\$READY"
\! i=0; while [ ! -f "\$STOP" ] && [ "\$i" -lt 900 ]; do sleep 1; i=\$((i + 1)); done
COMMIT;
SQL

psql "$NEON_BACKUP_DSN" -v ON_ERROR_STOP=1 -q -f "$WORK/hold.sql" &
HOLDER=$!

for ((i = 0; i < 60; i++)); do
  [ -f "$READY" ] && break
  kill -0 "$HOLDER" 2>/dev/null || break
  sleep 1
done
if [ ! -f "$READY" ]; then
  echo "could not export a snapshot" >&2
  exit 1
fi
SNAP="$(tr -d '[:space:]' <"$WORK/snapshot.txt")"
if [ -z "$SNAP" ]; then
  echo "empty snapshot id" >&2
  exit 1
fi

DUMP="$WORK/cdb-$STAMP.dump"
MANIFEST="$WORK/cdb-$STAMP.json"
echo "dump=cdb-$STAMP.dump snapshot=$SNAP"

pg_dump -Fc --no-owner --snapshot="$SNAP" -d "$NEON_BACKUP_DSN" -f "$DUMP"
if [ ! -s "$DUMP" ]; then
  echo "dump is empty" >&2
  exit 1
fi
pg_restore -l "$DUMP" >/dev/null

mapfile -t COUNTS < <(
  psql "$NEON_BACKUP_DSN" -v ON_ERROR_STOP=1 -q -t -A <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ;
SET TRANSACTION SNAPSHOT '$SNAP';
SELECT count(*) FROM users;
SELECT count(*) FROM tasks;
COMMIT;
SQL
)
USERS="${COUNTS[0]:-}"
TASKS="${COUNTS[1]:-}"
if ! [[ "$USERS" =~ ^[0-9]+$ && "$TASKS" =~ ^[0-9]+$ ]]; then
  echo "could not read row counts from the snapshot" >&2
  exit 1
fi

touch "$STOP"
wait "$HOLDER" || true

cat >"$MANIFEST" <<JSON
{"dump":"cdb-$STAMP.dump","created_at":"$STAMP","users":$USERS,"tasks":$TASKS}
JSON

"${AWS[@]}" s3 cp "$DUMP" "s3://$R2_BUCKET/$PREFIX/cdb-$STAMP.dump" --only-show-errors
"${AWS[@]}" s3 cp "$MANIFEST" "s3://$R2_BUCKET/$PREFIX/cdb-$STAMP.json" --only-show-errors
echo "uploaded=s3://$R2_BUCKET/$PREFIX/cdb-$STAMP.dump users=$USERS tasks=$TASKS"

# Safety guard: keep the new dump, but never prune when the data looks wrong.
if [ "$USERS" -eq 0 ]; then
  echo "guard: dump has 0 users; dump kept, prune skipped" >&2
  exit 1
fi
if [ -n "$PREV_USERS" ] && [ "$USERS" -lt $((PREV_USERS / 2)) ]; then
  echo "guard: users dropped from $PREV_USERS to $USERS (>50%); dump kept, prune skipped" >&2
  exit 1
fi

list_dumps
mapfile -t DUMPS <"$WORK/dumps.txt"
if [ "${#DUMPS[@]}" -gt "$KEEP" ]; then
  for OLD in "${DUMPS[@]:KEEP}"; do
    "${AWS[@]}" s3 rm "s3://$R2_BUCKET/$PREFIX/$OLD" --only-show-errors
    "${AWS[@]}" s3 rm "s3://$R2_BUCKET/$PREFIX/${OLD%.dump}.json" --only-show-errors
    echo "pruned=$OLD"
  done
fi
