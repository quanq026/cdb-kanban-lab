# Constraints - PostgreSQL 17 (container local)

- Thoi diem chay: `2026-11-09T09:48:06+00:00`
- Ket noi: `psql -h 127.0.0.1 -p 55432 -U postgres -d studydb`

## Dinh nghia rang buoc

```text
                         Table "public.users"
 Column |  Type  | Collation | Nullable |           Default            
--------+--------+-----------+----------+------------------------------
 id     | bigint |           | not null | generated always as identity
 email  | text   |           | not null | 
Indexes:
    "users_pkey" PRIMARY KEY, btree (id)
    "users_email_key" UNIQUE CONSTRAINT, btree (email)
Referenced by:
    TABLE "tasks" CONSTRAINT "tasks_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id)

                          Table "public.tasks"
 Column  |  Type  | Collation | Nullable |           Default            
---------+--------+-----------+----------+------------------------------
 id      | bigint |           | not null | generated always as identity
 user_id | bigint |           | not null | 
 title   | text   |           | not null | 
 status  | text   |           | not null | 'todo'::text
Indexes:
    "tasks_pkey" PRIMARY KEY, btree (id)
    "idx_tasks_user_status" btree (user_id, status)
Check constraints:
    "tasks_status_check" CHECK (status = ANY (ARRAY['todo'::text, 'doing'::text, 'done'::text]))
    "tasks_title_check" CHECK (length(btrim(title)) > 0)
Foreign-key constraints:
    "tasks_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id)

```

## 1. UNIQUE email (chen trung)

```sql
INSERT INTO users (email) VALUES ('an@example.test');

```

```text
psql:/tmp/evidence/sql/c1.sql:1: ERROR:  duplicate key value violates unique constraint "users_email_key"
DETAIL:  Key (email)=(an@example.test) already exists.
```

## 2. CHECK title khong rong (toan dau cach / rong)

```sql
INSERT INTO tasks (user_id, title) VALUES (1, '   ');

```

```text
psql:/tmp/evidence/sql/c2.sql:1: ERROR:  new row for relation "tasks" violates check constraint "tasks_title_check"
DETAIL:  Failing row contains (67, 1,    , todo).
```

```sql
INSERT INTO tasks (user_id, title) VALUES (1, '');

```

```text
psql:/tmp/evidence/sql/c3.sql:1: ERROR:  new row for relation "tasks" violates check constraint "tasks_title_check"
DETAIL:  Failing row contains (68, 1, , todo).
```

## 3. CHECK status hop le

```sql
INSERT INTO tasks (user_id, title, status) VALUES (1, 'hop le', 'blocked');

```

```text
psql:/tmp/evidence/sql/c4.sql:1: ERROR:  new row for relation "tasks" violates check constraint "tasks_status_check"
DETAIL:  Failing row contains (69, 1, hop le, blocked).
```

```sql
UPDATE tasks SET status = 'archived' WHERE id = 1;

```

```text
psql:/tmp/evidence/sql/c5.sql:1: ERROR:  new row for relation "tasks" violates check constraint "tasks_status_check"
DETAIL:  Failing row contains (1, 1, Soạn đề cương báo cáo, archived).
```

## 4. FK user_id phai ton tai

```sql
INSERT INTO tasks (user_id, title) VALUES (999999, 'mo coi');

```

```text
psql:/tmp/evidence/sql/c6.sql:1: ERROR:  insert or update on table "tasks" violates foreign key constraint "tasks_user_id_fkey"
DETAIL:  Key (user_id)=(999999) is not present in table "users".
```

## Ket luan

Ca 4 rang buoc deu chan du lieu xau o tang database. Ma loi: `23505` (unique), `23514` (check), `23503` (foreign key).
