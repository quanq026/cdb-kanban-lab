# Evidence — Database & Cloud

Gồm Postgres local (GĐ 2), Neon (GĐ 3), monitoring và dự toán chi phí. Số liệu lấy từ lần
chạy `2026-11-09`; production sau purge `2026-11-10` có `users=1 tasks=0`, sau đó seed 16 việc
mẫu cho tài khoản thật (`users=1 tasks=16`; local vẫn seed 2 user / 5 task).

## 1. Postgres local

Container `cdb-study` (postgres:17.11), volume `cdb-study-data`, `127.0.0.1:55432`,
DB `studydb`. Kết nối kiểm tra: `psql -h 127.0.0.1 -p 55432 -U postgres -d studydb`.

### 1.1. Ràng buộc

```text
Table "public.users"
 id     | bigint | not null | generated always as identity
 email  | text   | not null |
Indexes:
    users_pkey PRIMARY KEY (id)
    users_email_key UNIQUE (email)

Table "public.tasks"
 id      | bigint | not null | generated always as identity
 user_id | bigint | not null |
 title   | text   | not null |
 status  | text   | not null | 'todo'
Check constraints:
    tasks_status_check CHECK (status IN ('todo','doing','done'))
    tasks_title_check  CHECK (length(btrim(title)) > 0)
Foreign-key constraints:
    tasks_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id)
```

Thử dữ liệu xấu — cả 4 ràng buộc đều chặn ở DB:

| Thử | Lỗi |
|---|---|
| `INSERT users(email)` trùng `an@example.test` | `23505` `users_email_key` |
| `tasks.title = '   '` / `''` | `23514` `tasks_title_check` |
| `tasks.status = 'blocked'` / `UPDATE ... 'archived'` | `23514` `tasks_status_check` |
| `tasks.user_id = 999999` | `23503` `tasks_user_id_fkey` |

### 1.2. Transaction

```sql
SELECT id, user_id, title, status FROM tasks WHERE id = 2;
BEGIN;
UPDATE tasks SET status = 'done' WHERE id = 2;
SELECT id, title, status FROM tasks WHERE id = 2;
ROLLBACK;
SELECT id, title, status FROM tasks WHERE id = 2;
```

```text
 id | user_id |       title        | status
----+---------+--------------------+--------
  2 |       1 | Nộp bài tập tuần 3 | doing

 id |       title        | status
----+--------------------+--------
  2 | Nộp bài tập tuần 3 | done

 id |       title        | status
----+--------------------+--------
  2 | Nộp bài tập tuần 3 | doing
```

Bên trong transaction thấy `done`; sau `ROLLBACK` quay lại `doing`, không ghi xuống đĩa.

### 1.3. Index `idx_tasks_user_status (user_id, status)`

> Số liệu dưới đây là **evidence lịch sử GĐ 2**. Sau migration GĐ C, index này được thay bằng
> `idx_tasks_user_status_position (user_id, status, position)` — xem [schema.md](schema.md).

Với bảng 5 dòng, planner chọn **Seq Scan** cả trước và sau khi tạo index (chi phí đọc toàn
bảng thấp hơn):

```text
Seq Scan on tasks  (cost=0.00..1.07 rows=1 width=72) (actual time=0.011..0.012 rows=1 loops=1)
  Filter: ((user_id = 1) AND (status = 'todo'::text))
  Rows Removed by Filter: 4
```

Ép `SET enable_seqscan = off` → planner dùng index, chứng minh index hợp lệ và sẽ được chọn
khi bảng lớn:

```text
Index Scan using idx_tasks_user_status on tasks  (cost=0.13..8.15 rows=1 width=72)
  Index Cond: ((user_id = 1) AND (status = 'todo'::text))
```

### 1.4. Persistence

Xoá container, **giữ volume**, tạo lại:

```text
TRƯỚC: users=2 tasks=5  md5(users)=d2f198dbac7c784edb5dace18d85af21  md5(tasks)=aaaaa7a6658f216d9461a9bfe097eedf
SAU  : users=2 tasks=5  md5(users)=d2f198dbac7c784edb5dace18d85af21  md5(tasks)=aaaaa7a6658f216d9461a9bfe097eedf
app_user|t|f      (role còn, login được)
```

Dữ liệu, role và mật khẩu `app_user` nằm trong volume; xoá/tạo lại container không mất.
Giới hạn: mất volume hoặc VM là mất (xem backup).

### 1.5. Backup / restore

```bash
docker exec cdb-study pg_dump -Fc -U postgres -d studydb > /home/azureuser/studydb-lab.dump
docker exec cdb-study psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS studydb_restore"
docker exec cdb-study psql -U postgres -d postgres -c "CREATE DATABASE studydb_restore"
docker exec -i cdb-study pg_restore --exit-on-error -U postgres -d studydb_restore < /home/azureuser/studydb-lab.dump
```

```text
dump:    -rw-r--r-- 6101 bytes, "PostgreSQL custom database dump - v1.16-0"
         dump_ms=125  size_bytes=6101
restore: exit=0  restore_ms=228
count:   studydb users=2 tasks=5 | studydb_restore users=2 tasks=5
md5:     users d2f198db...  tasks aaaaa7a6...  (hai DB trùng)
object:  tasks:idx_tasks_user_status,tasks_pkey,users_email_key,users_pkey (trùng)
```

