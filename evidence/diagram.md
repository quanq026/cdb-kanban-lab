# Sơ đồ hệ thống

## 1. ER — users / tasks

```mermaid
erDiagram
    USERS {
        bigint id PK "GENERATED ALWAYS AS IDENTITY"
        text email UK "NOT NULL, UNIQUE"
    }
    TASKS {
        bigint id PK "GENERATED ALWAYS AS IDENTITY"
        bigint user_id FK "NOT NULL -> USERS.id"
        text title "NOT NULL, CHECK length(btrim(title)) > 0"
        text status "NOT NULL DEFAULT 'todo', CHECK IN ('todo','doing','done')"
    }
    USERS ||--o{ TASKS : "sở hữu"
```

Index: `idx_tasks_user_status (user_id, status)` phục vụ truy vấn lọc theo user + cột Kanban.

## 2. Luồng request

```mermaid
flowchart LR
    B["Trình duyệt<br/>index.html + fetch()"]
    N["nginx :80<br/>reverse proxy"]
    G["gunicorn :8000<br/>2 worker (systemd: cdb-kanban)"]
    P["psycopg_pool<br/>min 1 / max 5"]
    DB[("Neon PostgreSQL 17<br/>studydb, role app_user")]
    L[("Container local<br/>postgres:17 @ 127.0.0.1:55432<br/>chỉ dùng cho lab/backup")]

    B -- "HTTP :80" --> N
    N -- "http://127.0.0.1:8000" --> G
    G -- "SQL tham số hóa" --> P
    P -- "TLS 1.3, sslmode=verify-full<br/>+ CA hệ thống" --> DB
    G -. "pg_dump/pg_restore khi lab" .-> L
```

## 3. Luồng dữ liệu của một thao tác Kanban

```mermaid
sequenceDiagram
    participant U as Người dùng
    participant W as index.html
    participant A as Flask API
    participant D as Neon
    U->>W: kéo thẻ từ Todo sang Doing
    W->>A: PATCH /api/tasks/12 {user_id, status:"doing"}
    A->>A: validate status ∈ {todo,doing,done}
    A->>D: UPDATE tasks SET status=%s WHERE id=%s AND user_id=%s
    D-->>A: RETURNING id, user_id, title, status
    A-->>W: 200 JSON
    W->>A: GET /api/tasks?user_id=1
    A->>D: SELECT ... WHERE user_id=%s
    D-->>A: danh sách task
    A-->>W: 200 JSON
    W-->>U: render lại 3 cột
```
