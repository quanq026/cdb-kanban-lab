# Runbook thao tác tay

Các bước dưới đây chạy trên hạ tầng thật (VM / Neon / Cloudflare / Azure). Repo **không**
tự động hoá những việc này; tick từng ô sau khi làm và ghi chú kết quả.

Quy ước: `<...>` là placeholder; secret đọc từ `/etc/cdb/secrets.env` hoặc biến môi trường
của phiên shell, không dán vào repo.

## 1. Bỏ Postgres lab trên VM

Mục tiêu: VM chỉ còn `postgresql-client-17` (để `psql`/`pg_dump` lên Neon), không còn
Postgres server hay container DB.

- [ ] Xác nhận không còn ai dùng container lab:

```bash
docker ps -a --filter name=cdb-study
```

- [ ] Chuẩn bị DSN của container lab (mật khẩu thật, không dán vào repo):

```bash
export LAB_DSN='postgresql://postgres:<lab-password>@127.0.0.1:55432/studydb?sslmode=disable'
```

- [ ] Trên VM đã cài `awscli` (hoặc `rclone`) và cấu hình endpoint/bucket:

```bash
aws --version
aws s3 ls "s3://<bucket>/" --endpoint-url "https://<account-id>.r2.cloudflarestorage.com"
```

- [ ] Dump dữ liệu lab ra ngoài VM (bucket riêng, không để trong repo):

```bash
pg_dump -Fc "$LAB_DSN" -f /tmp/cdb-lab.dump
test -s /tmp/cdb-lab.dump || { echo "dump rong, dung lai"; exit 1; }
if aws s3 cp /tmp/cdb-lab.dump "s3://<bucket>/cdb-lab/$(date +%F).dump" \
  --endpoint-url "https://<account-id>.r2.cloudflarestorage.com"; then
  rm -f /tmp/cdb-lab.dump
else
  echo "upload loi: giu /tmp/cdb-lab.dump de thu lai"
  exit 1
fi
```

- [ ] Xoá container và volume:

```bash
docker rm -f cdb-study
docker volume rm cdb-study-data
```

- [ ] Kiểm tra không còn listen cổng lab:

```bash
ss -ltnp | grep 55432 || echo "no 55432 listener"
```

- [ ] Kiểm tra không có Postgres server trên host (chỉ được có client):

```bash
dpkg -l 'postgresql-*' | grep -E '^ii +postgresql-[0-9]' || echo "client-only OK"
pg_lsclusters 2>/dev/null || echo "no local cluster"
```

- [ ] `psql --version` vẫn chạy (giữ `postgresql-client-17`).

## 2. Backup Neon → R2

Workflow `backup.yml` chạy trên GitHub-hosted runner; repo không tự tạo bucket hay secret.

- [ ] Tạo bucket R2 riêng cho backup (ví dụ `cdb-backup`), **không** public.
- [ ] Tạo R2 API token quyền tối thiểu: Object Read & Write, giới hạn trong đúng bucket đó.
      Ghi lại endpoint `https://<account-id>.r2.cloudflarestorage.com`.
- [ ] (Tuỳ chọn, lưới an toàn thứ hai) Lifecycle rule xoá object sau 30 ngày — script đã
      prune còn 14 bản, rule này chỉ dọn rác nếu script chết giữa đường.
- [ ] Tạo GitHub Environment `backup` (Settings → Environments), thêm secrets:
      `NEON_BACKUP_DSN`, `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`,
      `R2_SECRET_ACCESS_KEY`, `RESTORE_TEST_DSN`; tuỳ chọn `NOTIFY_WEBHOOK`.
      `NEON_BACKUP_DSN` dùng role owner và **endpoint trực tiếp** của Neon (không phải
      host `-pooler`), vì dump + counts dùng chung một exported snapshot.
- [ ] Tạo Neon branch tạm cho restore test, lấy host của branch; trong branch đó chạy
      `CREATE DATABASE restoretest;` rồi đặt `RESTORE_TEST_DSN` trỏ database `restoretest`
      (script từ chối nếu host trùng hoặc tên database trùng production).
- [ ] Chạy lần đầu để xác nhận:

```bash
gh workflow run backup.yml --ref main -f restore_test=true
gh run watch
```

- [ ] Kiểm tra object trên R2: có `cdb-<stamp>.dump` và `cdb-<stamp>.json` dưới prefix `cdb/`.
- [ ] Điền kết quả diễn tập thật: đã restore thử ngày `____`, kết quả `____`,
      thời gian restore `____` phút (dùng để cập nhật RTO trong `operations.md`).
- [ ] (Sau khi xác nhận) đặt required reviewer cho Environment `backup` nếu muốn chặn chạy
      backup/restore ngoài ý muốn.

### 2.1. Giữ schedule sống (60 ngày)

GitHub tắt toàn bộ schedule của repo sau 60 ngày không có hoạt động; workflow hẹn giờ khác
cũng bị tắt nên không tự keepalive được. Chọn một trong hai:

