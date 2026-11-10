# Evidence

Bằng chứng thật của lab: lệnh đã chạy + output đo được. Ảnh UI nằm ở `images/`.

| File | Nội dung |
|---|---|
| [api.md](api.md) | Bộ test API hiện tại **108 case** (+22 case `position`/timestamp) + lịch sử 46/67/82/86, burst, dọn tài khoản |
| [ui.md](ui.md) | 8 ảnh UI (1440/375, light/dark) + 1 ảnh ô chèn khi kéo–thả, metadata, kiểm tra browser thật |
| [cloud.md](cloud.md) | Postgres local (constraints, transaction, index, persistence, backup/restore), Neon, monitoring, cost |
| [auth.md](auth.md) | Migration login, ma trận lỗi, session, purge demo + đăng ký công khai |
| [schema.md](schema.md) | Migration `tasks.position`/`created_at`/`updated_at`, index, trigger, rollback diễn tập |
| [https.md](https.md) | Domain, cert Let's Encrypt, TLS, Cloudflare settings, security header |
| [../testing.md §1.1](../testing.md) | CI smoke **57 case** qua Flask test client + Postgres 17 trên GitHub Actions |

## Tái tạo

```powershell
# CI smoke (GitHub Actions, hoặc local với Postgres đã apply schema)
gh run list --workflow=ci.yml --limit 3
python .github\scripts\ci-smoke.py

# Dọn tài khoản test còn sót (nếu có)
powershell -File infra\ops\run-remote.ps1 -Path infra\ops\maintenance\purge-test-accounts.sh
```

Script test thủ công cũ (`app-tests.sh`, `ui-shots.mjs`, `ui-drag-check.mjs`) đã xoá khỏi
repo; output của chúng vẫn giữ nguyên trong thư mục này và git history.

## Quy ước

- Mỗi mục ghi **ngày chạy**, **đường test** (qua nginx/Cloudflare hay localhost) và
  **output thật**. Số liệu không làm tròn tùy tiện.
- Secret luôn được che: `<endpoint>`, `<redacted>`, `PGPASSWORD=<sai>`. Không có mật khẩu,
  hash thật hay API key trong repo.
- Bộ evidence cũ (20 file rời) đã được gộp vào 6 file này; bản raw đầy đủ vẫn xem được
  trong git history commit `6d3a2b7` (`evidence/`).
- Ảnh cũ (7 ảnh, còn footer) đã bị thay bằng bộ 8 ảnh hiện tại.

## Mốc tham chiếu

| Mục | Giá trị tại lần đo cuối |
|---|---|
| Ngày | 2026-11-09 → 2026-11-10 |
| Web | `https://kanban.akaine.io.vn/` |
| API test | 108 PASS / 0 FAIL, `leftover_test_users=0` |
| CI smoke | 57 PASS / 0 FAIL (Postgres 17, Flask test client) |
| Production DB | `users=1` (tài khoản thật), `tasks=16` (16 việc mẫu) |
| Production schema | `id,user_id,title,status,position,created_at,updated_at`; index `idx_tasks_user_status_position`; trigger `trg_tasks_updated_at` |
| Local DB | `users=2`, `tasks=5` (seed lab, đã backfill `position`) |
| Build asset | `?v=20261110i` |
| Cert | `CN=kanban.akaine.io.vn`, hạn 2027-02-07 |
