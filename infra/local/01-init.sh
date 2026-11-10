#!/usr/bin/env bash
set -euo pipefail
set -a; . /etc/cdb/secrets.env; set +a

docker volume create cdb-study-data >/dev/null
docker rm -f cdb-study >/dev/null 2>&1 || true

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

docker exec -i cdb-study psql -v ON_ERROR_STOP=1 -U postgres -d studydb -f - < /opt/cdb/schema.sql

docker exec cdb-study psql -U postgres -d studydb -Atc "SELECT version()"
docker exec cdb-study psql -U postgres -d studydb -c "SELECT count(*) AS users FROM users; SELECT count(*) AS tasks FROM tasks;"
