# Bằng chứng giao diện — design B (warm neutral + teal), menu tài khoản, không footer, desktop 1440 / mobile 375, light + dark

- Thời điểm: `2026-11-10` (sau khi deploy GĐ A + B + B+ design B + login/logout + đăng ký công khai + **bỏ rate limit/top bar mới/bỏ footer**; Neon đã xoá demo)
- URL: `https://kanban.akaine.io.vn/` · đăng nhập `/login` · đăng ký `/register`
- Công cụ: Chrome headless qua CDP (`infra/ui-shots.mjs`), emulation đúng `width`, `mobile`, `prefers-color-scheme`.
- Script **tự đăng ký** `shot+<ts>@local.test` qua `POST /api/register`, chụp board trống, tạo 3 việc mẫu (1 Todo / 1 Doing / 1 Done) rồi chụp board + menu tài khoản; không cần tài khoản seed hay mật khẩu trong biến môi trường.
- Chỉ chụp khi `.task` render (hoặc 3 empty state với board trống); không còn điều kiện chờ footer.


## Lệnh chạy

```powershell
node infra/ui-shots.mjs evidence
# sau đó dọn tài khoản evidence:
powershell -File scripts\run-remote.ps1 -Path infra\purge-test-accounts.sh
```

## Output thật của script (lưu nguyên ở `evidence/ui-shots.json`)

| Ảnh | Bytes | ready | path | counts | menuOpen | hasFooter | bg | width |
|---|---|---|---|---|---|---|---|---|
| `ui-login-light.png` | 19692 | true | `/login` | – | – | – | `rgb(251, 250, 247)` | 1440 |
| `ui-register-light.png` | 23367 | true | `/register` | – | – | – | `rgb(251, 250, 247)` | 1440 |
| `ui-empty-light.png` | 24036 | true | `/` | `0/0/0` | false | false | `rgb(251, 250, 247)` | 1440 |
| `ui-desktop-light.png` | 25241 | true | `/` | `1/1/1` | false | false | `rgb(251, 250, 247)` | 1440 |
| `ui-desktop-dark.png` | 25525 | true | `/` | `1/1/1` | false | false | `rgb(22, 21, 19)` | 1440 |
| `ui-menu-light.png` | 31116 | true | `/` | `1/1/1` | true | false | `rgb(251, 250, 247)` | 1440 |
| `ui-mobile-light.png` | 15100 | true | `/` | `1/1/1` | false | false | `rgb(251, 250, 247)` | 375 |
| `ui-mobile-dark.png` | 15437 | true | `/` | `1/1/1` | false | false | `rgb(22, 21, 19)` | 375 |

Không còn footer ở bất kỳ ảnh board/empty nào (`hasFooter=false`); `ui-menu-light.png` chụp menu avatar đang mở (email + `Đăng xuất`).

`bg` khớp token design B: sáng `--bg #fbfaf7` = `rgb(251,250,247)`, tối `#161513` = `rgb(22,21,19)`; `width` đúng 1440/375 → `prefers-color-scheme` + breakpoint mobile chạy thật.

## Design B (phương án đã chọn)

- 1 accent teal `#0f766e` (dark `#2dd4bf`) + neutrals ấm; token CSS variables cho cả light/dark.
- Màu trạng thái riêng: Todo xám, Doing cam `#c2761c`, Done xanh `#2f855a`; chip trạng thái trên mỗi thẻ.
- Radius 10–14 px, không viền cột, thẻ có hover nâng nhẹ + shadow; kéo–thả có hiệu ứng nghiêng/giảm opacity.
- Chip tài khoản thay bằng **avatar tròn mở menu** (email + `Đăng xuất`), nút đổi theme 3 trạng thái `auto → light → dark`; top bar 1 hàng trên desktop, 2 hàng trên mobile (search full width).
- Motion 150–200 ms; `@media (prefers-reduced-motion: reduce)` tắt animation/transition.
- Trang login/register là layout riêng (`.auth-*`, `.auth-alt`), cùng token, không dùng chung topbar; hai trang link qua lại.

## Kiểm tra hành vi bằng browser thật (sau purge + đăng ký)

