#!/usr/bin/env bash
set -uo pipefail
set -a; . /etc/cdb/secrets.env; set +a

OUT=/tmp/evidence
SQL=/tmp/evidence/sql
mkdir -p "$OUT" "$SQL"
STAMP=$(date -Is)
export PGPASSWORD="$PG_SUPER_PASSWORD"
PSQL="psql -h 127.0.0.1 -p 55432 -U postgres -d studydb -q"

run_file() {
  local f="$1"
  printf '```sql\n'
  cat "$f"
  printf '\n```\n\n```text\n'
  $PSQL -f "$f" 2>&1 || true
  printf '```\n\n'
}

query() {
  $PSQL -tAc "$1" 2>&1
}

cat > "$SQL/c1.sql" <<'SQL'
INSERT INTO users (email) VALUES ('an@example.test');
SQL
cat > "$SQL/c2.sql" <<'SQL'
INSERT INTO tasks (user_id, title) VALUES (1, '   ');
SQL
cat > "$SQL/c3.sql" <<'SQL'
INSERT INTO tasks (user_id, title) VALUES (1, '');
SQL
cat > "$SQL/c4.sql" <<'SQL'
INSERT INTO tasks (user_id, title, status) VALUES (1, 'hop le', 'blocked');
SQL
cat > "$SQL/c5.sql" <<'SQL'
UPDATE tasks SET status = 'archived' WHERE id = 1;
SQL
cat > "$SQL/c6.sql" <<'SQL'
INSERT INTO tasks (user_id, title) VALUES (999999, 'mo coi');
SQL
cat > "$SQL/tx.sql" <<'SQL'
SELECT id, user_id, title, status FROM tasks WHERE id = 2;
BEGIN;
UPDATE tasks SET status = 'done' WHERE id = 2;
SELECT id, title, status FROM tasks WHERE id = 2;
ROLLBACK;
SELECT id, title, status FROM tasks WHERE id = 2;
SQL
cat > "$SQL/ix_drop.sql" <<'SQL'
DROP INDEX IF EXISTS idx_tasks_user_status;
SQL
cat > "$SQL/ix_explain.sql" <<'SQL'
EXPLAIN (ANALYZE, BUFFERS) SELECT id, title, status FROM tasks WHERE user_id = 1 AND status = 'todo';
SQL
cat > "$SQL/ix_create.sql" <<'SQL'
CREATE INDEX idx_tasks_user_status ON tasks (user_id, status);
SQL
cat > "$SQL/ix_force.sql" <<'SQL'
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT id, title, status FROM tasks WHERE user_id = 1 AND status = 'todo';
RESET enable_seqscan;
SQL

{
  echo "# Constraints - PostgreSQL 17 (container local)"
  echo
  echo "- Thoi diem chay: \`$STAMP\`"
  echo "- Ket noi: \`psql -h 127.0.0.1 -p 55432 -U postgres -d studydb\`"
  echo
  echo "## Dinh nghia rang buoc"
  echo
  printf '```text\n'
  $PSQL -c '\d users' 2>&1
  $PSQL -c '\d tasks' 2>&1
  printf '```\n\n'
  echo "## 1. UNIQUE email (chen trung)"
  echo
  run_file "$SQL/c1.sql"
  echo "## 2. CHECK title khong rong (toan dau cach / rong)"
  echo
  run_file "$SQL/c2.sql"
  run_file "$SQL/c3.sql"
  echo "## 3. CHECK status hop le"
  echo
  run_file "$SQL/c4.sql"
  run_file "$SQL/c5.sql"
  echo "## 4. FK user_id phai ton tai"
  echo
  run_file "$SQL/c6.sql"
  echo "## Ket luan"
  echo
  echo "Ca 4 rang buoc deu chan du lieu xau o tang database. Ma loi: \`23505\` (unique), \`23514\` (check), \`23503\` (foreign key)."
} > "$OUT/constraints.md"

{
  echo "# Transaction - BEGIN / UPDATE / SELECT / ROLLBACK"
  echo
  echo "- Thoi diem chay: \`$STAMP\`"
  echo
  echo "## Trang thai goc cua bang tasks"
  echo
  printf '```text\n'
  query "SELECT id, user_id, title, status FROM tasks ORDER BY id"
  printf '```\n\n'
  echo "## Chay transaction: UPDATE trong BEGIN, SELECT, ROLLBACK, SELECT lai"
  echo
  run_file "$SQL/tx.sql"
  echo "## Trang thai sau khi transaction ket thuc"
  echo
  printf '```text\n'
  query "SELECT id, user_id, title, status FROM tasks ORDER BY id"
  printf '```\n\n'
  echo "## Giai thich"
  echo
  echo "Ben trong transaction, \`UPDATE\` thay doi duoc nhin thay. Sau \`ROLLBACK\`, dong id=2 quay lai gia tri cu \`doing\`; khong co thay doi nao duoc ghi xuong dia."
} > "$OUT/transaction.md"

