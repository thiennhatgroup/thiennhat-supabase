// Edge Function: gửi Web Push khi có 1 dòng notifications mới.
// Kích hoạt bởi trigger tg_push_on_notify().
// Secrets cần đặt: VAPID_PUBLIC, VAPID_PRIVATE, PUSH_WEBHOOK_SECRET
// (SUPABASE_URL & SUPABASE_SERVICE_ROLE_KEY có sẵn).
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC")!;
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PUSH_WEBHOOK_SECRET = Deno.env.get("PUSH_WEBHOOK_SECRET")?.trim() ?? "";
const SECRET_HEADER = "x-push-webhook-secret";

webpush.setVapidDetails("mailto:admin@thiennhatgroup.com", VAPID_PUBLIC, VAPID_PRIVATE);

function timingSafeEqual(a: string, b: string) {
  const encoder = new TextEncoder();
  const aBytes = encoder.encode(a);
  const bBytes = encoder.encode(b);
  let diff = aBytes.length ^ bBytes.length;
  const length = Math.max(aBytes.length, bBytes.length);

  for (let i = 0; i < length; i += 1) {
    diff |= (aBytes[i] ?? 0) ^ (bBytes[i] ?? 0);
  }

  return diff === 0;
}

Deno.serve(async (req) => {
  const requestSecret = req.headers.get(SECRET_HEADER)?.trim() ?? "";
  if (!PUSH_WEBHOOK_SECRET || !requestSecret || !timingSafeEqual(requestSecret, PUSH_WEBHOOK_SECRET)) {
    return new Response("unauthorized", { status: 401 });
  }

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
  } catch (_) {
    console.error("send-push failed");
    return new Response("err", { status: 200 });
  }
});
