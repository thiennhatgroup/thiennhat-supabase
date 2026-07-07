# PRD Deck: Buổi alignment lãnh đạo và pilot 2 tuần

## 1. Mục tiêu của deck

Deck này dùng cho buổi trao đổi 2-3 giờ với lãnh đạo và các bên liên quan để:

- Tạo đồng thuận về lý do cần phần mềm mua hàng và theo dõi công nợ.
- Làm rõ ranh giới giữa quy trình offline/chứng từ hợp lệ và workflow realtime trong app.
- Chuẩn bị câu trả lời cho các câu hỏi lãnh đạo có khả năng đặt ra về quyền hạn, trách nhiệm, rủi ro và kiểm soát.
- Xin greenlight chạy **pilot có kiểm soát trong 2 tuần** cho các đơn mua hàng routine hiện đang được xin và duyệt qua Viber.

Kết quả mong muốn của buổi họp:

> Lãnh đạo đồng ý cho chạy pilot 2 tuần với phạm vi, nguyên tắc, người chịu trách nhiệm, tiêu chí thành công và cơ chế fallback đã được thống nhất.

## 2. Đối tượng tham dự

- Chủ tịch
- Tổng giám đốc
- Kế toán trưởng / KTTH / kế toán công nợ
- Thủ quỹ
- Nhân viên mua hàng
- Trưởng bộ phận liên quan
- Admin / người phụ trách sản phẩm và hỗ trợ triển khai

## 3. Điểm nhìn sản phẩm cần thống nhất

Phần mềm không chỉ thay một form hay một file Excel. Vai trò đúng của nó là:

- Lớp workflow realtime cho DXMH, nghiệm thu, DXTT, chi tiền và theo dõi công nợ.
- Nơi mọi người nhìn thấy trạng thái hiện tại của một yêu cầu.
- Công cụ chuẩn hóa thao tác, giảm nhập sai, giảm hỏi qua Viber và tạo dấu vết xử lý.
- Lớp kiểm soát theo vai trò: ai được tạo, ai duyệt, ai kiểm tra hồ sơ, ai chi tiền, ai xem dashboard.

Thông điệp cần lặp lại:

> Phần mềm giúp công việc đi đúng đường. Nó không thay thế bản gốc chứng từ hợp lệ, nhưng nó làm cho trạng thái, trách nhiệm và điểm kẹt hiện rõ hơn.

## 4. Phạm vi hiện tại và non-goals

### Trong phạm vi app hiện tại

- Tạo đề xuất mua hàng / tạm ứng.
- Gửi và duyệt DXMH theo phân quyền.
- Ghi nhận nghiệm thu với số lượng thực nhận, VAT, BBGN/phiếu cân/ảnh và thông tin tài khoản NCC.
- KTTH duyệt hồ sơ trước khi lưu vào công nợ.
- Lập DXTT từ các khoản đã đủ điều kiện.
- Chủ tịch duyệt DXTT.
- Thủ quỹ chi tiền theo từng dòng và upload bằng chứng chi tiền.
- Cập nhật công nợ và dashboard theo trạng thái.

### Không nên nói như tính năng đã có

- App chưa có workflow riêng cho trường hợp thanh toán khẩn cấp khi thiếu bản gốc VAT/BBGN/chứng từ.
- App chưa nên được trình bày như công cụ thay thế toàn bộ quy trình giấy tờ/offline có chữ ký.
- App không nên bị mô tả như đã có privacy tuyệt đối ở mức từng file đính kèm. Hiện tại nên nói theo nguyên tắc phân quyền theo vai trò và workflow, đồng thời ghi nhận private attachment là hardening tiếp theo.
- Trưởng bộ phận hiện tại là điều kiện/nghiệp vụ được ghi nhận và có oversight, chưa phải một cổng phê duyệt in-app riêng ngang hàng với phê duyệt TGĐ/Chủ tịch.

