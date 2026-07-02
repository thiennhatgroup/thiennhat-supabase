# Hướng dẫn sử dụng — Phần mềm Mua hàng & Công nợ (Thiên Nhật)

Tài liệu này mô tả quy trình từ đầu đến cuối và cách dùng từng chức năng, dành cho tất cả người dùng.
Yêu cầu cụ thể liên hệ email **ahuyle.work@gmail.com**.

---

## 1. Đăng nhập

- Truy cập địa chỉ web nội bộ của công ty (GitHub Pages).
- Đăng nhập bằng **Email** + **Mã PIN** do quản trị viên (Admin) cấp.
- Menu bên trái mở bằng nút **☰** ở góc trên bên trái. Chuông **🔔** trên cùng bên phải là thông báo — bấm vào một thông báo sẽ đi thẳng tới màn hình liên quan.

## 2. Vai trò & quyền

| Vai trò | Làm được gì |
|---|---|
| **Nhân viên mua hàng** | Xem báo giá NCC; tạo & gửi đề xuất mua hàng/tạm ứng; nghiệm thu; in đề xuất & phiếu YCTT |
| **Tổng giám đốc** | Duyệt/từ chối đề xuất **< 10 triệu**; theo dõi công nợ |
| **Chủ tịch** | Duyệt/từ chối đề xuất **≥ 10 triệu** và **xem/ghi đè (override) mọi khoản** kể cả của Giám đốc; **duyệt đề xuất thanh toán** |
| **Kế toán công nợ** | Lập đề xuất thanh toán; đi tiền; theo dõi công nợ; tất toán |
| **Admin** | Toàn quyền + tạo tài khoản, phân quyền, quản lý danh mục |

Ai cũng có: **Tài khoản** (xem thông tin cá nhân), **Tin nhắn**, **Tải dữ liệu**, **Đề xuất cải tiến**.

---

## 3. Quy trình nghiệp vụ tổng thể

```
(1) Mua hàng: lập ĐỀ XUẤT mua hàng/tạm ứng (Lưu nháp → Gửi duyệt)
        │  đính kèm báo giá gốc, hạn thanh toán, tồn kho, tick trưởng BP đã duyệt
        ▼
(2) Lãnh đạo DUYỆT (≥10tr: Chủ tịch · <10tr: Tổng giám đốc)
        │  xem báo giá đính kèm, so sánh giá NCC, cờ kế hoạch tuần → Duyệt / Từ chối
        ▼
(3) Hệ thống sinh CÔNG NỢ (AP) cho từng dòng
        ▼
(4) Mua hàng NGHIỆM THU: nhập SL thực nhận, đính kèm biên bản/phiếu cân (bắt buộc),
        hóa đơn VAT (nếu có), sửa hạn TT nếu cần → Lưu → chốt số nợ NCC
        ▼
(5) Kế toán lập ĐỀ XUẤT THANH TOÁN: nạp các khoản đã nghiệm thu/đến hạn
        │  (xem báo giá, biên bản, hạn TT làm cơ sở) → Gửi duyệt
        ▼
(6) Chủ tịch DUYỆT đề xuất thanh toán
        ▼
(7) Kế toán ĐI TIỀN (nút "Đã chi tiền") → ghi nhận vào công nợ
        ▼
(8) TẤT TOÁN: khoản đã trả đủ được lưu trữ; số dư luôn tính từ các lần chi
```

Thông báo 🔔 tự động đẩy tới đúng người ở mỗi bước (gửi duyệt → lãnh đạo; duyệt/từ chối → người đề nghị; nghiệm thu xong → kế toán…).

---

## 4. Chi tiết từng chức năng

### 4.1. Báo giá NCC
- Xem bảng so sánh giá các NCC theo từng mặt hàng (giá tốt nhất, xu hướng).
- Nhập báo giá mới ở khung bên phải để cập nhật dữ liệu.

### 4.2. Đề xuất mua hàng / tạm ứng (mua hàng)
- Chọn **Loại** (Mua hàng / Tạm ứng), **Người đề nghị** & **Bộ phận** (từ danh sách), **Hạn thanh toán** (bắt buộc), **Tồn kho mặt hàng hiện tại** (tùy chọn).
- **Đính kèm báo giá** gốc (PDF/Word/ảnh) — bắt buộc với Mua hàng; lãnh đạo sẽ xem khi duyệt.
- Tick **"Trưởng bộ phận đã duyệt"** nếu đã có.
- Tick **"đã có trong kế hoạch chi tuần"**; nếu chưa → **bắt buộc giải trình**.
- Thêm các **dòng vật tư** (mặt hàng, SL, đơn giá, VAT) — thành tiền & tổng tự tính. Chọn mặt hàng sẽ tự gợi ý giá tốt nhất.
- Bấm **Lưu nháp** → phiếu hiện bên phải. Bấm **Sửa** để bổ sung, **Gửi duyệt** để đẩy lên lãnh đạo.

