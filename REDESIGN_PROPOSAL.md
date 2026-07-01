# Đề xuất tái thiết kế A→Z — Thiên Nhật (Mua hàng / Công nợ)

> Góc nhìn: thiết kế ERP độc lập. Mục tiêu: (1) chạy đúng nghiệp vụ, (2) thân thiện người dùng.
> Tài liệu này đi kèm 2 sơ đồ đã trình bày trong chat: *luồng nghiệp vụ lý tưởng* và *cơ sở dữ liệu lý tưởng*.

---

## 1. Chẩn đoán — vì sao bản hiện tại sẽ chống lại bạn

Bản hiện tại là bản **port trung thành từ Google Sheets**. Nó chạy được ở mức "sổ tay điện tử", nhưng có 8 điểm gãy khi lên nghiệp vụ thật:

| # | Vấn đề | Hệ quả |
|---|--------|--------|
| 1 | Một bảng `debts` gánh 3 vai: đơn đặt + nhận hàng + công nợ | Không nhận hàng nhiều đợt; không có chỗ gắn đề xuất thanh toán |
| 2 | Thanh toán ghi tiền ngay, không có cổng duyệt | Ngược flow "16h lãnh đạo duyệt rồi mới đi tiền" |
| 3 | Giao dịch lưu **tên** mặt hàng/NCC, không phải mã (id) | Mã hoá vật tư/nhóm hàng không chảy vào thống kê |
| 4 | Chưa nhận hàng ⇒ công nợ = 0 | Khoản "thanh toán trước" (đa số NCC) không hiện để đề xuất chi |
| 5 | "Tạm ứng" mang 3 nghĩa trong 1 cột | Thống kê nhiễu |
| 6 | Tất toán **ghi đè** `da_thanh_toan` từ một "pool" | Tiền có thể dịch chuyển khó lường; ghi sổ 2 nơi |
| 7 | Từ chối chỉ set trạng thái, không có thông báo/gửi lại | Vòng cộng tác mua hàng ⇄ lãnh đạo bị đứt |
| 8 | Không có view "đã duyệt trong ngày theo nhóm" cho lãnh đạo | Thiếu công cụ ra quyết định |

**Nguyên tắc ERP bị vi phạm nặng nhất:** *số dư phải được **tính ra** từ các bút toán bất biến, không được **ghi đè**.* Đây là gốc của rủi ro sai tiền.

---

## 2. Mô hình đích — theo chứng từ (document-centric)

Chuỗi chứng từ, mỗi bảng một vai trò, nối bằng khóa ngoại:

```
materials / doi_tuong / profiles        (master data, mã hoá)
        │
price_quotes                             (nền so sánh giá)
        │
purchase_proposals → _lines              (đề xuất mua hàng / tạm ứng)
        │  (duyệt)
ap_obligations   ← goods_receipts        (công nợ phải trả; nhận hàng nhiều đợt)
        │
payment_requests → _lines                (đề xuất thanh toán — có trạng thái duyệt)
        │  (duyệt)
payments → payment_allocations           (chi tiền + phân bổ BẤT BIẾN)

notifications                            (thông báo in-app + email)
audit_log
```

### Nguyên tắc thiết kế
1. **Tham chiếu bằng ID** ở mọi giao dịch: `material_id`, `doi_tuong_id`. Tên chỉ để hiển thị.
2. **Một chứng từ = một mục đích.** Không gộp. Nối bằng FK.
3. **Số dư = nghĩa vụ − Σ(allocation).** Allocation bất biến. Bỏ hẳn kiểu "recompute paid from pool".
4. **Cổng phê duyệt rõ ràng** cho cả đề xuất mua hàng và đề xuất thanh toán.
5. **Ràng buộc:** payment chỉ tạo được từ `payment_request` đã duyệt; `payment_request` line ưu tiên gắn `ap_obligation` đã duyệt, nếu tự nhập (ngoài PO) thì bắt buộc `giai_trinh` (mô hình lai bạn đã chọn).
6. **Tạm ứng tách bạch:** một loại là chứng từ tạm ứng (từ đề xuất loại TamUng), một loại là số dư trả trước (AR) — không nhét chung `loai_cong_no`.

---

## 3. Kế hoạch sửa theo giai đoạn (không đập bỏ phần đang chạy)

