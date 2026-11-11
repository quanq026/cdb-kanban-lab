#!/usr/bin/env bash
set -euo pipefail

: "${NEON_BACKUP_DSN:?missing NEON_BACKUP_DSN}"
: "${R2_ENDPOINT:?missing R2_ENDPOINT}"
: "${R2_BUCKET:?missing R2_BUCKET}"

STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
FILE="/tmp/cdb-${STAMP}.dump"

docker run --rm postgres:17 pg_dump -Fc --no-owner "$NEON_BACKUP_DSN" > "$FILE"
[ -s "$FILE" ] || { echo "dump file is empty" >&2; exit 1; }

aws --endpoint-url "$R2_ENDPOINT" s3 cp "$FILE" "s3://${R2_BUCKET}/cdb/cdb-${STAMP}.dump"
rm -f "$FILE"
