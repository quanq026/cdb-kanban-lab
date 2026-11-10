# Dự toán chi phí

Ngày tra cứu: **2026-11-09**. Nguồn:
- Azure Retail Prices API (`https://prices.azure.com/api/retail/prices`), filter `armRegionName = 'japaneast'`, `priceType = 'Consumption'`, tra cùng ngày.
- Neon pricing: <https://neon.com/pricing> (cập nhật 2026-11-04 trên trang).

## Đơn giá tra được

| Hạng mục | Meter | Đơn giá | Ghi chú |
|---|---|---|---|
| VM | `Standard_B2pls_v2` (Arm64, 2 vCPU / 4 GiB) | **$0.0524/giờ** | giá on-demand, japaneast |
| Static public IP | `Standard IPv4 Static Public IP` | **$0.005/giờ** (~$3.65/tháng) | gắn với NIC, luôn tính phí khi tồn tại |
| Disk | Standard SSD **E4 LRS** (32 GiB) | **$2.40/tháng** | đĩa 30 GB được làm tròn lên tier E4 (32 GiB) |
| Egress | `Standard Data Transfer Out` | **$0.12/GB** | 100 GB/tháng đầu tiên miễn phí |
| Neon | Free plan | **$0** | 100 CU-hour/project, 1 GB storage, 5 GB egress; scale-to-zero sau 5 phút |

## Dự toán

Giả định: 1 VM chạy liên tục trong thời gian demo; đĩa tính theo tháng; egress demo < 100 GB (thực tế vài MB); Neon Free.

| Hạng mục | 8 giờ demo | 24 giờ | 730 giờ (1 tháng) |
|---|---:|---:|---:|
| VM B2pls_v2 (`0.0524 × giờ`) | $0.42 | $1.26 | $38.25 |
| Static public IP (`0.005 × giờ`) | $0.04 | $0.12 | $3.65 |
| Disk E4 (`2.40 / 730 × giờ`) | $0.03 | $0.08 | $2.40 |
| Egress (trong 100 GB free) | $0.00 | $0.00 | $0.00 |
| Neon Free | $0.00 | $0.00 | $0.00 |
| **Tổng** | **≈ $0.49** | **≈ $1.46** | **≈ $44.30** |

## Cảnh báo ngưỡng $10

- Chi phí của buổi lab (≈ 30–60 phút) chỉ khoảng **$0.03–0.06**, không vượt ngưỡng.
- Nếu để nguyên VM chạy 24/7, ngưỡng **$10 bị vượt sau khoảng 7 ngày** (≈ 165 giờ). Vì vậy sau khi demo xong nên `az vm deallocate` (giữ đĩa/IP) hoặc xoá RG theo `cleanup.md`.
- Nếu chỉ deallocate VM: IP tĩnh + đĩa vẫn tốn ≈ **$6.05/tháng**.
- Neon Free không phát sinh tiền, nhưng project đang nằm trong org do Vercel quản lý (dùng chung với project khác) — không xoá project, chỉ xoá database `studydb` khi dọn.

## Giới hạn của dự toán

- Chưa gồm backup/snapshot ngoài (chưa bật), log/monitoring ngoài Azure (không dùng), DNS/domain (không dùng).
- Giá có thể đổi theo thời điểm và theo hợp đồng; Azure for Students dùng credit $100 nên số tiền thực trừ là credit, không phải thẻ.
- Egress thực tế phụ thuộc lưu lượng người xem demo.