### 4.3. Duyệt đề xuất mua hàng (lãnh đạo)
- Danh sách tách **2 nhóm**: *Đã nằm trong kế hoạch* và *Khoản phát sinh (ngoài kế hoạch)*, kèm tổng số phiếu & số tiền mỗi nhóm.
- Nhấp một phiếu → xem chi tiết: **báo giá đính kèm**, hạn TT, tồn kho, trưởng BP đã duyệt, giải trình, và **so sánh giá NCC** cho từng mặt hàng.
- **Duyệt** (kèm ghi chú) hoặc **Từ chối** (bắt buộc lý do — gửi lại cho mua hàng).
- Mục **"Phiếu đã duyệt theo ngày"**: chọn ngày để xem lại; có thể **Hủy duyệt** (kèm lý do) nếu chưa phát sinh thanh toán.
- Phân cấp: ≥10tr → Chủ tịch; <10tr → Tổng giám đốc. Chủ tịch thấy & override được tất cả.

### 4.4. Nghiệm thu nhận hàng (mua hàng)
- Chọn khoản đã duyệt (bên phải) → nhập **SL thực nhận**, **biên bản giao nhận/phiếu cân (bắt buộc)**, **hóa đơn VAT** (nếu có), tick **hồ sơ đầy đủ**, sửa **hạn TT** nếu cần → **Lưu** để chốt về công nợ. Đây là cơ sở NCC lập hóa đơn VAT.

### 4.5. Đề xuất thanh toán (kế toán)
- Bấm **"Nạp phiếu đã nghiệm thu (đến hạn)"** → chọn khoản (thấy hạn TT, hồ sơ, báo giá, biên bản), hoặc **tự thêm dòng** (kèm giải trình nếu ngoài công nợ).
- Điền theo mẫu: NCC, kế hoạch, số tiền, nội dung, hình thức TT, tình trạng hồ sơ → **Gửi duyệt**.
- Sau khi Chủ tịch duyệt, bấm **"Đã chi tiền"** để ghi nhận thanh toán.

### 4.6. Duyệt đề xuất thanh toán (Chủ tịch)
- Xem từng phiếu (bảng dòng như mẫu) → **Duyệt / Từ chối** kèm ghi chú.

### 4.7. Theo dõi công nợ & Tất toán
- **Theo dõi công nợ**: tổng hợp AP/AR theo NCC, lọc theo ngày/đối tượng.
- **Tất toán**: xem trước & xác nhận lưu trữ các khoản đã trả đủ (kế toán).

### 4.8. Danh mục (Admin/Trưởng phòng)
- Quản lý **Mặt hàng** (mã VT, nhóm hàng, ĐVT), **Nhà cung cấp** (mã, MST, liên hệ, **số TK & chi nhánh ngân hàng**, điều khoản TT), **Nhóm hàng**, và **Người đề nghị**.

### 4.9. Tài khoản & phân quyền (Admin)
- Tạo tài khoản (email, họ tên, vai trò, PIN), đổi vai trò/trạng thái, đặt lại PIN, thêm **Bộ phận**.
- *(Nếu tạo tài khoản trong app báo lỗi quyền `auth`, tạo user ở Supabase Dashboard → Authentication, rồi gán vai trò tại đây.)*

### 4.10. In / xuất Excel (chỉ mua hàng)
- **In đề xuất mua hàng**: tick nhiều phiếu (đã duyệt & nghiệm thu) → gộp **1 file** để lãnh đạo in & ký một lần.
- **In phiếu yêu cầu TT (BM-03TH)**: chọn 1 phiếu → tự lấy số TK/ngân hàng NCC, nhập số hóa đơn tay → tải Excel đúng mẫu (số tiền theo SL nghiệm thu + VAT).

### 4.11. Tải dữ liệu (phân tích)
- Xuất Excel dữ liệu gốc theo khoảng ngày: **đề xuất mua hàng** (kèm trạng thái duyệt/nghiệm thu), **đề xuất thanh toán** (kèm trạng thái duyệt), **báo giá NCC**.

### 4.12. Tin nhắn (chat)
- Nhắn 1-1 với người dùng khác; gửi ảnh/tài liệu (≤ 5MB/tệp); **đính kèm phiếu ĐX** (nút 📄) để trao đổi/bổ sung. Người nhận nhận thông báo.

### 4.13. Đề xuất cải tiến
- Gửi góp ý cải tiến phần mềm — chuyển thẳng thông báo tới Admin.

---

## 5. Ghi chú vận hành (Admin)
- **Storage**: file đính kèm dùng bucket **`attachments`** (Supabase → Storage). Nếu gửi tệp báo lỗi, tạo bucket `attachments` (Public) một lần trong Dashboard.
- **Ngưỡng duyệt** 10.000.000đ lưu ở bảng `app_config` (key `approval_threshold`) — chỉnh được khi cần.
- **Triển khai**: mọi thay đổi được đẩy qua GitHub → GitHub Actions tự chạy migration Supabase và publish giao diện. Sau khi Actions ✓ xanh, tải lại trang (Cmd/Ctrl+Shift+R).
- **Logo**: đặt file `public/logo.png` để dùng logo gốc.
