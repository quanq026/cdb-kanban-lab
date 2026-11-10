# Cloud Database Lab — PostgreSQL 17 · Docker · Azure · Neon

Bài lab end-to-end: dựng PostgreSQL 17 trong Docker trên VM Azure, làm backup/restore,
đẩy dữ liệu lên Neon (managed Postgres), rồi chạy web Kanban Flask dùng chính database
cloud đó — kèm đăng nhập, đăng ký, HTTPS và bộ test thật.

| | |
|---|---|
| Web | <https://kanban.akaine.io.vn/> |
| Health | <https://kanban.akaine.io.vn/api/health> |
| Repo | `quanq026/cdb-kanban-lab` (private) |
| Trạng thái | Demo đang chạy; production `users=1`, `tasks=0` |

## Kiến trúc trong 10 giây

```
Browser ──HTTPS──► Cloudflare (proxy, SSL strict)
                        │ TLS 1.2/1.3
                        ▼
                   nginx :443 (VM Azure) ──► gunicorn 127.0.0.1:8000 (Flask)
                                                   │ psycopg_pool 1–5
                                                   ▼
                                    Neon PostgreSQL 17 "studydb" (verify-full)
```

VM còn chạy container `postgres:17` tại `127.0.0.1:55432` làm nguồn dump cho lab và
backup; app production chỉ nói chuyện với Neon. Chi tiết: [docs/architecture.md](docs/architecture.md).

## Cấu trúc repo

```
app/                        Runtime web app (deploy vào /opt/cdb/app)
  app.py                    Flask API, pool, session, static + cache headers
  index.html                Board Kanban
  login.html                Trang đăng nhập
  register.html             Trang đăng ký
  app.css                   1 file CSS (design B, light/dark, responsive)
  app.js                    1 file JS (board, auth, optimistic update, drag & drop, reorder)

infra/
  db/schema.sql             users / tasks (position + timestamps) / index / trigger / seed
  vm/                      01-provision → 02-deploy-app → 03-fix-tls
  local/                   01-init → 02-roles → 03-verify → 04-persistence → 05-backup-restore
  neon/                    01-restore → 02-verify
  https/                   01-acme → 02-cert → 03-nginx → 04-renew-hook → 05-hardening
  deploy/                  deploy.ps1, deploy-on-vm.sh, cdb-kanban.service, nginx conf
  test/                    app-tests.sh (108 case), ui-shots.mjs (8 ảnh)
  maintenance/             auth-*, schema-*, purge-*, idle-check, sql/ (migration up/down)
  tools/run-remote.ps1     Copy script LF lên VM rồi chạy bằng sudo

docs/
  architecture.md          Sơ đồ, thành phần, data model, luồng request
  api.md                   Hợp đồng API: endpoint, lỗi, validate, session
  operations.md            Deploy, rollback, migration, backup, TLS, cleanup
  security.md              Least privilege, secret, TLS, auth, đánh đổi
  testing.md               Bộ test, cách chạy, kết quả, kiểm thử UI
  history.md               Nhật ký GĐ 1–6 + các phase sau, lỗi và cách sửa
  evidence/                Bằng chứng thật: api, ui, cloud, auth, https + ảnh
  design/options.{html,png} 2 phương án thiết kế GĐ B+ (mockup tĩnh)

README.md
.gitignore
```

`infra/README.md` là bảng tra nhanh từng script.

## Chạy lại

Yêu cầu: Azure CLI đã đăng nhập, SSH key `~/.ssh/id_rsa_azure`, PowerShell, Node ≥ 20
(chỉ cho script ảnh). Các lệnh chạy từ **root repo**.

