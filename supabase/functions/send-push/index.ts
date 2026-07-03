// Edge Function: gửi Web Push khi có 1 dòng notifications mới.
// Kích hoạt bằng Database Webhook (Database → Webhooks → Insert on `notifications`).
// Secrets cần đặt: VAPID_PUBLIC, VAPID_PRIVATE (SUPABASE_URL & SUPABASE_SERVICE_ROLE_KEY có sẵn).
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC")!;
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

webpush.setVapidDetails("mailto:admin@thiennhatgroup.com", VAPID_PUBLIC, VAPID_PRIVATE);

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const record = payload?.record ?? payload; // Database Webhook gửi { record }
    const toUser = record?.to_user;
    if (!toUser) return new Response("no recipient", { status: 200 });

    const r = await fetch(
      `${SUPABASE_URL}/rest/v1/push_subscriptions?user_id=eq.${toUser}&select=endpoint,p256dh,auth`,
      { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } },
    );
    const subs = await r.json();
    if (!Array.isArray(subs) || subs.length === 0) return new Response("no subs", { status: 200 });

    const body = JSON.stringify({
      title: record.tieu_de || "Thông báo Thiên Nhật",
      body: record.noi_dung || "",
      tag: "tn-" + (record.id || ""),
      data: { screen: record.man_hinh, refId: record.ref_id, loai: record.loai, id: record.id },
    });

    await Promise.allSettled(
      subs.map((s: any) =>
        webpush
          .sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, body)
          .catch(async (err: any) => {
            // Dọn subscription đã hết hạn (410/404)
            if (err?.statusCode === 410 || err?.statusCode === 404) {
              await fetch(`${SUPABASE_URL}/rest/v1/push_subscriptions?endpoint=eq.${encodeURIComponent(s.endpoint)}`, {
                method: "DELETE",
                headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
              });
            }
          }),
      ),
    );
    return new Response("ok", { status: 200 });
  } catch (e) {
    return new Response("err: " + (e as Error).message, { status: 200 });
  }
});
