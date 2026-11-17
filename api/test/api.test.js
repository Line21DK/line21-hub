import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { generateKeyPairSync, sign, verify, createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp } from '../src/server.js';
import { loadCatalog, validate } from '../src/catalog.js';
import { createJsonlStore, computeStats } from '../src/events.js';
import { compare } from '../src/semver.js';
import { signedMessage } from '../src/signing.js';

const repoCatalog = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'catalog');
const INSTALL = '5b0c6a2e-8f1d-4c3b-9a7e-2d4f6b8a0c1e';

function fixtureCatalog() {
  const dir = mkdtempSync(join(tmpdir(), 'l21cat-'));
  cpSync(repoCatalog, dir, { recursive: true });
  const sha = 'a'.repeat(64);
  const p = JSON.parse(JSON.stringify(loadCatalog(dir).products.find((x) => x.id === 'lineseparator')));
  delete p.__file;
  const t = p.targets[0];
  t.releases.push(
    { version: '0.4.0', channel: 'stable', date: '2026-12-01', notes: 'New', requires: { macos: '12.0' },
      artifacts: [{ platform: 'macos', arch: 'universal', key: 'k/0.4.0.zip', size: 10, sha256: sha, signature: 'sig' }] },
    { version: '0.5.0-beta.1', channel: 'beta', date: '2026-12-10', notes: 'Beta', artifacts: [] },
    { version: '0.3.5', channel: 'stable', status: 'withdrawn', date: '2026-11-20', notes: 'Withdrawn', artifacts: [] },
  );
  writeFileSync(join(dir, 'products', 'lineseparator.json'), JSON.stringify(p));
  mkdirSync(join(dir, 'products'), { recursive: true });
  writeFileSync(join(dir, 'products', 'proxel.json'), JSON.stringify({
    id: 'proxel', name: 'PROXEL', targets: [{ id: 'proxel-macos', kind: 'tauri-app', platform: 'macos', releases: [
      { version: '1.2.0', channel: 'stable', date: '2026-12-01', notes: 'Hurtigere', artifacts: [
        { platform: 'macos', arch: 'arm64', key: 'proxel/1.2.0.tar.gz', size: 5, sha256: sha, signature: 's', tauriSignature: 'TAURISIG' }] }] }],
  }));
  return loadCatalog(dir);
}

async function serve(opts) {
  const events = createJsonlStore(join(mkdtempSync(join(tmpdir(), 'l21ev-')), 'events.jsonl'));
  const storage = { bucket: 'b', ttlSeconds: 600, presign: async (key) => `https://bucket.example/${key}?sig=1` };
  const server = createServer(createApp({ catalog: fixtureCatalog(), storage, events, adminToken: 'secret', ...opts }));
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  return { base, events, close: () => server.close() };
}

test('semver ordering', () => {
  assert.equal(compare('0.10.0', '0.9.9'), 1);
  assert.equal(compare('1.0.0-beta.2', '1.0.0'), -1);
  assert.equal(compare('1.0.0-beta.10', '1.0.0-beta.2'), 1);
  assert.equal(compare('v1.2', '1.2.0'), 0);
});

test('repo catalog is valid', () => {
  assert.deepEqual(validate(loadCatalog(repoCatalog)), []);
});

test('validation catches broken entries', () => {
  const c = fixtureCatalog();
  c.products[0].targets[0].releases[0].artifacts = [{ platform: 'macos', arch: 'universal', key: 'x', size: 1, sha256: 'nope' }];
  const errors = validate(c);
  assert.ok(errors.some((e) => e.includes('sha256')));
  assert.ok(errors.some((e) => e.includes('signature')));
});

test('catalog: newest first, hides withdrawn and beta by default, supports etag', async () => {
  const s = await serve();
  const res = await fetch(`${s.base}/v1/catalog`);
  const body = await res.json();
  const t = body.products.flatMap((p) => p.targets).find((x) => x.id === 'lineseparator-ofx-macos');
  assert.equal(t.latest, '0.4.0');
  assert.deepEqual(t.releases.map((r) => r.version), ['0.4.0', '0.3.0']);
  assert.deepEqual(t.withdrawn, ['0.3.5']);
  assert.equal(t.releases[0].artifacts[0].download, '/v1/download/lineseparator-ofx-macos/0.4.0/macos-universal');
  assert.equal(t.releases[0].artifacts[0].key, undefined, 'bucket keys stay private');
  const again = await fetch(`${s.base}/v1/catalog`, { headers: { 'if-none-match': res.headers.get('etag') } });
  assert.equal(again.status, 304);
  const beta = await (await fetch(`${s.base}/v1/catalog?channel=beta`)).json();
  assert.equal(beta.products.flatMap((p) => p.targets).find((x) => x.id === 'lineseparator-ofx-macos').latest, '0.5.0-beta.1');
  s.close();
});

test('download redirects to a presigned link and counts it', async () => {
  const s = await serve();
  const res = await fetch(`${s.base}/v1/download/lineseparator-ofx-macos/0.4.0/macos-universal?from=0.3.0`, { redirect: 'manual', headers: { 'x-line21-install-id': INSTALL } });
  assert.equal(res.status, 302);
  assert.match(res.headers.get('location'), /^https:\/\/bucket\.example\/k\/0\.4\.0\.zip/);
  assert.equal((await fetch(`${s.base}/v1/download/lineseparator-ofx-macos/0.3.5/macos-universal`, { redirect: 'manual' })).status, 404);
  await new Promise((r) => setTimeout(r, 20));
  const rows = await s.events.since('2000-01-01');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].type, 'download');
  assert.equal(rows[0].installId, INSTALL);
  assert.equal(rows[0].fromVersion, '0.3.0');
  s.close();
});

