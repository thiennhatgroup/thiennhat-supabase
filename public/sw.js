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
