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
window.APP.vapidPublicKey = "DÁN_PUBLIC_KEY_VÀO_ĐÂY";
```
(hoặc thêm `vapidPublicKey: "..."` vào object APP). Push chỉ tự đăng ký khi có key này.

### 3. Tạo Edge Function gửi push
Tạo file `supabase/functions/send-push/index.ts`:
```ts
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC")!;
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
webpush.setVapidDetails("mailto:admin@thiennhatgroup.com", VAPID_PUBLIC, VAPID_PRIVATE);

Deno.serve(async (req) => {
  // Nhận payload từ Database Webhook (INSERT notifications)
  const { record } = await req.json();          // record = dòng notifications vừa tạo
  const toUser = record?.to_user; if (!toUser) return new Response("no user", { status: 200 });

  // Lấy subscriptions của người nhận
  const r = await fetch(`${SUPABASE_URL}/rest/v1/push_subscriptions?user_id=eq.${toUser}&select=endpoint,p256dh,auth`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
  });
  const subs = await r.json();
  const payload = JSON.stringify({
    title: record.tieu_de || "Thông báo Thiên Nhật",
    body: record.noi_dung || "",
    data: { screen: record.man_hinh, refId: record.ref_id, loai: record.loai },
  });
  await Promise.allSettled((subs || []).map((s: any) =>
    webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload)
  ));
  return new Response("ok", { status: 200 });
});
```

Deploy:
```
supabase functions deploy send-push --no-verify-jwt
supabase secrets set VAPID_PUBLIC=... VAPID_PRIVATE=...
```
(SUPABASE_URL và SUPABASE_SERVICE_ROLE_KEY thường có sẵn trong môi trường function.)

### 4. Kích hoạt gửi tự động khi có thông báo
Supabase Dashboard → **Database → Webhooks → Create**:
- Table: `notifications`, Events: **Insert**
- Type: **Supabase Edge Function** → chọn `send-push`.

Từ đó, mỗi khi hệ thống tạo 1 thông báo, Edge Function gửi push tới đúng người — **kể cả khi họ đã đóng app**.

## Ghi chú
- iPhone: chỉ nhận push khi app đã **"Thêm vào MH chính"** (cài như PWA) và mở ít nhất 1 lần để cho phép.
- Nếu không muốn push thật, cứ để trống `vapidPublicKey` — app vẫn dùng thông báo hệ thống nội bộ (mức 1).