Giới hạn: chưa test mất toàn máy/PITR/failover; dump nằm cùng VM; chưa đo RTO/RPO thật.

## 2. Neon PostgreSQL 17

- Endpoint trực tiếp: `ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech:5432`
  (project `icy-sound-48483515`, region `aws-ap-southeast-1`).
- Endpoint pooled `...-pooler...` kết nối được nhưng app dùng trực tiếp.
- DB `studydb`, role `app_user` (không superuser). Không đụng `neondb`.

### 2.1. TLS verify-full

```bash
psql "host=<endpoint> port=5432 dbname=studydb user=app_user sslmode=verify-full sslrootcert=system"
```

```text
subject=CN = *.ap-southeast-1.aws.neon.tech
issuer=C = US, O = Let's Encrypt, CN = YR1
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off, ALPN: postgresql)
```

App dùng `DB_SSLROOTCERT=/etc/ssl/certs/ca-certificates.crt` (vẫn verify-full). `pg_stat_ssl`
trên compute node trả `ssl=f` vì Neon kết thúc TLS tại proxy; client vẫn xác minh cert thật.

### 2.2. Restore & CRUD

```text
pg_restore --no-owner --no-privileges: 3107 ms
md5 users/tasks: trùng local
app_user: INSERT/SELECT/UPDATE/DELETE OK; đọc pg_authid bị từ chối
```

### 2.3. Dữ liệu thật nằm ở Neon (không phải RAM app)

```text
POST /api/tasks → {"id":36,...}
SQL độc lập     → id=36 | user_id=1 | Task tu web truoc khi restart | todo
restart cdb-kanban → task 36 vẫn còn trong GET /api/tasks
```

### 2.4. Sai mật khẩu & không lộ secret trong log

```text
psql ... PGPASSWORD=<sai> → ERROR: password authentication failed for user "app_user"

journalctl -u cdb-kanban | grep -cF "$NEON_APP_PASSWORD"  → 0
grep -rcF "$NEON_APP_PASSWORD" /var/log/nginx/             → 0
```

### 2.5. App dùng `app_user`

```text
/api/health (detail) → db_user=app_user, database=studydb, sslmode=verify-full
pg_stat_activity     → app_user | cdb-kanban | idle | 2 kết nối (2 worker)
```

## 3. Monitoring (`pg_stat_activity`)

```text
 datname  | state  | count
----------+--------+-------
 postgres |        |     4
 studydb  | active |     1
 studydb  | idle   |     3
          |        |     6

 pid  | usename  | application_name | client_addr | state
  875 | app_user | psql             | ::1         | idle
 1975 | app_user | cdb-kanban       | 10.9.12.116 | idle
 1976 | app_user | cdb-kanban       | 10.9.58.101 | idle
 1995 | app_user | psql             | 10.9.58.101 | active

application_name | usename  | count
 cdb-kanban      | app_user |     2
 psql            | app_user |     2
```

- Pool `max_size=5`, giữ 1 connection warm; 2 worker → 2–3 connection là bình thường.
- Không có kết nối từ Internet vào 5432 của VM (chỉ loopback 55432).

## 4. Chi phí

Nguồn: Azure Retail Prices API (`japaneast`, Consumption) + Neon pricing, tra `2026-11-09`.

| Hạng mục | Meter | Đơn giá |
|---|---|---|
| VM | `Standard_B2pls_v2` (Arm64, 2 vCPU/4 GiB) | $0.0524/giờ |
| Static IP | `Standard IPv4 Static Public IP` | $0.005/giờ (~$3.65/tháng) |
| Disk | Standard SSD E4 LRS (32 GiB) | $2.40/tháng |
| Egress | `Standard Data Transfer Out` | $0.12/GB (100 GB đầu miễn phí) |
| Neon | Free | $0 |

| Hạng mục | 8 giờ demo | 24 giờ | 730 giờ |
|---|---:|---:|---:|
| VM | $0.42 | $1.26 | $38.25 |
| Static IP | $0.04 | $0.12 | $3.65 |
| Disk | $0.03 | $0.08 | $2.40 |
| Egress | $0.00 | $0.00 | $0.00 |
| Neon | $0.00 | $0.00 | $0.00 |
| **Tổng** | **≈ $0.49** | **≈ $1.46** | **≈ $44.30** |

- Buổi lab 30–60 phút ≈ $0.03–0.06. Chạy 24/7 vượt ngưỡng $10 sau ~7 ngày (≈165 giờ).
- Deallocate VM: IP + đĩa vẫn ≈ $6.05/tháng.
- Neon Free không tốn tiền; chỉ xoá DB `studydb` khi dọn, giữ project.

## 5. Ghi chú

- Endpoint pooled không dùng vì app không cần prepared statement dài/LISTEN-NOTIFY.
- Neon Free scale-to-zero 5 phút; cold start 1.9–3.1 s, pool không trả 500/503.
- Backup local và Neon đều thủ công; chưa có lịch định kỳ.