- [ ] Hằng tháng kiểm tra thủ công: `gh run list --workflow backup.yml --limit 5`; nếu chỉ
      toàn `schedule` cũ hơn 2 ngày thì vào Actions → Backup → `Enable workflow` (hoặc
      `gh workflow enable backup.yml`) rồi chạy `gh workflow run backup.yml`.
- [ ] Hoặc external cron (cron-job.org, UptimeRobot…) gọi REST API mỗi tuần bằng
      fine-grained PAT chỉ có quyền Actions: write trên repo:

```bash
curl -fsS -X POST \
  -H "Authorization: Bearer $GH_PAT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/<owner>/<repo>/actions/workflows/backup.yml/dispatches" \
  -d '{"ref":"main"}'
```

- [ ] Kiểm tra job `Check latest dump age`: xanh nghĩa là bản `.dump` mới nhất ≤ 36 giờ.

## 3. Cutover systemd/venv → Docker (làm **trước** khi merge PR Docker)

Mục tiêu: đổi runtime production sang container mà vẫn giữ đường lui. **Chưa xoá**
`/opt/cdb/venv` và `cdb-kanban.service` cho tới bước 3.7. Có downtime vài giây ở bước 3.5.

- [ ] 3.1. Cài Docker + compose, giữ psql client/nginx/swap:

```bash
cd /opt/cdb/src   # checkout hiện tại trên VM
sudo bash infra/setup/vm.sh
sudo docker --version && sudo docker compose version
grep -c '^APP_SECRET_KEY=' /etc/cdb/app.env   # phải là 1; script giữ key cũ, không reset session
```

- [ ] 3.2. Cho user runner + user deploy vào group `docker`, rồi khởi động lại runner để
      nhận group mới (nếu không, `docker` sẽ báo permission denied):

```bash
sudo usermod -aG docker <runner-user>
sudo systemctl restart actions.runner.<owner>-<repo>.<runner-name>.service   # tên thật lấy từ systemctl list-units 'actions.runner*'
groups <runner-user>
```

- [ ] 3.3. Build thử image arm64 **tại chỗ** từ checkout của branch (CI chỉ push sau khi
      merge, nên bước cutover dùng image local):

```bash
cd /opt/cdb/src
git fetch origin ops/docker-ghcr && git checkout ops/docker-ghcr
sudo docker build --pull -t cdb-kanban:canary .
```

- [ ] 3.4. Chạy container thử trên cổng phụ `8001`, dùng env production, rồi kiểm tra:

```bash
sudo docker run -d --name cdb-canary --read-only --tmpfs /tmp:size=32m \
  --cap-drop ALL --security-opt no-new-privileges:true -m 256m \
  --env-file /etc/cdb/app.env -p 127.0.0.1:8001:8000 cdb-kanban:canary
sleep 5
curl -fsS http://127.0.0.1:8001/api/health
sudo docker exec cdb-canary python -c \
  'import urllib.request as u;print(u.urlopen("http://127.0.0.1:8000/api/health?detail=1").read().decode())'
sudo docker logs --tail 20 cdb-canary
```

  Kỳ vọng: health `{"status":"ok",...}`, detail thấy `db_host`/`sslmode=verify-full`
  (chứng minh CA bundle + `DB_SSLROOTCERT` hoạt động trong image). Nếu fail → sửa/rollback
  image, **chưa** đụng systemd.

- [ ] 3.4b. Kiểm tra user runner dùng được Docker và pull được GHCR (đường mà Deploy dùng:
  runner pull bằng credential của mình, rồi `sudo deploy.sh` tái sử dụng image):

```bash
sudo -u <runner-user> docker info --format '{{.ServerVersion}}'   # không lỗi permission
sudo -u <runner-user> docker pull ghcr.io/<owner>/cdb-kanban:<sha>
```

  Ở giai đoạn trước merge chưa có tag `<sha>` trên GHCR, nên bước pull này chỉ chạy được
  sau lần push `main` đầu tiên (làm ngay trước 3.7). Trước merge vẫn phải xác nhận
  `docker info` chạy được bằng user runner; nếu chưa, quay lại 3.2 (group `docker` +
  restart runner).

- [ ] 3.5. Chuyển production (downtime vài giây). Gắn tag local để compose dùng được, rồi
      tắt systemd và bật compose trên `8000`:

```bash
sudo docker tag cdb-kanban:canary ghcr.io/<owner>/cdb-kanban:local-canary
sudo install -d -m 755 /opt/cdb
sudo install -m 644 /opt/cdb/src/infra/ops/docker-compose.yml /opt/cdb/docker-compose.yml
printf 'CDB_IMAGE=%s\nIMAGE_TAG=%s\n' ghcr.io/<owner>/cdb-kanban local-canary \
  | sudo tee /opt/cdb/compose.env >/dev/null
sudo chmod 600 /opt/cdb/compose.env
sudo docker rm -f cdb-canary
sudo systemctl disable --now cdb-kanban
sudo docker compose --env-file /opt/cdb/compose.env -f /opt/cdb/docker-compose.yml up -d
```