## 5. Câu hỏi lãnh đạo cần được chuẩn bị

Deck nên có một slide riêng: **"Những câu hỏi cần chốt hôm nay"**.

1. Pilot sẽ chạy cho nhóm đơn nào?
2. Trong pilot, app hay Viber là hành động phê duyệt chính?
3. Nếu app và chứng từ/offline khác nhau, bên nào thắng và ai sửa trạng thái app?
4. Nếu phát sinh ca khẩn cấp thiếu chứng từ, pilot có bao gồm không?
5. Ai là owner kinh doanh quyết định pilot đạt hay chưa đạt?
6. Tiêu chí nào cho thấy app tiện lợi hơn, chính xác hơn và cho dữ liệu realtime tốt hơn?
7. Sau 2 tuần pilot, điều kiện nào để mở rộng phạm vi?

## 6. Câu trả lời định hướng cho lãnh đạo

### 6.1 App và chứng từ offline

Nguyên tắc:

- Chứng từ hợp lệ/offline vẫn là bằng chứng pháp lý và kế toán.
- App là nơi thể hiện workflow, trạng thái, phân quyền và dấu vết.
- Nếu app và chứng từ/offline khác nhau, chứng từ đúng về mặt pháp lý/kế toán, nhưng workflow phải tạm dừng để điều chỉnh app.
- Không có silent bypass. Nếu sửa, hủy, trả lại hoặc nhập lại thì cần có lý do và dấu vết.

### 6.2 Trách nhiệm theo chốt kiểm soát

- NVMH chịu trách nhiệm về nội dung mua hàng, thông tin NCC, dữ liệu nhập ban đầu và bằng chứng upload.
- Trưởng bộ phận chịu trách nhiệm xác nhận nhu cầu của bộ phận theo quy định nội bộ.
- TGĐ/Chủ tịch chịu trách nhiệm quyết định phê duyệt dựa trên thông tin và bằng chứng hiện có.
- KTTH chịu trách nhiệm kiểm tra hồ sơ, lưu công nợ và lập DXTT đúng dữ liệu.
- Chủ tịch là người duyệt cuối cho DXTT.
- Thủ quỹ chịu trách nhiệm chi đúng dòng đã duyệt và upload bằng chứng chi tiền.
- Admin chịu trách nhiệm tài khoản, phân quyền và cấu hình, không chịu trách nhiệm thay cho nội dung giao dịch.

### 6.3 Ngoại lệ khẩn cấp thiếu chứng từ

Không trình bày như tính năng đã có.

Cách nói an toàn:

- Hiện tại app được thiết kế để bắt buộc hồ sơ cần thiết trước khi quy trình đi tiếp.
- Các trường hợp khẩn cấp thiếu bản gốc cần một chính sách và workflow ngoại lệ riêng.
- Nếu lãnh đạo muốn cho phép, đây nên là improvement sau pilot: có trạng thái "pending originals", lý do bắt buộc, approver chấp nhận rủi ro, aging dashboard và không cho đóng hồ sơ khi chưa bổ sung đủ.

Ghi chú chi tiết đã có trong `docs/APP_IMPROVEMENT_NOTES.md`.

## 7. Đề xuất pilot 2 tuần

### 7.1 Phạm vi pilot

Pilot chỉ gồm:

- Các đơn mua hàng routine/hằng ngày hiện đang được xin và duyệt qua Viber.
- Các trường hợp có đủ thông tin để đi hết flow bình thường.
- NCC, mặt hàng, bộ phận, chứng từ và đường thanh toán tương đối rõ.
- Các case có khả năng hoàn tất trọn vòng đời trong 2 tuần: DXMH -> app approval -> nghiệm thu -> KTTH review -> DXTT -> Chủ tịch approval -> Thủ quỹ chi tiền và upload proof -> công nợ cập nhật.

Pilot loại trừ:

