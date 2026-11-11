# Triển khai trên Azure VM (Tuỳ chọn)

Thư mục này chứa cấu hình và script triển khai ban đầu của tác giả trên hạ tầng Azure VM:
- **Runner**: GitHub Actions Self-hosted Runner trên VM.
- **Image**: Kéo pre-built image từ GitHub Container Registry (`ghcr.io`).
- **Web Server & SSL**: Nginx reverse proxy, Certbot Let's Encrypt và Cloudflare Real-IP.

> [!NOTE]
> **Đây là cấu hình tuỳ chọn.**
> Nếu bạn muốn triển khai ứng dụng một cách độc lập và tinh gọn trên bất kỳ VPS nào (không cần GitHub Runner, GHCR hay Cloudflare), vui lòng sử dụng file [`docker-compose.yml`](../../docker-compose.yml) và [`Caddyfile`](../../Caddyfile) ở thư mục gốc repo.

## Các thành phần:
- `vm.sh`: Bootstrap máy ảo Ubuntu (cài Docker, Nginx, swap, postgres client).
- `https.sh`: Cài đặt Certbot và chứng chỉ Let's Encrypt cho Nginx.
- `deploy.sh`: Script deploy/rollback theo tag container và kiểm tra health check.
- `deploy.yml`: Workflow GitHub Actions deploy qua self-hosted runner.
- `docker-compose.yml`: Cấu hình compose production của Azure VM.
- `nginx-cdb.conf`, `nginx-cloudflare-realip.conf`: Cấu hình Nginx reverse proxy và khôi phục IP từ Cloudflare.
