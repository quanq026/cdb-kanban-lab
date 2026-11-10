# Transaction - BEGIN / UPDATE / SELECT / ROLLBACK

- Thoi diem chay: `2026-11-09T09:48:06+00:00`

## Trang thai goc cua bang tasks

```text
1|1|Soạn đề cương báo cáo|todo
2|1|Nộp bài tập tuần 3|doing
3|1|Cài PostgreSQL 17|done
4|2|Chuẩn bị slide demo|todo
5|2|Kiểm thử backup/restore|doing
```

## Chay transaction: UPDATE trong BEGIN, SELECT, ROLLBACK, SELECT lai

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
(1 row)

 id |       title        | status 
----+--------------------+--------
  2 | Nộp bài tập tuần 3 | done
(1 row)

 id |       title        | status 
----+--------------------+--------
  2 | Nộp bài tập tuần 3 | doing
(1 row)

```

## Trang thai sau khi transaction ket thuc

```text
1|1|Soạn đề cương báo cáo|todo
2|1|Nộp bài tập tuần 3|doing
3|1|Cài PostgreSQL 17|done
4|2|Chuẩn bị slide demo|todo
5|2|Kiểm thử backup/restore|doing
```

## Giai thich

Ben trong transaction, `UPDATE` thay doi duoc nhin thay. Sau `ROLLBACK`, dong id=2 quay lai gia tri cu `doing`; khong co thay doi nao duoc ghi xuong dia.
