# Evidence

Bằng chứng thật của lab: lệnh đã chạy + output đo được. Ảnh UI nằm ở `images/`.

| File | Nội dung |
|---|---|
| [api.md](api.md) | Bộ test API hiện tại 86 case + lịch sử 46/67/82 case, burst, dọn tài khoản |
| [ui.md](ui.md) | 8 ảnh UI (1440/375, light/dark), metadata, kiểm tra browser thật |
| [cloud.md](cloud.md) | Postgres local (constraints, transaction, index, persistence, backup/restore), Neon, monitoring, cost |
| [auth.md](auth.md) | Migration login, ma trận lỗi, session, purge demo + đăng ký công khai |
| [https.md](https.md) | Domain, cert Let's Encrypt, TLS, Cloudflare settings, security header |

## Tái tạo

```powershell
# API (trên VM)
powershell -File infra\tools\run-remote.ps1 -Path infra\test\app-tests.sh

# Ảnh UI (từ máy local, cần Chrome + Node ≥ 20)
node infra\test\ui-shots.mjs docs\evidence\images
powershell -File infra\tools\run-remote.ps1 -Path infra\maintenance\purge-test-accounts.sh
```

## Quy ước

- Mỗi mục ghi **ngày chạy**, **đường test** (qua nginx/Cloudflare hay localhost) và
  **output thật**. Số liệu không làm tròn tùy tiện.
- Secret luôn được che: `<endpoint>`, `<redacted>`, `PGPASSWORD=<sai>`. Không có mật khẩu,
  hash thật hay API key trong repo.
- Bộ evidence cũ (20 file rời) đã được gộp vào 5 file này; bản raw đầy đủ vẫn xem được
  trong git history commit `6d3a2b7` (`evidence/`).
- Ảnh cũ (7 ảnh, còn footer) đã bị thay bằng bộ 8 ảnh hiện tại.

## Mốc tham chiếu

| Mục | Giá trị tại lần đo cuối |
|---|---|
| Ngày | 2026-11-09 → 2026-11-10 |
| Web | `https://kanban.akaine.io.vn/` |
| API test | 86 PASS / 0 FAIL, `leftover_test_users=0` |
| Production DB | `users=1` (tài khoản thật), `tasks=0` |
| Local DB | `users=2`, `tasks=5` (seed lab) |
| Build asset | `?v=20261110f` |
| Cert | `CN=kanban.akaine.io.vn`, hạn 2027-02-07 |
