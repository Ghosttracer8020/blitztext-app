// HTTP surface of the hub. Only reachable through tailscale serve, which sets
// Tailscale-User-Login; without it everything but /api/health answers 401.

import { Hono } from 'hono';
import { readLogin } from './identity.js';
import { installScript, missingReleaseScript } from './install.js';
import { hasLatestZip, resolveUpdateFile, streamFile } from './updates.js';

export interface AppDeps {
  updatesDir: string;
  hubVersion: string;
  /** Public https URL of the hub as seen by clients (used in install.sh). */
  hubURL: string;
}

export function createApp(deps: AppDeps): Hono {
  const app = new Hono();

  app.use('*', async (c, next) => {
    await next();
    const h = c.res.headers;
    h.set('X-Content-Type-Options', 'nosniff');
    h.set('Referrer-Policy', 'no-referrer');
    if (!h.has('Cache-Control')) h.set('Cache-Control', 'no-store');
  });

  app.get('/api/health', (c) => c.json({ ok: true, version: deps.hubVersion }));

  // Identity gate for everything else.
  app.use('*', async (c, next) => {
    if (c.req.path === '/api/health') return next();
    if (readLogin((n) => c.req.header(n)) === null) return c.json({ error: 'unauthenticated' }, 401);
    return next();
  });

  app.get('/install.sh', (c) => {
    c.header('Content-Type', 'text/x-shellscript; charset=utf-8');
    return c.body(hasLatestZip(deps.updatesDir) ? installScript(deps.hubURL) : missingReleaseScript());
  });

  app.get('/updates/*', (c) => {
    const name = new URL(c.req.url).pathname.slice('/updates/'.length);
    if (name === '' || name.includes('/')) return c.json({ error: 'not_found' }, 404);
    const file = resolveUpdateFile(deps.updatesDir, name);
    if (!file) return c.json({ error: 'not_found' }, 404);
    return streamFile(c.req.method, file);
  });

  app.notFound((c) => c.json({ error: 'not_found' }, 404));
  app.onError((err, c) => {
    console.error(`${new Date().toISOString()} [hub] ERROR ${c.req.method} ${c.req.path}: ${err.message}`);
    return c.json({ error: 'internal' }, 500);
  });

  return app;
}
