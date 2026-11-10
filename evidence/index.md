# Index - truy van loc (user_id, status)

- Thoi diem chay: `2026-11-09T09:48:06+00:00`
- Bang tasks hien co 5 dong (du lieu mau rat nho).

## Truoc khi co index

```sql
DROP INDEX IF EXISTS idx_tasks_user_status;

```

```text
```

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT id, title, status FROM tasks WHERE user_id = 1 AND status = 'todo';

```

```text
                                           QUERY PLAN                                           
------------------------------------------------------------------------------------------------
 Seq Scan on tasks  (cost=0.00..1.07 rows=1 width=72) (actual time=0.008..0.009 rows=1 loops=1)
   Filter: ((user_id = 1) AND (status = 'todo'::text))
   Rows Removed by Filter: 4
   Buffers: shared hit=1
 Planning:
   Buffers: shared hit=75 dirtied=1
 Planning Time: 0.265 ms
 Execution Time: 0.032 ms
(8 rows)

```

## Tao index

```sql
CREATE INDEX idx_tasks_user_status ON tasks (user_id, status);

```

```text
```


## Sau khi co index

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT id, title, status FROM tasks WHERE user_id = 1 AND status = 'todo';

```

```text
                                           QUERY PLAN                                           
------------------------------------------------------------------------------------------------
 Seq Scan on tasks  (cost=0.00..1.07 rows=1 width=72) (actual time=0.011..0.012 rows=1 loops=1)
   Filter: ((user_id = 1) AND (status = 'todo'::text))
   Rows Removed by Filter: 4
   Buffers: shared hit=1
 Planning:
   Buffers: shared hit=93 read=1
 Planning Time: 0.369 ms
 Execution Time: 0.037 ms
(8 rows)

```

## Ep planner dung index (enable_seqscan=off)

```sql
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT id, title, status FROM tasks WHERE user_id = 1 AND status = 'todo';
RESET enable_seqscan;

```

```text
                                                          QUERY PLAN                                                          
------------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_tasks_user_status on tasks  (cost=0.13..8.15 rows=1 width=72) (actual time=0.062..0.062 rows=1 loops=1)
   Index Cond: ((user_id = 1) AND (status = 'todo'::text))
   Buffers: shared hit=4 read=1
 Planning:
   Buffers: shared hit=94
 Planning Time: 0.289 ms
 Execution Time: 0.092 ms
(7 rows)

```

## Ghi chu

Voi bang nho, planner chon **Seq Scan** ca truoc va sau khi tao index vi chi phi doc toan bang thap hon. Khi tat seqscan, planner dung index `idx_tasks_user_status` -> index hop le va se duoc chon khi bang lon dan.
