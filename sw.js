// Lytmoz app helper: makes the Client HQ and HQ open fast and survive weak data.
// Pages: network first, saved copy if offline. Static files: saved copy first.
// Database and login requests are never stored.
const CACHE = 'lytmoz-app-v18';
const SHELL = ['/portal.html', '/admin.html', '/config.js?v=4', '/assets/api.js?v=3', '/assets/chat.js?v=1', '/assets/app.css?v=21',
  '/assets/favicon.svg', '/assets/icon-192.png', '/assets/hq-192.png', '/offline.html'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co') || url.hostname.includes('formsubmit')) return; // live data only
  const isPage = req.mode === 'navigate';
  const isStatic = url.origin === location.origin || url.hostname === 'cdn.jsdelivr.net' || url.hostname.includes('fonts.g');
  if (!isStatic) return;
  if (isPage) {
    e.respondWith(fetch(req).then((res) => {
      const copy = res.clone(); caches.open(CACHE).then((c) => c.put(url.pathname, copy)); return res;
    }).catch(() => caches.match(url.pathname).then((r) => r || caches.match('/offline.html'))));
    return;
  }
  e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => {
    if (res.ok || res.type === 'opaque') { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
    return res;
  })));
});
