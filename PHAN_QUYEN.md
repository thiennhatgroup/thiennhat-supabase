# Phân cấp & phân quyền người dùng — Thiên Nhật

## 1. Các vai trò (role)

| Vai trò (mã) | Ý nghĩa |
|---|---|
| `NhanVienMuaHang` | Nhân viên mua hàng |
| `TruongPhong` | **Trưởng bộ phận** (rà soát phiếu bộ phận mình) |
| `KeToanCongNo` | Kế toán công nợ |
| `TongGiamDoc` | Tổng giám đốc (duyệt < 10 triệu) |
| `ChuTich` | Chủ tịch (duyệt ≥ 10 triệu + override + duyệt thanh toán) |
| `Admin` | Quản trị hệ thống (toàn quyền) |
| `LanhDao` | *(cũ — không dùng nữa, thay bằng ChuTich/TongGiamDoc)* |

## 2. Ma trận quyền theo màn hình

✅ = thấy & dùng được. Admin thấy tất cả.

| Màn hình / chức năng | Mua hàng | Trưởng BP | Kế toán | TGĐ | Chủ tịch | Admin |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Báo giá NCC | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Đề xuất mua hàng / tạm ứng | ✅ | | | | | ✅ |
| **Duyệt đề xuất mua hàng** | | | | ✅ (<10tr) | ✅ (≥10tr, override) | ✅ |
| Nhận hàng (nghiệm thu) | ✅ | | ✅ | | | ✅ |
| Đề xuất thanh toán (lập) | | | ✅ | | | ✅ |
| **Duyệt đề xuất thanh toán** | | | | | ✅ | ✅ |
| **Theo dõi & rà soát** (hủy phiếu chờ duyệt) | | ✅ (bộ phận mình) | ✅ (tất cả) | | | ✅ |
| Theo dõi công nợ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Tất toán | | | ✅ | | | ✅ |
| In đề xuất / In phiếu YCTT | ✅ | | | | | ✅ |
| Danh mục (mặt hàng/NCC/nhóm) | xem | | xem | | | ✅ quản lý |
| Tài khoản & phân quyền | | | | | | ✅ |
| Tài khoản cá nhân / Hướng dẫn / Tin nhắn / Tải dữ liệu / Đề xuất cải tiến | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

**Quy tắc then chốt:**
- Đề xuất mua hàng: **≥ 10.000.000đ → Chủ tịch** duyệt; **< 10.000.000đ → Tổng giám đốc**. Chủ tịch xem & override được cả khoản của TGĐ (ngược lại thì không).
- Đề xuất thanh toán: **chỉ Chủ tịch** duyệt cuối.
- Trưởng bộ phận & Kế toán rà soát và **hủy phiếu đang chờ duyệt** trước khi lên sếp; Trưởng BP chỉ trong **bộ phận của mình** (cần gán trường *Bộ phận* cho tài khoản đó).

## 3. Danh sách tài khoản cần tạo (gợi ý cho công ty)

| # | Người | Vai trò gán | Bộ phận (nếu TBP) |
|---|---|---|---|
| 1–6 | 6 cán bộ mua hàng | `NhanVienMuaHang` | — |
| 7 | Chủ tịch | `ChuTich` | — |
| 8 | Tổng giám đốc | `TongGiamDoc` | — |
| 9–10 | 2 kế toán | `KeToanCongNo` | — |
| (tùy chọn) | Trưởng từng bộ phận | `TruongPhong` | gán đúng bộ phận (vd "Vật tư") |
| (đã có) | Quản trị | `Admin` | — |

**Cách gán:** vào menu **Tài khoản** (Admin) → tạo tài khoản (email + PIN) hoặc **Sửa** để đổi vai trò; với **Trưởng bộ phận** nhớ điền ô **Bộ phận** cho khớp với bộ phận ghi trên phiếu đề xuất (để rà soát đúng phạm vi).

*(Nếu tạo tài khoản trong app báo lỗi quyền `auth`, tạo user ở Supabase → Authentication rồi vào đây gán vai trò + bộ phận.)*
