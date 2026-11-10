#!/usr/bin/env bash
set -euo pipefail
set -a; . /etc/cdb/secrets.env; set +a

DUMP=/home/azureuser/studydb-lab.dump
q() { docker exec cdb-study psql -U postgres -d "$1" "$@"; }

echo "=== DUMP (custom format, whole DB, no -t) ==="
start=$(date +%s%N)
docker exec cdb-study pg_dump -Fc -U postgres -d studydb > "$DUMP"
end=$(date +%s%N)
echo "dump_ms=$(( (end - start) / 1000000 ))"
ls -l "$DUMP"
file -b "$DUMP"

echo "=== RESTORE INTO studydb_restore ==="
docker exec cdb-study psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS studydb_restore"
docker exec cdb-study psql -U postgres -d postgres -c "CREATE DATABASE studydb_restore"
start=$(date +%s%N)
docker exec -i cdb-study pg_restore --exit-on-error -U postgres -d studydb_restore < "$DUMP"
rc=$?
end=$(date +%s%N)
echo "restore_ms=$(( (end - start) / 1000000 ))"
echo "restore_exit=$rc"

echo "=== COMPARE counts (studydb vs studydb_restore) ==="
echo "studydb:         users=$(q studydb -tAc 'SELECT count(*) FROM users') tasks=$(q studydb -tAc 'SELECT count(*) FROM tasks')"
echo "studydb_restore: users=$(q studydb_restore -tAc 'SELECT count(*) FROM users') tasks=$(q studydb_restore -tAc 'SELECT count(*) FROM tasks')"

echo "=== COMPARE content checksums ==="
echo "studydb         users=$(q studydb -tAc "SELECT md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users")"
echo "studydb_restore users=$(q studydb_restore -tAc "SELECT md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users")"
echo "studydb         tasks=$(q studydb -tAc "SELECT md5(string_agg(id||'|'||user_id||'|'||title||'|'||status, ',' ORDER BY id)) FROM tasks")"
echo "studydb_restore tasks=$(q studydb_restore -tAc "SELECT md5(string_agg(id||'|'||user_id||'|'||title||'|'||status, ',' ORDER BY id)) FROM tasks")"

echo "=== COMPARE index/constraint objects ==="
echo "studydb         indexes=$(q studydb -tAc "SELECT string_agg(tablename||':'||indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE schemaname='public'")"
echo "studydb_restore indexes=$(q studydb_restore -tAc "SELECT string_agg(tablename||':'||indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE schemaname='public'")"
echo "studydb         checks=$(q studydb -tAc "SELECT string_agg(conname||'='||contype, ',' ORDER BY conname) FROM pg_constraint WHERE conrelid IN ('users'::regclass,'tasks'::regclass)")"
echo "studydb_restore checks=$(q studydb_restore -tAc "SELECT string_agg(conname||'='||contype, ',' ORDER BY conname) FROM pg_constraint WHERE conrelid IN ('users'::regclass,'tasks'::regclass)")"

echo "=== FULL CONTENT of restored DB ==="
q studydb_restore -c "SELECT * FROM users ORDER BY id"
q studydb_restore -c "SELECT id, user_id, title, status FROM tasks ORDER BY id"
