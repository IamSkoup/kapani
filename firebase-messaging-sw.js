/* Kapani Web Push Service Worker.
 * One Service Worker only: receives standard Web Push and renders system notifications.
 */
const SW_VERSION = 'kapani-pwa-2026-11-07-v29';
const KAPANI_APP_PATH = '/kapani/';
const KAPANI_STATIC_CACHE = 'kapani-static-v29';
const KAPANI_STATIC_PREFIX = 'kapani-static-';
const KAPANI_APP_SHELL = [
  './', './index.html', './config.js', './manifest.json',
  './assets/icon-192.png', './assets/icon-512.png',
  './assets/kapani-main-classic.js?v=29',
  './assets/supabase-bridge-classic.js?v=17&rev=27',
  './assets/kapani-v28.css?v=28',
  './assets/kapani-onboarding.js?v=29',
  './assets/kapani-onboarding.css?v=29'
];

function isPublicStaticRequest(request) {
  if (request.method !== 'GET') return false;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith(KAPANI_APP_PATH)) return false;
  // Never intercept Supabase, auth, Storage or cross-origin API requests.
  return request.mode === 'navigate' || /\.(?:html|js|css|webp|png|svg|json)$/i.test(url.pathname)
    || url.pathname === KAPANI_APP_PATH;
}

function resolveNotificationUrl(requestedUrl) {
  try {
    const raw = String(requestedUrl || '').trim();
    if (!raw) return new URL(KAPANI_APP_PATH, self.location.origin).href;
    const url = new URL(raw, self.location.origin);
    if (url.origin !== self.location.origin) return new URL(KAPANI_APP_PATH, self.location.origin).href;
    if (url.pathname === '/index.html') {
      const canonical = new URL(KAPANI_APP_PATH, self.location.origin);
      canonical.search = url.search; canonical.hash = url.hash; return canonical.href;
    }
    return url.href;
  } catch (_) { return new URL(KAPANI_APP_PATH, self.location.origin).href; }
}

const shownNotificationIds = new Map();
function pruneShown() {
  const now = Date.now();
  for (const [key, ts] of shownNotificationIds) if (now - ts > 120000) shownNotificationIds.delete(key);
}
/* Check only; the id is recorded AFTER showNotification() succeeds, so a failed
 * display can still be retried (e.g. by the server push for the same id). */
function wasShownRecently(notificationId) {
  const id = String(notificationId || '').trim(); if (!id) return false;
  pruneShown();
  return shownNotificationIds.has(id);
}

async function showKapaniPush(data = {}) {
  const notificationId = String(data.notificationId || '').trim();
  if (notificationId && wasShownRecently(notificationId)) return false;
  const body = String(data.body || data.text || '').trim(); if (!body) return false;
  const category = String(data.category || 'system');
  const title = String(data.title || 'Капани');
  const targetUrl = resolveNotificationUrl(data.url);
  await self.registration.showNotification(title, {
    body,
    icon: new URL('/kapani/image.png', self.location.origin).href,
    badge: new URL('/kapani/image.png', self.location.origin).href,
    tag: notificationId ? `kapani-${notificationId}` : `kapani-${category}-${Date.now()}`,
    renotify: false,
    data: { ...data, url: targetUrl, category, swVersion: SW_VERSION, receivedAt: Date.now() }
  });
  if (notificationId) shownNotificationIds.set(notificationId, Date.now());
  return true;
}

function isKapaniUrl(url) {
  try {
    const parsed = new URL(url, self.location.origin);
    return parsed.origin === self.location.origin && (
      parsed.pathname === KAPANI_APP_PATH ||
      parsed.pathname === KAPANI_APP_PATH.replace(/\/$/, '') ||
      parsed.pathname === '/index.html'
    );
  } catch (_) { return false; }
}

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(KAPANI_STATIC_CACHE);
    await Promise.allSettled(KAPANI_APP_SHELL.map(async path => {
      const request = new Request(new URL(path, self.registration.scope), {cache:'reload'});
      const response = await fetch(request);
      if (response.ok && response.type === 'basic') await cache.put(request, response);
    }));
    await self.skipWaiting();
  })());
});
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(key => key.startsWith(KAPANI_STATIC_PREFIX) && key !== KAPANI_STATIC_CACHE)
      .map(key => caches.delete(key)));
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', event => {
  if (!isPublicStaticRequest(event.request)) return;
  event.respondWith((async () => {
    try {
      const response = await fetch(event.request);
      if (response.ok && response.type === 'basic') {
        const cache = await caches.open(KAPANI_STATIC_CACHE);
        await cache.put(event.request, response.clone());
      }
      return response;
    } catch (error) {
      const cached = await caches.match(event.request);
      if (cached) return cached;
      if (event.request.mode === 'navigate') {
        const fallback = await caches.match(new URL('./', self.registration.scope).href);
        if (fallback) return fallback;
      }
      throw error;
    }
  })());
});

/* Foreground helper: the page may explicitly ask the same SW to display a
 * system notification, so there is no second display implementation. */
self.addEventListener('message', event => {
  if (event?.data?.type === 'KAPANI_FOREGROUND_PUSH') {
    event.waitUntil(showKapaniPush(event.data.payload || {}).catch(err => console.error('[Kapani SW] foreground push failed:', err)));
  }
});

/* Standard Web Push. This event is the critical closed-tab path. */
self.addEventListener('push', event => {
  event.waitUntil((async () => {
    let data = {};
    try { data = event.data ? event.data.json() : {}; }
    catch (_) {
      try { data = { body: event.data ? event.data.text() : '' }; } catch (_) { data = {}; }
    }
    await showKapaniPush(data);
  })().catch(err => console.error('[Kapani SW] push event failed:', err)));
});

/* Browser implementations may rotate subscriptions. The active page will
 * receive this signal and persist the new subscription server-side. */
self.addEventListener('pushsubscriptionchange', event => {
  event.waitUntil((async () => {
    try {
      const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (const client of clients) client.postMessage({ type: 'KAPANI_PUSHSUBSCRIPTION_CHANGED' });
    } catch (error) { console.warn('[Kapani SW] pushsubscriptionchange notification failed:', error); }
  })());
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const data = event.notification?.data || {};
  const targetUrl = resolveNotificationUrl(data.url);
  event.waitUntil((async () => {
    try {
      const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (const client of clients) {
        if (!client.url || !isKapaniUrl(client.url)) continue;
        /* The app is already open: focus it and let the page route in-app (no reload). */
        let routed = false;
        try { client.postMessage({ type: 'KAPANI_NOTIFICATION_CLICK', url: targetUrl }); routed = true; } catch (_) {}
        try { await client.focus(); } catch (_) {}
        if (!routed) { try { if ('navigate' in client) await client.navigate(targetUrl); } catch (_) {} }
        return client;
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
    } catch (error) {
      console.error('[Kapani SW] notification click failed:', error);
      try { if (self.clients.openWindow) return self.clients.openWindow(resolveNotificationUrl('')); } catch (_) {}
    }
    return undefined;
  })());
});