Tái cấu trúc trọn gói rủi ro cao. Đề xuất 4 đợt, mỗi đợt deploy + kiểm thử độc lập.

### Đợt A — Nối mã hoá vào giao dịch *(nền tảng, ít rủi ro)*
- Thêm `material_id`, `doi_tuong_id` vào `proposal_lines`, `debts`, `price_quotes` (giữ cột tên để tương thích).
- Backfill: khớp tên hiện có → id (script một lần, log ca không khớp để bạn duyệt tay).
- `ensure_material` / `ensure_doi_tuong` trả id và ghi id vào dòng giao dịch.
- **Lợi ích ngay:** thống kê theo nhóm hàng/NCC chính xác; so sánh giá trong màn duyệt bám mã thay vì tên.

### Đợt B — Đề xuất thanh toán + cổng duyệt *(đúng flow bạn cần nhất)*
- Bảng mới: `payment_requests`, `payment_request_lines` (các trường như ảnh: NCC, kế hoạch, số đề xuất TT, nội dung, hình thức TT, tình trạng hồ sơ).
- RPC: `rpc_create_payment_request` (kế toán, gom khoản đến hạn), `rpc_approve_payment_request` / `reject` (lãnh đạo).
- Sửa `rpc_create_payment`: **chỉ chạy được khi trỏ tới payment_request đã duyệt.**
- Màn mới: "Đề xuất thanh toán" (kế toán) + "Duyệt đề xuất thanh toán" (lãnh đạo).

### Đợt C — Thông báo + vòng gửi lại *(cộng tác)*
- Bảng `notifications` + hộp thư in-app (chuông/badge) + email (Supabase Edge Function).
- Từ chối phiếu → tạo notification cho người tạo, kèm lý do.
- Nút "Chỉnh sửa & gửi lại" trên phiếu bị từ chối (clone giữ nguyên thread, tăng version).
- Màn lãnh đạo: "Đã duyệt hôm nay theo nhóm vật tư" (asphalt, đá, cát, xi măng, dầu diesel, dầu chuyên dụng, phụ tùng).

### Đợt D — Tách công nợ khỏi nhận hàng + sổ cái bất biến *(chuẩn hoá lõi)*
- Tách `debts` → `ap_obligations` (+ `goods_receipts` cho nhận nhiều đợt).
- Cờ `prepay` trên dòng đề xuất: nếu "thanh toán trước" ⇒ nghĩa vụ đến hạn ngay khi duyệt (sửa vấn đề #4).
- Tất toán = **chỉ lưu trữ** nghĩa vụ đã trả đủ; số dư luôn tính từ allocation (sửa #6).
- Migrate dữ liệu `debts` cũ sang mô hình mới, giữ `payment_allocations` làm nguồn sự thật.

> Thứ tự ưu tiên gợi ý theo nhu cầu bạn nêu: **B → C → A → D**. B và C giải quyết flow + cộng tác (đang đau nhất); A và D là chuẩn hoá nền, làm sau khi flow đã đúng.

---

## 4. Ảnh hưởng tới frontend
- Gộp điều hướng theo vai trò: Mua hàng (đề xuất, nhận hàng), Kế toán (đề xuất TT, chi tiền, công nợ), Lãnh đạo (2 màn duyệt + dashboard nhóm), Admin (danh mục, phân quyền).
- Mỗi màn duyệt: thẻ trực quan → mở chi tiết → bằng chứng ra quyết định (phiếu, so sánh giá NCC, cờ kế hoạch tuần). *(Đã làm cho đề xuất mua hàng ở Đợt 1.)*
- Chuông thông báo + badge số chưa đọc trên header.

---

## 5. Việc đã làm (Đợt 1 trước tài liệu này)
- Sửa lỗi `relation "base"`; import 21 NCC / 21 mặt hàng / 71 báo giá.
- Mã hoá `materials` (VT-xxxx + nhóm hàng) + màn Danh mục.
- Chuyển quyền duyệt sang LanhDao; form đề xuất mua/tạm ứng + cờ kế hoạch tuần; màn duyệt mua hàng có so sánh giá NCC.

Các mục này là tiền đề tốt cho Đợt A/B/C/D ở trên; không phải làm lại.