- Đơn khẩn cấp thiếu chứng từ gốc cần chính sách riêng.
- Đơn bất thường/chưa rõ chủ sở hữu.
- Đơn liên quan số dư đầu kỳ chưa đối soát xong.
- One-off purchase có logic ngoài quy trình.
- Trường hợp cần thay đổi quyền hạn/policy trước khi xử lý.

### 7.2 Nguyên tắc trong pilot

- Với item trong phạm vi, phê duyệt chính thức thực hiện trong app.
- Viber chỉ dùng để nhắc, hỏi nhanh, làm rõ hoặc fallback khi app bị blocker.
- Nếu dùng Viber vì app bị chặn, cần ghi nhận blocker và reconcile vào app trong ngày hoặc ngày làm việc kế tiếp.
- Pilot không được biến thành "nhập lại dữ liệu sau khi việc đã xong". Mục tiêu là test workflow thật, không chỉ test data entry.

### 7.3 Owner pilot

- Business owner đề xuất: Kế toán trưởng / KTTH.
- Product/support owner: Huy.
- Role owners:
  - NVMH: chất lượng dữ liệu DXMH và hồ sơ upload.
  - Lãnh đạo: phê duyệt trong app đúng thời điểm.
  - KTTH: kiểm tra hồ sơ, công nợ, DXTT.
  - Thủ quỹ: chi tiền đúng dòng và upload proof.

## 8. Tiêu chí thành công của pilot

Không đo thành công bằng "không có lỗi". Pilot thành công khi nó chứng minh được app có thể thay thế Viber cho lane routine với các outcome sau.

### 8.1 Convenience

- Người dùng từng vai trò có thể hoàn thành phần việc của mình mà không cần hỗ trợ liên tục.
- Routine approval diễn ra trong app thay vì phải chase qua Viber.
- Mọi người xem được "đang ở bước nào" mà không phải hỏi nhiều người.
- Các màn hình theo vai trò đủ để người dùng biết việc tiếp theo cần làm.

### 8.2 Accuracy

- Số tiền, VAT, số lượng thực nhận, trạng thái duyệt, trạng thái công nợ và trạng thái chi tiền trong app khớp với thực tế/offline.
- Routing phê duyệt đúng theo vai trò và ngưỡng tiền.
- Thông tin NCC, tài khoản ngân hàng, hóa đơn VAT, BBGN/phiếu cân và proof chi tiền được nhập/upload đầy đủ cho case pilot.
- Sai lệch nếu có được phát hiện, có owner và có cách sửa rõ.

### 8.3 Real-time visibility

- Lãnh đạo mở app có thể thấy:
  - DXMH đang chờ duyệt.
  - Hàng đang chờ nghiệm thu.
  - Hồ sơ đang chờ KTTH review.
  - DXTT đang chờ duyệt.
  - Khoản đã chi và proof chi tiền.
  - Vị trí công nợ hiện tại.
- Dashboard trả lời được câu hỏi: việc đang kẹt ở đâu, ai đang giữ bước tiếp theo, giá trị tiền là bao nhiêu.

### 8.4 Risk control

- Không có silent bypass cho item trong phạm vi pilot.
- Fallback Viber nếu có được ghi lại như blocker và reconcile vào app.
- Các exception cần policy riêng được tách ra, không tính là lỗi pilot nếu đã được loại trừ đúng cách.
- Sau pilot có danh sách blocker/fix rõ ràng, ưu tiên được và gắn owner.

## 9. Narrative deck đề xuất

Deck nên đi theo arc:

