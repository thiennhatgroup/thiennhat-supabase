# Bật thông báo đẩy "thật" trên điện thoại (Web Push)

App đã có **2 mức thông báo**:

1. **Đang chạy sẵn (không cần cấu hình gì):** khi mở app (kể cả chạy nền/thu nhỏ trên Android), có tin mới sẽ hiện **thông báo hệ thống**. Bấm nút **"🔔 Bật thông báo trên thiết bị này"** trong panel chuông để cho phép.
2. **Push thật (app đóng vẫn nhận) — tùy chọn, làm theo dưới đây.**

## Các bước bật Push thật

### 1. Tạo VAPID keys
Chạy 1 lần (máy có Node):
```
npx web-push generate-vapid-keys
```
Nhận được `Public Key` và `Private Key`.

### 2. Khai báo Public Key cho web
Mở `public/config.js`, thêm dòng:
```js
window.APP_CONFIG.vapidPublicKey = "DÁN_PUBLIC_KEY_VÀO_ĐÂY";
```
(hoặc thêm `vapidPublicKey: "..."` vào object APP_CONFIG). Push chỉ tự đăng ký khi có key này.

### 3. Deploy Edge Function gửi push
Repo đã có sẵn file `supabase/functions/send-push/index.ts`. Function này dùng
`PUSH_WEBHOOK_SECRET` để chỉ trigger trong database gọi được.

Deploy:
```
supabase functions deploy send-push --no-verify-jwt
supabase secrets set VAPID_PUBLIC=... VAPID_PRIVATE=... PUSH_WEBHOOK_SECRET=...
```
(SUPABASE_URL và SUPABASE_SERVICE_ROLE_KEY thường có sẵn trong môi trường function.)

### 4. Khai báo cùng secret cho database trigger
Tạo một chuỗi bí mật mạnh, ví dụ:
```
openssl rand -hex 32
```

Dùng đúng chuỗi đó cho `PUSH_WEBHOOK_SECRET` ở bước 3, rồi lưu vào Supabase
Vault với tên `push_webhook_secret`:
```sql
select vault.create_secret(
  'DAN_CHUOI_SECRET_VAO_DAY',
  'push_webhook_secret',
  'Shared secret for send-push trigger'
);
```

Các migration tạo sẵn trigger `tg_push_on_notify()`. Trigger này gửi header
`x-push-webhook-secret` kèm payload cũ `{ record: ... }` tới Edge Function.
Nếu chưa cấu hình secret, trigger sẽ bỏ qua push thật thay vì gọi function
không xác thực.

Từ đó, mỗi khi hệ thống tạo 1 thông báo, Edge Function gửi push tới đúng người — **kể cả khi họ đã đóng app**.

## Ghi chú
- iPhone: chỉ nhận push khi app đã **"Thêm vào MH chính"** (cài như PWA) và mở ít nhất 1 lần để cho phép.
- Nếu không muốn push thật, cứ để trống `vapidPublicKey` — app vẫn dùng thông báo hệ thống nội bộ (mức 1).
