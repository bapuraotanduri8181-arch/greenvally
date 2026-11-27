// Green Valley CRM – minimal service worker so phones can install the app.
// Always loads fresh from the network (no stale copies); data stays in Supabase.
self.addEventListener('install', e => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {});
