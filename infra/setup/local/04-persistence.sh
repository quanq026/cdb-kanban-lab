#!/usr/bin/env bash
set -euo pipefail
set -a; . /etc/cdb/secrets.env; set +a

echo "=== BEFORE: data + roles ==="
docker exec cdb-study psql -U postgres -d studydb -c "SELECT count(*) AS users FROM users" -c "SELECT count(*) AS tasks FROM tasks"
docker exec cdb-study psql -U postgres -d studydb -c "SELECT rolname, rolcanlogin, rolsuper FROM pg_roles WHERE rolname='app_user'"
docker exec cdb-study psql -U postgres -d studydb -Atc "SELECT md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users"

echo "=== REMOVE CONTAINER (volume kept) ==="
docker rm -f cdb-study
docker volume ls --filter name=cdb-study-data --format '{{.Name}} {{.Driver}}'

echo "=== RECREATE CONTAINER ON SAME VOLUME ==="
docker run -d --name cdb-study --restart unless-stopped \
  -e POSTGRES_PASSWORD="$PG_SUPER_PASSWORD" \
  -e POSTGRES_DB=studydb \
  -p 127.0.0.1:55432:5432 \
  -v cdb-study-data:/var/lib/postgresql/data \
  postgres:17 >/dev/null

for i in $(seq 1 60); do
  if docker exec cdb-study pg_isready -U postgres -d studydb >/dev/null 2>&1; then break; fi
  sleep 2
done

echo "=== AFTER: data + roles ==="
docker exec cdb-study psql -U postgres -d studydb -c "SELECT count(*) AS users FROM users" -c "SELECT count(*) AS tasks FROM tasks"
docker exec cdb-study psql -U postgres -d studydb -c "SELECT rolname, rolcanlogin, rolsuper FROM pg_roles WHERE rolname='app_user'"
docker exec cdb-study psql -U postgres -d studydb -Atc "SELECT md5(string_agg(id||'|'||email, ',' ORDER BY id)) FROM users"

echo "=== app_user still able to log in after recreate ==="
PGPASSWORD="$LOCAL_APP_PASSWORD" psql "host=127.0.0.1 port=55432 dbname=studydb user=app_user sslmode=disable" \
  -c "SELECT current_user, (SELECT count(*) FROM tasks) AS tasks"