```powershell
# 1. Hạ tầng mới (hiện tại đã tồn tại — bỏ qua nếu chỉ cập nhật app)
powershell -File infra\tools\run-remote.ps1 -Path infra\vm\01-provision.sh
powershell -File infra\tools\run-remote.ps1 -Path infra\local\01-init.sh
powershell -File infra\tools\run-remote.ps1 -Path infra\local\02-roles.sh
powershell -File infra\tools\run-remote.ps1 -Path infra\local\05-backup-restore.sh
powershell -File infra\tools\run-remote.ps1 -Path infra\neon\01-restore.sh

# 2. Deploy app (backup + upload + restart + health-check + tự rollback)
powershell -File infra\deploy\deploy.ps1

# 3. Kiểm thử
powershell -File infra\tools\run-remote.ps1 -Path infra\test\app-tests.sh
node infra\test\ui-shots.mjs docs\evidence\images
powershell -File infra\tools\run-remote.ps1 -Path infra\maintenance\purge-test-accounts.sh
```

`deploy.ps1` sao lưu bản cũ vào `/opt/cdb/app/backup-YYYY-MM-DD[-HHMMSS]/` trước khi ghi
đè; nếu `nginx -t` fail, service không lên hoặc health-check fail thì tự khôi phục.
Mỗi lần đổi `app.css`/`app.js` phải tăng `?v=` trong **cả ba** HTML vì Cloudflare cache
asset tĩnh (~4 h).

## Cấu hình production

| Thành phần | Giá trị |
|---|---|
| VM | `vm-cdb` · `20.48.104.156` · japaneast · `Standard_B2pls_v2` (Arm64, 2 vCPU / 4 GiB) · Ubuntu 24.04.5 |
| App | `/opt/cdb/app`, venv `/opt/cdb/venv`, systemd `cdb-kanban`, nginx site `cdb-kanban` |
| Neon | project `icy-sound-48483515`, DB `studydb`, role `app_user`, endpoint trực tiếp (không `-pooler`) |
| TLS origin | Let's Encrypt `CN=kanban.akaine.io.vn`, hết hạn 2027-02-07, tự gia hạn `certbot.timer` |
| Secret | `/etc/cdb/app.env` (app) + `/etc/cdb/secrets.env` (lab/owner), 600 root — **không** trong repo |
| DB local | container `cdb-study`, volume `cdb-study-data`, `127.0.0.1:55432`, DB `studydb` |
| Chi phí | ≈ $44.30/tháng nếu VM chạy 24/7; deallocate sau demo (`docs/operations.md` §7) |

## Tài liệu

| Muốn biết | Đọc |
|---|---|
| Hệ thống ghép thế nào, schema ra sao | [docs/architecture.md](docs/architecture.md) |
| Gọi API nào, lỗi nào | [docs/api.md](docs/api.md) |
| Deploy / rollback / migration / dọn tài nguyên | [docs/operations.md](docs/operations.md) |
| Mô hình bảo mật và đánh đổi | [docs/security.md](docs/security.md) |
| Test gì, chạy sao, kết quả | [docs/testing.md](docs/testing.md) |
| Đã làm gì, lỗi gì, sửa thế nào | [docs/history.md](docs/history.md) |
| Bằng chứng raw (lệnh + output) | [docs/evidence/README.md](docs/evidence/README.md) |

## Phạm vi & giới hạn

- Demo, không dùng cho dữ liệu thật: **không rate limit** (đã bỏ theo yêu cầu), không
  CAPTCHA/2FA/xác thực email, không có luồng quên/đổi mật khẩu.
- Session là cookie ký phía client; logout chỉ xoá cookie hiện tại. Muốn thu hồi toàn bộ
  phải đổi `APP_SECRET_KEY` rồi restart.
- Chưa test mất toàn máy/PITR/failover; dump nằm cùng VM.
- Schema GĐ C đã đủ: `tasks.position`, `created_at`, `updated_at` + trigger
  `trg_tasks_updated_at`; migration/rollback ở `infra/maintenance/sql/`.

Danh sách đầy đủ ở [docs/security.md](docs/security.md) §9 và [docs/operations.md](docs/operations.md) §8.
