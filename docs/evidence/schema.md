# Evidence — Schema GĐ C (`position` + timestamps)

Phạm vi: migration `tasks.position`, `created_at`, `updated_at`, index mới và trigger
`trg_tasks_updated_at`. Phần login (`users.password_hash`) nằm ở [auth.md](auth.md).

## 1. Thiết kế

| Hạng mục | Cách làm |
|---|---|
| `position` | `integer NOT NULL DEFAULT 0`; thứ tự thủ công trong `(user_id, status)`, 0 = trên cùng |
| `created_at` / `updated_at` | `timestamptz NOT NULL DEFAULT now()` |
| `updated_at` | Trigger `trg_tasks_updated_at` gọi `tasks_touch_updated_at()` ở mọi `UPDATE` — DB đảm bảo, không phụ thuộc đường ghi của app |
| Index | `idx_tasks_user_status_position (user_id, status, position)` thay `idx_tasks_user_status` |
| Backfill | `row_number() OVER (PARTITION BY user_id, status ORDER BY id) - 1` cho dữ liệu cũ |
| Tính chất | Additive + idempotent: app cũ vẫn chạy trong lúc migrate (INSERT cũ nhận `position` default 0) |
| Quyền | `app_user` giữ nguyên `SELECT/INSERT/UPDATE/DELETE` mức bảng; không cấp thêm |

## 2. File

- Up: `infra/ops/maintenance/sql/2026-11-10-task-order.sql`
- Down: `infra/ops/maintenance/sql/2026-11-10-task-order-rollback.sql`
- Runner: `infra/ops/maintenance/schema-migrate.sh` / `schema-rollback.sh`
- DDL canonical: `infra/setup/db/schema.sql`

## 3. Diễn tập up → down trong transaction (local Docker)

```bash
powershell -File infra\ops\run-remote.ps1 -Path <rehearse-task-order.sh>
```

```text
== UP ==
ALTER TABLE ... (3 cot)            -> them position/created_at/updated_at
UPDATE 5                           -> backfill position
UPDATE 5 / UPDATE 5                -> backfill created_at/updated_at
CREATE INDEX / DROP INDEX          -> idx_tasks_user_status_position thay index cu
CREATE FUNCTION / CREATE TRIGGER   -> trg_tasks_updated_at

up_columns=3
position_nulls=0
time_nulls=0
indexes=idx_tasks_user_status_position,tasks_pkey
trigger=trg_tasks_updated_at
seed_order=2:doing:0,3:done:0,1:todo:0,5:doing:0,4:todo:0

-- INSERT theo đúng pattern của app (append cuối cột todo)
 id  | position | has_created | has_updated
-----+----------+-------------+-------------
 100 |        1 | t           | t

== DOWN ==
DROP TRIGGER / DROP FUNCTION
DROP INDEX / CREATE INDEX          -> idx_tasks_user_status quay lai
ALTER TABLE ... (drop 3 cot)

down_columns=0
down_index=idx_tasks_user_status
down_trigger=0

ROLLBACK
after_rollback_columns=0    <- khong de lai thay doi sau ROLLBACK
```

## 4. Migration thật (local Docker + Neon)

```bash
powershell -File infra\ops\run-remote.ps1 -Path infra\ops\maintenance\schema-migrate.sh
```

```text
== migrate local docker (cdb-study / studydb) ==
tasks:id,user_id,title,status,position,created_at,updated_at

== migrate neon (studydb, owner) ==
tasks:id,user_id,title,status,position,created_at,updated_at

== app_user doc/ghi duoc cot moi + trigger (transaction rollback) ==
 db_user  | tasks | with_position | with_created_at
----------+-------+---------------+-----------------
 app_user |     0 |             0 |               0
```

- App cũ vẫn healthy trong lúc migrate (health 3 mức `ok`), sau đó mới deploy code mới.
- Trigger chạy không cần `EXECUTE` riêng cho `app_user` — xác nhận bằng `INSERT/UPDATE ...
  ROLLBACK` trong chính script.

## 5. Integration test với Postgres local

Flask test-client + `app_user` thật trên local Docker (`DB_SSLMODE=disable`), transaction
tự dọn tài khoản `it-*`:

```text
integration=ok tasks=3 user=100
```

Kiểm: tạo 3 task → `position` 0/1/2; PATCH `position=0` → thứ tự `c,a,b`; PATCH status →
append `position=0` ở cột đích; PATCH title → `updated_at` tăng; `position` âm/không phải số
→ 400; DELETE hết → board rỗng.

## 6. Trạng thái production sau deploy + purge

> Số liệu dưới đo ngay sau migration, trước khi seed dữ liệu mẫu. Hiện tại tài khoản thật
> có 16 việc mẫu: `users=1 tasks=16`.

```text
== production / neon (app_user) ==
users=1
tasks=0
test_users=0
schema=id,user_id,title,status,position,created_at,updated_at
indexes=idx_tasks_user_status_position,tasks_pkey
triggers=trg_tasks_updated_at

== local docker ==
users=2
tasks=5
it_users=0
order=2:doing:0,3:done:0,1:todo:0,5:doing:0,4:todo:0
```

- Deploy backup: `/opt/cdb/app/backup-2026-11-10-074504`.
- Asset bump `?v=20261110g` lúc migrate (Cloudflare cache ~4 h); chỉ báo kéo–thả sau đó
  dùng `h`/`i`.
- Bộ test API: **108 PASS / 0 FAIL**, `leftover_test_users=0` — xem [api.md](api.md).
- Browser headless: reorder `↑` ×2 + `→` đúng, reload giữ thứ tự, 0 console error — xem
  [ui.md](ui.md) §5.

## 7. Rollback

```bash
powershell -File infra\ops\run-remote.ps1 -Path infra\ops\maintenance\schema-rollback.sh
```

Chỉ đụng `tasks`: drop trigger/function, drop 3 cột, tạo lại `idx_tasks_user_status`.
**Không** đụng `users`/`password_hash`. Phải rollback app mới về bản cũ trước (hoặc cùng lúc)
vì code mới đọc `position`/`created_at`/`updated_at`.
