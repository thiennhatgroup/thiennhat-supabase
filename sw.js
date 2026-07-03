/* Service worker cho PWA Thiên Nhật.
   Chiến lược: NETWORK-FIRST (luôn ưu tiên bản mới nhất khi có mạng, để deploy
   mới hiện ngay), chỉ dùng cache khi mất mạng. Không cache lời gọi Supabase. */
const CACHE = 'tn-muahang-v1';
const SHELL = ['./', './index.html', './config.js', './logo.png',
  './icon-192.png', './icon-512.png', './manifest.webmanifest'];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL).catch(() => {})));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;                       // bỏ qua POST (RPC ghi)
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;             // KHÔNG can thiệp Supabase / CDN
  e.respondWith(
    fetch(req)
      .then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(req).then(r => r || caches.match('./index.html')))
  );
});

// ---- Web Push (khi có VAPID/Edge Function) — nhận đẩy kể cả app đóng --------
self.addEventListener('push', event => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (_) { d = { title: 'Thông báo', body: event.data ? event.data.text() : '' }; }
  event.waitUntil(self.registration.showNotification(d.title || 'Thông báo Thiên Nhật', {
    body: d.body || '', tag: d.tag || undefined, data: d.data || {}, icon: './icon-192.png', badge: './icon-192.png'
  }));
});

// ---- Bấm vào thông báo -> focus app + điều hướng --------------------------
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const data = event.notification.data || {};
  event.waitUntil((async () => {
    const all = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) { if ('focus' in c) { await c.focus(); c.postMessage({ type: 'notif-click', data }); return; } }
    if (clients.openWindow) await clients.openWindow('./#' + (data.screen || ''));
  })());
});
