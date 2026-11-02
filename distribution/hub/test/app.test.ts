import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { installScript } from '../src/install.js';

const HUB = 'https://hub.example.invalid:8452';
const AUTH = { 'Tailscale-User-Login': 'someone@example.invalid' };
let root: string;
let updates: string;

function app() {
  return createApp({ updatesDir: updates, hubVersion: 'test', hubURL: HUB });
}

beforeEach(() => {
  root = mkdtempSync(path.join(os.tmpdir(), 'ultradic-hub-'));
  updates = path.join(root, 'updates');
  mkdirSync(updates);
  writeFileSync(path.join(updates, 'appcast.xml'), '<rss/>');
  writeFileSync(path.join(updates, 'latest.zip'), 'ZIPDATA');
  writeFileSync(path.join(updates, 'UltraDic-1.0.0.zip'), 'ZIPDATA');
  writeFileSync(path.join(root, 'secret.zip'), 'SECRET');
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

describe('identity gate', () => {
  it('health is open', async () => {
    const res = await app().request('/api/health');
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, version: 'test' });
  });

  it.each(['/install.sh', '/updates/appcast.xml', '/updates/latest.zip', '/nope'])('%s answers 401 without header', async (p) => {
    expect((await app().request(p)).status).toBe(401);
  });

  it('blank login header is 401', async () => {
    expect((await app().request('/install.sh', { headers: { 'Tailscale-User-Login': '   ' } })).status).toBe(401);
  });

  it('any login passes (no allowlist)', async () => {
    expect((await app().request('/updates/appcast.xml', { headers: AUTH })).status).toBe(200);
  });
});

describe('updates', () => {
  it('serves feed and archives with types', async () => {
    const feed = await app().request('/updates/appcast.xml', { headers: AUTH });
    expect(feed.headers.get('content-type')).toContain('application/xml');
    expect(await feed.text()).toBe('<rss/>');
    const zip = await app().request('/updates/UltraDic-1.0.0.zip', { headers: AUTH });
    expect(zip.headers.get('content-type')).toBe('application/zip');
    expect(await zip.text()).toBe('ZIPDATA');
    expect(zip.headers.get('x-content-type-options')).toBe('nosniff');
  });

  it('HEAD has no body', async () => {
    const res = await app().request('/updates/latest.zip', { method: 'HEAD', headers: AUTH });
    expect(res.status).toBe(200);
    expect(res.headers.get('content-length')).toBe('7');
  });

  it.each([
    '/updates/../secret.zip',
    '/updates/%2e%2e/secret.zip',
    '/updates/..%2fsecret.zip',
    '/updates/%2e%2e%2fsecret.zip',
    '/updates/sub/latest.zip',
    '/updates/',
    '/updates/missing.zip',
    '/updates/appcast.txt',
    '/updates/%00.zip',
    '/updates/%ZZ.zip',
    '/updates/..\\secret.zip',
  ])('rejects %s', async (p) => {
    const res = await app().request(p, { headers: AUTH });
    expect(res.status).toBe(404);
    expect(await res.text()).not.toContain('SECRET');
  });

  it('does not follow a symlink out of the directory', async () => {
    symlinkSync(path.join(root, 'secret.zip'), path.join(updates, 'evil.zip'));
    const res = await app().request('/updates/evil.zip', { headers: AUTH });
    expect(res.status).toBe(404);
  });
});

describe('install.sh', () => {
  it('is the real installer when latest.zip exists', async () => {
    const res = await app().request('/install.sh', { headers: AUTH });
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toBe(installScript(HUB));
    expect(body).toContain(`HUB='${HUB}'`);
    expect(body).toContain('$HUB/updates/latest.zip');
    expect(body).toContain('ditto');
    expect(body).toContain('UltraDic.app');
    expect(body).toContain('xattr -dr com.apple.quarantine');
    expect(body).toContain('open "$ZIEL"');
    expect(body).toContain('Mikrofon');
    expect(body).toContain('Bedienungshilfen');
    expect(body).toContain('OpenAI');
    expect(body).toContain('Anthropic');
    expect(body).toContain('Dein Name');
  });

  it('is a failing explainer without latest.zip', async () => {
    rmSync(path.join(updates, 'latest.zip'));
    const body = await (await app().request('/install.sh', { headers: AUTH })).text();
    expect(body).toContain('exit 1');
    expect(body).not.toContain('ditto');
  });

  it('is syntactically valid bash', async () => {
    const { spawnSync } = await import('node:child_process');
    const f = path.join(root, 'install.sh');
    writeFileSync(f, installScript(HUB));
    expect(spawnSync('bash', ['-n', f]).status).toBe(0);
  });
});
