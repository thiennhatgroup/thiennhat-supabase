# Phân cấp & phân quyền người dùng — Thiên Nhật

## 1. Các vai trò (role)

| Vai trò (mã) | Ý nghĩa |
|---|---|
| `NhanVienMuaHang` | Nhân viên mua hàng |
| `TruongPhong` | **Trưởng bộ phận** (rà soát phiếu bộ phận mình) |
| `KeToanCongNo` | Kế toán công nợ |
| `ThuQuy` | Thủ quỹ |
| `TongGiamDoc` | Tổng giám đốc (duyệt < 10 triệu) |
| `ChuTich` | Chủ tịch (duyệt ≥ 10 triệu + override + duyệt thanh toán) |
| `Admin` | Quản trị tài khoản và bộ phận |
| `LanhDao` | *(cũ — không dùng nữa, thay bằng ChuTich/TongGiamDoc)* |

## 2. Ma trận quyền theo màn hình

✅ = thấy & dùng được theo phạm vi dữ liệu của vai trò.

| Màn hình / chức năng | Mua hàng | Trưởng BP | Kế toán | Thủ quỹ | TGĐ | Chủ tịch | Admin |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Báo giá NCC | ✅ | ✅ | ✅ | | ✅ | ✅ | |
| Đề xuất mua hàng / tạm ứng | ✅ | | | | | | |
| **Duyệt đề xuất mua hàng** | | | | | ✅ (<10tr) | ✅ (≥10tr, override) | |
| Nhận hàng (nghiệm thu) | ✅ (phiếu mình) | | | | | | |
| Duyệt hồ sơ & lưu công nợ | | | ✅ | xem | | | |
| Đề xuất thanh toán (lập) | | | ✅ | | | | |
| **Duyệt đề xuất thanh toán** | | | | | | ✅ | |
| Chi tiền đã duyệt | | | | ✅ | | | |
| **Theo dõi & rà soát** | | ✅ (bộ phận mình, xem) | ✅ (tất cả, trả lại/hủy) | | | | |
| Theo dõi công nợ | ✅ (phiếu mình) | ✅ (bộ phận mình) | ✅ (tất cả) | | ✅ | ✅ | |
| Tổng quan điều hành | | | | | ✅ | ✅ | |
| Điều chỉnh thanh toán thủ công | | | ✅ | | | | |
| Tất toán | | | ✅ | | | | |
| In đề xuất / In phiếu YCTT | ✅ | | | | | | |
| Danh mục (mặt hàng/NCC/nhóm) | xem/tạo nhanh | xem | xem | | | | |
| Tài khoản & bộ phận | | | | | | | ✅ |
| Tài khoản cá nhân / Hướng dẫn / Tin nhắn / Đề xuất cải tiến | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

**Quy tắc then chốt:**
- Đề xuất mua hàng: **≥ 10.000.000đ → Chủ tịch** duyệt; **< 10.000.000đ → Tổng giám đốc**. Chủ tịch xem & override được cả khoản của TGĐ (ngược lại thì không).
- Đề xuất thanh toán: **chỉ Chủ tịch** duyệt cuối.
- Trưởng bộ phận chỉ **xem** đề xuất đã trình của **bộ phận mình**; Kế toán rà soát toàn bộ và có quyền trả lại/hủy theo quy trình.
- Admin không còn là vai trò toàn quyền dữ liệu; Admin chỉ quản lý tài khoản và bộ phận.

## 3. Danh sách tài khoản cần tạo (gợi ý cho công ty)

| # | Người | Vai trò gán | Bộ phận (nếu TBP) |
|---|---|---|---|
| 1–6 | 6 cán bộ mua hàng | `NhanVienMuaHang` | — |
| 7 | Chủ tịch | `ChuTich` | — |
| 8 | Tổng giám đốc | `TongGiamDoc` | — |
| 9–10 | 2 kế toán | `KeToanCongNo` | — |
| (tùy chọn) | Thủ quỹ | `ThuQuy` | — |
| (tùy chọn) | Trưởng từng bộ phận | `TruongPhong` | gán đúng bộ phận (vd "Vật tư") |
| (đã có) | Quản trị | `Admin` | — |

**Cách gán:** vào menu **Tài khoản** (Admin) → tạo tài khoản (email + PIN) hoặc **Sửa** để đổi vai trò; với **Trưởng bộ phận** nhớ điền ô **Bộ phận** cho khớp với bộ phận ghi trên phiếu đề xuất (để rà soát đúng phạm vi).

*(Nếu tạo tài khoản trong app báo lỗi quyền `auth`, tạo user ở Supabase → Authentication rồi vào đây gán vai trò + bộ phận.)*
