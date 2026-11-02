// Entry point: HTTP server on top of DATA_DIR/updates.

import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { serve } from '@hono/node-server';
import { createApp } from './app.js';

const dataDir = process.env.DATA_DIR ?? './data';
const updatesDir = path.join(dataDir, 'updates');
mkdirSync(updatesDir, { recursive: true });

const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? '127.0.0.1';
const hubVersion = process.env.GIT_SHA ?? 'unknown';
const hubURL = process.env.HUB_URL ?? 'https://ugreen-nas.tail076274.ts.net:8452';

const app = createApp({ updatesDir, hubVersion, hubURL });
const server = serve({ fetch: app.fetch, hostname: host, port }, (info) => {
  console.log(`${new Date().toISOString()} [hub] UltraDic Hub ${hubVersion} lauscht auf ${info.address}:${info.port}`);
});

function shutdown(): void {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