test('product icons are listed in the catalog and served as png', async () => {
  const s = await serve();
  const cat = await (await fetch(`${s.base}/v1/catalog`)).json();
  const ls = cat.products.find((p) => p.id === 'lineseparator');
  assert.equal(ls.icon, '/v1/icons/lineseparator.png');
  const res = await fetch(`${s.base}${ls.icon}`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'image/png');
  assert.equal((await fetch(`${s.base}/v1/icons/nope.png`)).status, 404);
  s.close();
});

test('/download/:target points at the newest stable package, skipping beta and withdrawn', async () => {
  const s = await serve();
  const res = await fetch(`${s.base}/download/lineseparator-ofx-macos`, { redirect: 'manual' });
  assert.equal(res.status, 302);
  assert.equal(res.headers.get('location'), '/v1/download/lineseparator-ofx-macos/0.4.0/macos-universal');
  assert.equal((await fetch(`${s.base}/download/line21-hub-macos`, { redirect: 'manual' })).status, 404);
  assert.equal((await fetch(`${s.base}/download/nope`, { redirect: 'manual' })).status, 404);
  s.close();
});

test('tauri endpoint answers 200 with an update and 204 without', async () => {
  const s = await serve({ publicBaseUrl: 'https://hub.line21.dk' });
  const res = await fetch(`${s.base}/v1/tauri/proxel-macos/darwin/aarch64/1.1.0`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.version, '1.2.0');
  assert.equal(body.signature, 'TAURISIG');
  assert.equal(body.url, 'https://hub.line21.dk/v1/download/proxel-macos/1.2.0/macos-arm64?from=1.1.0');
  assert.equal((await fetch(`${s.base}/v1/tauri/proxel-macos/darwin/aarch64/1.2.0`)).status, 204);
  assert.equal((await fetch(`${s.base}/v1/tauri/proxel-macos/darwin/x86_64/1.0.0`)).status, 204);
  s.close();
});

test('events are validated, stored and summarised behind the admin token', async () => {
  const s = await serve();
  const post = (body) => fetch(`${s.base}/v1/events`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  assert.equal((await post({ installId: 'nope', events: [{ type: 'check' }] })).status, 400);
  assert.equal((await post({ installId: INSTALL, events: [{ type: 'hack' }] })).status, 400);
  const ok = await post({ installId: INSTALL, hubVersion: '0.1.0', os: '15.1', arch: 'arm64', events: [
    { type: 'check', data: { installed: { 'lineseparator-ofx-macos': '0.3.0', 'floatblur-ofx-macos': null }, hosts: { 'davinci-resolve': '20.2' } } },
    { type: 'install_ok', targetId: 'lineseparator-ofx-macos', fromVersion: '0.3.0', toVersion: '0.4.0' },
    { type: 'install_fail', targetId: 'floatblur-ofx-macos', toVersion: '0.2.0', error: 'admin_cancelled' },
  ] });
  assert.equal(ok.status, 202);
  assert.equal((await fetch(`${s.base}/v1/admin/stats`)).status, 401);
  const stats = await (await fetch(`${s.base}/v1/admin/stats?days=7`, { headers: { authorization: 'Bearer secret' } })).json();
  assert.equal(stats.activeInstalls, 1);
  assert.deepEqual(stats.installs, { 'lineseparator-ofx-macos': { '0.4.0': 1 } });
  assert.deepEqual(stats.failures, { 'floatblur-ofx-macos': { admin_cancelled: 1 } });
  assert.deepEqual(stats.installed['floatblur-ofx-macos'], { 'not installed': 1 });
  assert.deepEqual(stats.hostVersions, { 'davinci-resolve': { '20.2': 1 } });
  assert.equal(stats.targets['lineseparator-ofx-macos'].latest, '0.4.0');
  const html = await (await fetch(`${s.base}/admin`)).text();
  assert.match(html, /LINE21 Hub · Admin/);
  s.close();
});

test('signature message round-trips with Ed25519 (same bytes the Hub verifies)', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const sha256 = createHash('sha256').update('zip').digest('hex');
  const msg = Buffer.from(signedMessage({ targetId: 't', version: '1.0.0', platform: 'macos', arch: 'universal', sha256 }));
  const sig = sign(null, msg, privateKey);
  assert.equal(sig.length, 64);
  assert.ok(verify(null, msg, publicKey, sig));
  const other = Buffer.from(signedMessage({ targetId: 't', version: '1.0.1', platform: 'macos', arch: 'universal', sha256 }));
  assert.ok(!verify(null, other, publicKey, sig), 'a signature cannot be reused for another version');
});

test('computeStats counts daily active installs once', () => {
  const rows = [
    { ts: '2026-11-13T10:00:00Z', type: 'check', installId: INSTALL, data: {} },
    { ts: '2026-11-13T12:00:00Z', type: 'check', installId: INSTALL, data: {} },
  ];
  assert.deepEqual(computeStats(rows, { days: 1 }).daily, [{ day: '2026-11-13', active: 1, downloads: 0, installs: 0, failures: 0 }]);
});