- [ ] 3.6. Kiểm tra end-to-end (giống `deploy.sh`):

```bash
curl -fsS http://127.0.0.1:8000/api/health
curl -fsS -k --resolve kanban.akaine.io.vn:443:127.0.0.1 https://kanban.akaine.io.vn/api/health
curl -sS -o /dev/null -w '%{http_code}\n' https://kanban.akaine.io.vn/login
sudo docker compose --env-file /opt/cdb/compose.env -f /opt/cdb/docker-compose.yml ps
ss -ltnp | grep 8000
```

  Kỳ vọng: 200, `cdb-app` healthy, chỉ `127.0.0.1:8000` listen (không phải `0.0.0.0`).

- [ ] 3.7. Sau khi merge + deploy thật xanh **một lần** (workflow Deploy chạy
      `deploy.sh` với tag SHA `ghcr.io/<owner>/cdb-kanban:<sha>`), mới dọn di sản:

```bash
sudo systemctl status cdb-kanban        # phải inactive/disabled
sudo rm -f /etc/systemd/system/cdb-kanban.service
sudo systemctl daemon-reload
sudo rm -rf /opt/cdb/venv /opt/cdb/app
cat /opt/cdb/current_tag /opt/cdb/previous_tag   # phải là tag SHA thật
```

### Quay lại systemd nếu container lỗi (làm trước bước 3.7)

Trường hợp thường gặp: **lần deploy container đầu tiên fail** nên `previous_tag` chưa tồn tại
— `deploy.sh` không thể rollback bằng tag, chỉ báo lỗi rồi exit 1. Khi đó quay lại systemd:

```bash
sudo cat /opt/cdb/current_tag 2>/dev/null || echo "no current_tag"
sudo docker compose --env-file /opt/cdb/compose.env -f /opt/cdb/docker-compose.yml down
# nếu deploy đã kịp đổi nginx conf thì khôi phục bản trước
sudo ls -l /opt/cdb/nginx-backup
sudo install -m 644 /opt/cdb/nginx-backup/cdb-kanban.conf \
  /etc/nginx/sites-available/cdb-kanban
sudo install -m 644 /opt/cdb/nginx-backup/cloudflare-realip.conf \
  /etc/nginx/conf.d/cloudflare-realip.conf
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl enable --now cdb-kanban
sudo systemctl status cdb-kanban --no-pager
curl -fsS http://127.0.0.1:8000/api/health
curl -fsS -k --resolve kanban.akaine.io.vn:443:127.0.0.1 https://kanban.akaine.io.vn/api/health
```

Nếu `/opt/cdb/nginx-backup/` chưa có (deploy fail trước khi backup), nginx vẫn là bản cũ —
bỏ qua phần khôi phục. Nếu file backup không tồn tại vì trước đó chưa có conf, `deploy.sh`
đã xoá file mới; kiểm tra `ls /etc/nginx/sites-enabled/` trước khi reload.

`deploy.sh` từ chối chạy khi `cdb-kanban.service` còn active, nên chỉ enable lại khi thật
sự muốn bỏ container. Sau khi quay lại systemd, `docker compose` không được bật lại.

### Thứ tự bắt buộc

1. `vm.sh` + group docker → 2. build local + canary `8001` → 3. tắt systemd, compose `8000`
→ 4. verify → 5. merge PR → 6. deploy thật bằng tag SHA → 7. xoá venv/unit.

Không đảo bước 3 và 5: nếu merge trước khi cutover, workflow Deploy sẽ fail ngay ở guard
`cdb-kanban.service is still active` (an toàn, nhưng production vẫn ở bản cũ).

### Kiểm tra GHCR trước khi merge

- [ ] `docker login ghcr.io -u <github-user> --password-stdin` bằng PAT `read:packages`
      (hoặc `GITHUB_TOKEN` trong Actions) chạy được từ VM.
- [ ] Package `cdb-kanban` đã cấp quyền đọc cho repo (Actions access). Vào
      `https://github.com/users/<owner>/packages/container/cdb-kanban/settings` →
      **Manage Actions access** → thêm repo `<owner>/cdb-kanban-lab` với role **Read**
      (mặc định package gắn với repo đã có quyền này; kiểm tra lại sau lần push đầu).
      Kiểm tra nhanh visibility:

```bash
gh api "/users/<owner>/packages/container/cdb-kanban" --jq '.visibility'
```

- [ ] Sau lần push `main` đầu tiên: package `cdb-kanban` xuất hiện ở
      `https://github.com/<owner>?tab=packages`, có tag `<sha>` và `latest`.
- [ ] Trên VM: `sudo -u <runner-user> docker pull ghcr.io/<owner>/cdb-kanban:<sha>` thành
      công trước khi chạy `deploy.sh` lần đầu.
