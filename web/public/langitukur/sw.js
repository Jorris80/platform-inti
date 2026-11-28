/* LangitUkur edisi Supabase — service worker (PWA & offline). Versi cache berubah otomatis tiap build. */
const V = 'lus-1.2.1-a2e4f14f', SHELL = ['./', './index.html', './supabase.js', './config.js', './manifest.json', './icon.png'];
const RUNTIME = 'lus-rt', TILES = 'lus-tiles', MAX_TILES = 2000;
self.addEventListener('install', e => { e.waitUntil(caches.open(V).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k.startsWith('lus-') && ![V, RUNTIME, TILES].includes(k)).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
async function trim(name, max) { const c = await caches.open(name), k = await c.keys(); for (let i = 0; i < k.length - max; i++) await c.delete(k[i]); }
function put(name, req, res) { if (res && (res.ok || res.type === 'opaque')) { const cl = res.clone(); caches.open(name).then(c => c.put(req, cl)); } return res; }
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET') return;                                              // simpan/kirim data selalu ke jaringan
  if (/\/(rest|auth|storage|functions|realtime|graphql)\/v1\//.test(u.pathname)) return;   // Supabase: data tidak pernah disimpan di cache
  if (r.mode === 'navigate') { e.respondWith(fetch(r).then(res => put(V, './index.html', res)).catch(() => caches.match('./index.html', { ignoreSearch: true }))); return; }
  if (u.origin === location.origin && /\/config\.js$/.test(u.pathname)) { e.respondWith(fetch(r).then(res => put(V, r, res)).catch(() => caches.match(r, { ignoreSearch: true }))); return; }
  const tile = /tile\.openstreetmap\.org|arcgisonline\.com|tile\.opentopomap\.org|google\.com\/vt/.test(u.hostname + u.pathname);
  if (tile) { e.respondWith(caches.open(TILES).then(c => c.match(r).then(hit => hit || fetch(r).then(res => { if (res.ok || res.type === 'opaque') { c.put(r, res.clone()); trim(TILES, MAX_TILES); } return res; })))); return; }
  if (/unpkg\.com|jsdelivr\.net|fonts\.(googleapis|gstatic)\.com/.test(u.hostname) || u.origin === location.origin) {
    e.respondWith(caches.match(r, { ignoreSearch: u.origin === location.origin }).then(hit => { const net = fetch(r).then(res => put(u.origin === location.origin ? V : RUNTIME, r, res)).catch(() => hit); return hit || net; }));
  }
});