{
  echo "# Index - truy van loc (user_id, status)"
  echo
  echo "- Thoi diem chay: \`$STAMP\`"
  echo "- Bang tasks hien co $(query 'SELECT count(*) FROM tasks') dong (du lieu mau rat nho)."
  echo
  echo "## Truoc khi co index"
  echo
  run_file "$SQL/ix_drop.sql"
  run_file "$SQL/ix_explain.sql"
  echo "## Tao index"
  echo
  run_file "$SQL/ix_create.sql"
  echo
  echo "## Sau khi co index"
  echo
  run_file "$SQL/ix_explain.sql"
  echo "## Ep planner dung index (enable_seqscan=off)"
  echo
  run_file "$SQL/ix_force.sql"
  echo "## Ghi chu"
  echo
  echo "Voi bang nho, planner chon **Seq Scan** ca truoc va sau khi tao index vi chi phi doc toan bang thap hon. Khi tat seqscan, planner dung index \`idx_tasks_user_status\` -> index hop le va se duoc chon khi bang lon dan."
} > "$OUT/index.md"

BEFORE_USERS=$(query "SELECT count(*) FROM users")
BEFORE_TASKS=$(query "SELECT count(*) FROM tasks")
BEFORE_MD5=$(query "SELECT md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users")
BEFORE_TMD5=$(query "SELECT md5(string_agg(id||'|'||user_id||'|'||title||'|'||status, ',' ORDER BY id)) FROM tasks")

{
  echo "# Persistence - xoa container, giu volume, tao lai"
  echo
  echo "- Thoi diem chay: \`$STAMP\`"
  echo
  echo "## Du lieu TRUOC khi xoa container"
  echo
  echo '```text'
  echo "users=$BEFORE_USERS tasks=$BEFORE_TASKS"
  echo "md5(users)=$BEFORE_MD5"
  echo "md5(tasks)=$BEFORE_TMD5"
  echo '```'
  echo
  echo "## Xoa container (volume cdb-study-data duoc giu)"
  echo
  printf '```bash\ndocker rm -f cdb-study\ndocker volume ls --filter name=cdb-study-data\n```\n\n'
  printf '```text\n'
  docker rm -f cdb-study 2>&1
  docker volume ls --filter name=cdb-study-data 2>&1
  printf '```\n\n'
  echo "## Tao lai container tren cung volume"
  echo
  printf '```bash\n'
  echo 'docker run -d --name cdb-study --restart unless-stopped \'
  echo '  -e POSTGRES_PASSWORD=$PG_SUPER_PASSWORD (lay tu /etc/cdb/secrets.env) \'
  echo '  -e POSTGRES_DB=studydb -p 127.0.0.1:55432:5432 \'
  echo '  -v cdb-study-data:/var/lib/postgresql/data postgres:17'
  printf '```\n\n'
  docker run -d --name cdb-study --restart unless-stopped \
    -e POSTGRES_PASSWORD="$PG_SUPER_PASSWORD" -e POSTGRES_DB=studydb \
    -p 127.0.0.1:55432:5432 -v cdb-study-data:/var/lib/postgresql/data postgres:17 >/dev/null 2>&1
  for i in $(seq 1 60); do
    docker exec cdb-study pg_isready -U postgres -d studydb >/dev/null 2>&1 && break
    sleep 2
  done
  printf '```text\n'
  docker exec cdb-study pg_isready -U postgres -d studydb 2>&1
  printf '```\n\n'
  echo "## Du lieu SAU khi tao lai"
  echo
  printf '```text\n'
  echo "users=$(query 'SELECT count(*) FROM users') tasks=$(query 'SELECT count(*) FROM tasks')"
  echo "md5(users)=$(query "SELECT md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users")"
  echo "md5(tasks)=$(query "SELECT md5(string_agg(id||'|'||user_id||'|'||title||'|'||status, ',' ORDER BY id)) FROM tasks")"
  printf '```\n\n'
  echo "## Role app_user van con"
  echo
  printf '```text\n'
  query "SELECT rolname, rolcanlogin, rolsuper FROM pg_roles WHERE rolname='app_user'"
  printf '```\n\n'
  echo "## app_user van dang nhap duoc"
  echo
  printf '```bash\nPGPASSWORD=<local app password> psql "host=127.0.0.1 port=55432 dbname=studydb user=app_user sslmode=disable" -c "SELECT current_user"\n```\n\n'
  printf '```text\n'
  PGPASSWORD="$LOCAL_APP_PASSWORD" psql "host=127.0.0.1 port=55432 dbname=studydb user=app_user sslmode=disable" -tAc "SELECT current_user, count(*) FROM tasks GROUP BY current_user" 2>&1
  printf '```\n\n'
  echo "## Ket luan"
  echo
  echo "Du lieu, role va mat khau cua \`app_user\` nam trong volume \`cdb-study-data\`, nen xoa/tao lai container khong mat gi. Gioi han: neu volume hoac VM bi xoa thi mat (xem backup-restore.md)."
} > "$OUT/persistence.md"

