# App Improvement Notes

## Urgent payment with missing original documents

**Status:** Not implemented yet. Do not present this as an existing app workflow.

### Context

During leadership onboarding, one likely question is:

> Khi cần thanh toán gấp nhưng chưa đủ hóa đơn VAT, BBGN, phiếu cân, hoặc bản gốc chứng từ thì hệ thống xử lý thế nào?

Current app behavior is stricter than the desired exception flow:

- NVMH nghiệm thu currently requires VAT invoice attachment, BBGN/receipt evidence, supplier bank account, bank branch, and VAT invoice number before saving.
- KTTH reviews hồ sơ before saving the item into confirmed debt/payment flow.
- There is no explicit "urgent exception / pending originals" state yet.

### Product principle to consider

Urgent cases should not become silent bypasses. If an urgent payment must proceed before original documents are complete, the app should make that risk visible, assign ownership, and keep the item open until evidence is completed.

### Possible future workflow

1. NVMH marks a proposal or receipt as **urgent / pending originals**.
2. NVMH uploads minimum temporary evidence and enters a required explanation.
3. The responsible approver explicitly accepts the exception.
4. KTTH can see the item as incomplete and decide whether it is allowed into DXTT.
5. The item remains flagged until missing VAT/BBGN/original documents are uploaded and checked.
6. Dashboard shows pending-original exceptions so leadership can monitor aging and owner.

### Risk controls to design

- Require a reason for every exception.
- Require explicit approver identity and timestamp.
- Separate "approved for urgent payment" from "documents complete".
- Prevent final closure/tat toan while originals are still missing.
- Show aging: how many days the item has been pending evidence.
- Notify NVMH and KTTH until evidence is completed.
- Keep audit history for exception approval, later document completion, and any correction.

### Presentation note

In the leadership deck, frame this carefully:

- Safe to say: "For urgent cases, we need a clear exception policy: evidence governs, the system must be reconciled, and pending documents must remain visible."
- Do not say yet: "The app already supports urgent payment with missing originals as a complete workflow."

### Open product question

Should urgent exceptions be allowed only before nghiệm thu/KTTH review, or can they also be used after DXTT is created but before Thủ quỹ pays?
