# Backup & Restore - pg_dump -Fc, pg_restore --exit-on-error

- Thoi diem chay: `2026-11-09T09:48:06+00:00`
- Server: PostgreSQL 17.11 trong container `cdb-study`

## Dump (toan bo database, khong dung -t)

```bash
docker exec cdb-study pg_dump -Fc -U postgres -d studydb > /home/azureuser/studydb-lab.dump
```

```text
-rw-r--r-- 1 root root 6101 Nov  9 09:48 /home/azureuser/studydb-lab.dump
PostgreSQL custom database dump - v1.16-0
dump_ms=125  size_bytes=6101
```

## Restore sang database moi

```bash
docker exec cdb-study psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS studydb_restore"
docker exec cdb-study psql -U postgres -d postgres -c "CREATE DATABASE studydb_restore"
docker exec -i cdb-study pg_restore --exit-on-error -U postgres -d studydb_restore < /home/azureuser/studydb-lab.dump
```

```text
restore_exit_code=0
restore_ms=228
```

## Doi chieu so dong

```text
studydb         users=2 tasks=5
studydb_restore users=2 tasks=5
```

## Doi chieu noi dung (md5 toan bo dong, sap theo id)

```text
studydb         users=d2f198dbac7c784edb5dace18d85af21
studydb_restore users=d2f198dbac7c784edb5dace18d85af21
studydb         tasks=aaaaa7a6658f216d9461a9bfe097eedf
studydb_restore tasks=aaaaa7a6658f216d9461a9bfe097eedf
```

## Doi chieu object (index)

```text
studydb         : tasks:idx_tasks_user_status,tasks:tasks_pkey,users:users_email_key,users:users_pkey
studydb_restore : tasks:idx_tasks_user_status,tasks:tasks_pkey,users:users_email_key,users:users_pkey
```

## Noi dung database restore

```bash
docker exec cdb-study psql -U postgres -d studydb_restore -c "SELECT * FROM users ORDER BY id"
docker exec cdb-study psql -U postgres -d studydb_restore -c "SELECT id, user_id, title, status FROM tasks ORDER BY id"
```

```text
 id |       email       
----+-------------------
  1 | an@example.test
  2 | binh@example.test
(2 rows)

 id | user_id |          title          | status 
----+---------+-------------------------+--------
  1 |       1 | Soạn đề cương báo cáo   | todo
  2 |       1 | Nộp bài tập tuần 3      | doing
  3 |       1 | Cài PostgreSQL 17       | done
  4 |       2 | Chuẩn bị slide demo     | todo
  5 |       2 | Kiểm thử backup/restore | doing
(5 rows)

```

## Gioi han (chua kiem chung)

- Chua test mat toan bo may (VM/volume/region); hien chi test mat container.
- Chua test PITR (WAL archiving) vi container khong bat archive_mode.
- Chua test failover/replica; day la single instance.
- Dump nam tren cung VM voi database: neu VM mat thi mat ca dump. Production can day dump sang object storage khac.
- Chua do RTO/RPO that; so ms o tren chi la thoi gian restore 6 KB du lieu mau.