1. Hiện trạng: Viber/Excel/offline đang giúp xử lý nhanh nhưng khó thấy trạng thái và khó truy vết.
2. Vấn đề lãnh đạo cần giải quyết: không phải "thêm phần mềm", mà là tạo workflow rõ trách nhiệm và realtime.
3. Giải pháp: app là lớp workflow/control layer cho DXMH -> công nợ -> DXTT -> chi tiền.
4. Ranh giới quan trọng: app không thay thế chứng từ gốc/offline authority.
5. Vai trò và chốt kiểm soát: ai làm gì, ai chịu trách nhiệm ở đâu.
6. Safeguards: phân quyền, audit/history, required evidence, dashboard, fallback policy.
7. Walkthrough đồ thị: một case routine từ Viber lane đi qua app.
8. Pilot 2 tuần: phạm vi, nguyên tắc, owner, success criteria.
9. Câu hỏi cần lãnh đạo chốt.
10. Approval ask: xin greenlight pilot 2 tuần.

## 10. Cấu trúc slide cấp cao

### Phần A - Vì sao cần thay đổi

1. Mục tiêu buổi họp: xin đồng thuận pilot 2 tuần.
2. Hiện trạng: routine purchasing order đang đi qua Viber/offline.
3. Pain points: hỏi trạng thái, sai/trễ thông tin, khó truy vết, khó nhìn công nợ realtime.
4. Nguyên tắc mới: app là workflow/control layer, không thay thế chứng từ gốc.

### Phần B - Operating model

5. Full lifecycle: DXMH -> duyệt -> nghiệm thu -> KTTH -> DXTT -> duyệt chi -> thủ quỹ chi -> công nợ.
6. Role map: NVMH, TBP, TGĐ/Chủ tịch, KTTH, Thủ quỹ, Admin.
7. Accountability by checkpoint.
8. Offline vs app authority.
9. Sensitive data and access principle.
10. Current limitation: urgent missing-original exception not in scope yet.

### Phần C - Product walkthrough

11. Routine purchasing case example.
12. NVMH tạo DXMH.
13. Lãnh đạo duyệt trong app.
14. NVMH nghiệm thu và upload evidence.
15. KTTH review hồ sơ và lưu công nợ.
16. KTTH lập DXTT.
17. Chủ tịch duyệt DXTT.
18. Thủ quỹ chi tiền và upload proof.
19. Dashboard/visibility: xem đang kẹt ở đâu.

### Phần D - Pilot proposal

20. Pilot scope: routine Viber purchasing orders only.
21. What is included / excluded.
22. App approval is primary for in-scope pilot items.
23. Viber fallback rule.
24. Pilot owner and responsibilities.
25. Success criteria: convenience, accuracy, realtime visibility, risk control.
26. Questions leadership needs to decide today.
27. Final ask: approve 2-week controlled pilot.

## 11. Slide copy snippets

Short memorable lines:

> Không cần hỏi "đơn này tới đâu rồi?" nếu hệ thống luôn trả lời được.

> Chứng từ gốc là bằng chứng. App là dòng thời gian và dấu vết xử lý.

> Pilot không phải go-live. Pilot là cách chứng minh lane routine có thể chạy thật trong app.

> Viber có thể hỗ trợ trao đổi, nhưng không nên là nơi duy nhất biết trạng thái công việc.

> Thành công của pilot không phải là không có lỗi; thành công là thấy rõ lỗi, owner và cách sửa.

## 12. Final approval ask

Nội dung xin phê duyệt:

> Xin lãnh đạo phê duyệt chạy pilot 2 tuần cho các đơn mua hàng routine hiện đang được xử lý qua Viber. Trong phạm vi pilot, phê duyệt thực hiện trong app; Viber chỉ dùng làm fallback/trao đổi nhanh. Cuối pilot, nhóm triển khai báo cáo convenience, accuracy, realtime visibility, risk controls và danh sách blocker/fix để quyết định mở rộng.

Quyết định cần chốt trong buổi họp:

- Đồng ý chạy pilot 2 tuần hay không.
- Chọn lane/bộ phận/NVMH/NCC/mặt hàng routine để pilot.
- Xác nhận app approval là hành động chính cho item trong scope.
- Xác nhận owner pilot.
- Xác nhận tiêu chí thành công và cách báo cáo cuối pilot.