DUMP=/home/azureuser/studydb-lab.dump
start=$(date +%s%N)
docker exec cdb-study pg_dump -Fc -U postgres -d studydb > "$DUMP"
end=$(date +%s%N)
DUMP_MS=$(( (end - start) / 1000000 ))
DUMP_SIZE=$(stat -c %s "$DUMP")

docker exec cdb-study psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS studydb_restore" >/dev/null
docker exec cdb-study psql -U postgres -d postgres -c "CREATE DATABASE studydb_restore" >/dev/null
start=$(date +%s%N)
docker exec -i cdb-study pg_restore --exit-on-error -U postgres -d studydb_restore < "$DUMP"
RESTORE_RC=$?
end=$(date +%s%N)
RESTORE_MS=$(( (end - start) / 1000000 ))

export PGPASSWORD="$PG_SUPER_PASSWORD"
q() { psql -h 127.0.0.1 -p 55432 -U postgres -d "$1" -tAc "$2"; }

{
  echo "# Backup & Restore - pg_dump -Fc, pg_restore --exit-on-error"
  echo
  echo "- Thoi diem chay: \`$STAMP\`"
  echo "- Server: PostgreSQL 17.11 trong container \`cdb-study\`"
  echo
  echo "## Dump (toan bo database, khong dung -t)"
  echo
  echo '```bash'
  echo "docker exec cdb-study pg_dump -Fc -U postgres -d studydb > $DUMP"
  echo '```'
  echo
  echo '```text'
  ls -l "$DUMP"
  file -b "$DUMP"
  echo "dump_ms=$DUMP_MS  size_bytes=$DUMP_SIZE"
  echo '```'
  echo
  echo "## Restore sang database moi"
  echo
  echo '```bash'
  echo 'docker exec cdb-study psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS studydb_restore"'
  echo 'docker exec cdb-study psql -U postgres -d postgres -c "CREATE DATABASE studydb_restore"'
  echo "docker exec -i cdb-study pg_restore --exit-on-error -U postgres -d studydb_restore < $DUMP"
  echo '```'
  echo
  echo '```text'
  echo "restore_exit_code=$RESTORE_RC"
  echo "restore_ms=$RESTORE_MS"
  echo '```'
  echo
  echo "## Doi chieu so dong"
  echo
  echo '```text'
  echo "studydb         users=$(q studydb 'SELECT count(*) FROM users') tasks=$(q studydb 'SELECT count(*) FROM tasks')"
  echo "studydb_restore users=$(q studydb_restore 'SELECT count(*) FROM users') tasks=$(q studydb_restore 'SELECT count(*) FROM tasks')"
  echo '```'
  echo
  echo "## Doi chieu noi dung (md5 toan bo dong, sap theo id)"
  echo
  echo '```text'
  echo "studydb         users=$(q studydb "SELECT md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users")"
  echo "studydb_restore users=$(q studydb_restore "SELECT md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users")"
  echo "studydb         tasks=$(q studydb "SELECT md5(string_agg(id||'|'||user_id||'|'||title||'|'||status, ',' ORDER BY id)) FROM tasks")"
  echo "studydb_restore tasks=$(q studydb_restore "SELECT md5(string_agg(id||'|'||user_id||'|'||title||'|'||status, ',' ORDER BY id)) FROM tasks")"
  echo '```'
  echo
  echo "## Doi chieu object (index)"
  echo
  echo '```text'
  echo "studydb         : $(q studydb "SELECT string_agg(tablename||':'||indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE schemaname='public'")"
  echo "studydb_restore : $(q studydb_restore "SELECT string_agg(tablename||':'||indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE schemaname='public'")"
  echo '```'
  echo
  echo "## Noi dung database restore"
  echo
  printf '```bash\n'
  echo 'docker exec cdb-study psql -U postgres -d studydb_restore -c "SELECT * FROM users ORDER BY id"'
  echo 'docker exec cdb-study psql -U postgres -d studydb_restore -c "SELECT id, user_id, title, status FROM tasks ORDER BY id"'
  printf '```\n\n```text\n'
  docker exec cdb-study psql -U postgres -d studydb_restore -c "SELECT * FROM users ORDER BY id" 2>&1
  docker exec cdb-study psql -U postgres -d studydb_restore -c "SELECT id, user_id, title, status FROM tasks ORDER BY id" 2>&1
  printf '```\n\n'
  echo "## Gioi han (chua kiem chung)"
  echo
  echo "- Chua test mat toan bo may (VM/volume/region); hien chi test mat container."
  echo "- Chua test PITR (WAL archiving) vi container khong bat archive_mode."
  echo "- Chua test failover/replica; day la single instance."
  echo "- Dump nam tren cung VM voi database: neu VM mat thi mat ca dump. Production can day dump sang object storage khac."
  echo "- Chua do RTO/RPO that; so ms o tren chi la thoi gian restore 6 KB du lieu mau."
} > "$OUT/backup-restore.md"

chmod -R a+r "$OUT"
ls -l "$OUT"