Tab Chromium (OpenCode browser tool), dữ liệu Neon thật:

| Bước | Kết quả |
|---|---|
| Mở `/` khi chưa đăng nhập | 302 → `/login`; form login hiện, board không lộ |
| Mở `/register` | 200; 3 field, link "Đã có tài khoản? Đăng nhập" |
| Mật khẩu 7 ký tự / nhập lại sai | Lỗi inline ngay, không gửi request |
| Đăng ký hợp lệ | 201 → tự đăng nhập về `/`, board **trống** `0/0/0` + 3 empty state |
| Không footer | `document.getElementById("footer")` = `null`; không còn `Kết nối database…` |
| Menu tài khoản | Bấm avatar → menu mở (`aria-expanded=true`), email + `Đăng xuất`; bấm ra ngoài hoặc `Esc` → đóng, `Esc` trả focus về avatar |
| Theme toggle | `auto → light → dark → auto`; nền `rgb(251,250,247)` ↔ `rgb(22,21,19)` |
| Thêm việc (`N` hoặc nút) | Dialog mở, submit disable khi gửi, 201, thẻ mới xuất hiện, toast `Đã thêm việc` |
| Sửa tiêu đề (`✎` → Enter) | PATCH `title` 200, chữ đổi tại chỗ |
| Chuyển cột `→` | Đổi cột ngay (optimistic), PATCH 200, đếm cột cập nhật, chip đổi `Doing` |
| Lọc theo tiêu đề | Không khớp → 0 thẻ + empty state “Không có việc khớp từ khoá” |
| `/` | Focus ô tìm kiếm |
| Xoá | `<dialog>` xác nhận `#55 — Việc kiểm thử đăng ký (Doing)`; xác nhận → `DELETE /api/tasks/55?user_id=38` 200, thẻ biến mất, 3 empty state trở lại |
| Đăng xuất | 200 → `/login`; `/api/me` và `/api/tasks` trả 401 |
| Đăng ký trùng email qua form | 409, inline `du lieu da ton tai` |
| Console | **0 error** |

## Lỗi tìm thấy trong lúc kiểm và cách sửa

- Banner `#slow` dùng `hidden` nhưng `.slow { display: flex }` đè UA style → banner “Đang kết nối cơ sở dữ liệu…” không bao giờ ẩn. Sửa `.slow[hidden] { display: none; }`; chụp lại toàn bộ ảnh.
- **Cache asset:** HTML mới nhưng Cloudflare/browser vẫn dùng `app.js`/`app.css` cũ → `TypeError: Cannot read properties of null (reading 'addEventListener')`, board trắng. Sửa: `?v=` cho asset + `Cache-Control: no-cache`; lần này tăng lên `?v=20261110f`. Origin trả `no-cache` nhưng Cloudflare vẫn cache `max-age=14400` → **mỗi lần đổi build phải tăng `?v=`**.
- Trong test tự động, thao tác chuyển cột ngay sau lưu tiêu đề bị bỏ qua vì thẻ đang `busy` (guard chống double-submit) — hành vi đúng, test phải chờ `busy` hết.
- Script chụp ảnh phải **điều hướng lại** sau khi đăng ký/tạo task qua `fetch`, vì UI không tự render lại dữ liệu do API ngoài trang tạo; đã thêm `Page.navigate` + chờ điều kiện.

## Ghi chú

- Kéo–thả chuột dùng HTML5 drag & drop; cảm ứng dùng nút `←`/`→` (đề cho phép phương án nút thay thế trên mobile).
- Ảnh là bằng chứng trực quan; số liệu/hành vi lấy từ DOM thật.
- Bộ test API 86 case (bỏ rate limit): `evidence/app-tests-nolimit.md`; bộ 82 case còn limiter: `evidence/app-tests-register.md` (lịch sử); chi tiết login/đăng ký: `evidence/login.md`; dọn dữ liệu: `evidence/cleanup-register.md`.
- Bộ ảnh cũ (7 ảnh, có footer) đã được thay bằng bộ 8 ảnh hiện tại; metadata cũ không còn trong `ui-shots.json`.
