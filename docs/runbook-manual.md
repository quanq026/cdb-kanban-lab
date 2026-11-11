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
