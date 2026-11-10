# Monitoring - pg_stat_activity khi app dang chay

- Thoi diem chay: `2026-11-09T09:49:20+00:00`
- App: gunicorn 2 worker + psycopg_pool (min 1, max 5), backend Neon

## Tong hop theo database va state (Neon)

```bash
psql "host=<neon> dbname=studydb user=app_user sslmode=verify-full sslrootcert=system" \
  -c "SELECT datname, state, count(*) FROM pg_stat_activity GROUP BY datname, state ORDER BY datname, state"
```

```text
 datname  | state  | count 
----------+--------+-------
 postgres |        |     4
 studydb  | active |     1
 studydb  | idle   |     3
          |        |     6
(4 rows)

```

## Chi tiet backend cua app

```text
 pid  | usename  | application_name | client_addr | state  | started  |                            query                             
------+----------+------------------+-------------+--------+----------+--------------------------------------------------------------
  875 | app_user | psql             | ::1         | idle   | 09:42:36 | SELECT count(*) AS tasks FROM tasks
 1975 | app_user | cdb-kanban       | 10.9.12.116 | idle   | 09:49:23 | COMMIT
 1976 | app_user | cdb-kanban       | 10.9.58.101 | idle   | 09:49:23 | 
 1995 | app_user | psql             | 10.9.58.101 | active | 09:49:29 | SELECT pid, usename, application_name, client_addr, state, b
(4 rows)

```

## So ket noi theo application_name

```text
 application_name | usename  | count 
------------------+----------+-------
 cdb-kanban       | app_user |     2
 psql             | app_user |     2
(2 rows)

```

## Doi chieu: pg_stat_activity tren container local

```text
 datname | state  | count 
---------+--------+-------
 studydb | active |     1
         |        |     5
(2 rows)

```

## Nhan xet

- App chi mo toi da 5 ket noi (pool max_size=5) va giu 1 ket noi warm; cac ket noi `idle` la cua gunicorn worker.
- Tren Neon, so ket noi tinh vao gioi han cua endpoint (0.25 CU); voi 2 worker thi 2-3 ket noi la binh thuong.
- Khong thay ket noi nao tu ngoai Internet vao 5432 cua VM: PostgreSQL local chi listen 127.0.0.1:55432.
