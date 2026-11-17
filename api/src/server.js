import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { timingSafeEqual } from 'node:crypto';
import { loadCatalog, publicCatalog, findTarget, visibleReleases, downloadPath } from './catalog.js';
import { bucketConfig, createStorage } from './storage.js';
import { normalizeBatch, isInstallId, createJsonlStore, createPgStore, computeStats } from './events.js';
import { compare } from './semver.js';
import { verifyStripeSignature, applyEvent, subscriberRows, billingOverview, createMemoryBillingStore, createPgBillingStore } from './billing.js';

const here = dirname(fileURLToPath(import.meta.url));
const ADMIN_HTML = readFileSync(join(here, 'admin.html'), 'utf8');

/** Builds the request handler. Exported so tests can run it without a network or a bucket. */
export function createApp({ catalog, storage = null, events, billing = createMemoryBillingStore(), stripeWebhookSecret = null, adminToken = null, publicBaseUrl = null }) {
  const views = { stable: publicCatalog(catalog, { channel: 'stable' }), beta: publicCatalog(catalog, { channel: 'beta' }) };
  const limiter = rateLimiter({ perMinute: 120 });

  const send = (res, status, body, headers = {}) => {
    const isJson = typeof body !== 'string';
    res.writeHead(status, {
      'content-type': isJson ? 'application/json; charset=utf-8' : 'text/html; charset=utf-8',
      'access-control-allow-origin': '*',
      'x-content-type-options': 'nosniff',
      ...headers,
    });
    res.end(status === 204 || status === 304 ? undefined : isJson ? JSON.stringify(body) : body);
  };
  const baseUrl = (req) => publicBaseUrl ?? `${req.headers['x-forwarded-proto'] ?? 'http'}://${req.headers.host}`;
  const isAdmin = (req) => {
    if (!adminToken) return false;
    const got = Buffer.from((req.headers.authorization ?? '').replace(/^Bearer\s+/i, ''));
    const want = Buffer.from(adminToken);
    return got.length === want.length && timingSafeEqual(got, want);
  };
  const record = (rows) => events.insert(rows).catch((err) => console.error('event store failed:', err.message));

  return async function handle(req, res) {
    try {
      const url = new URL(req.url, 'http://x');
      const path = url.pathname.replace(/\/+$/, '') || '/';
      if (req.method === 'OPTIONS') {
        return send(res, 204, null, { 'access-control-allow-methods': 'GET, POST', 'access-control-allow-headers': 'content-type, authorization, x-line21-install-id' });
      }

      if (req.method === 'GET' && path === '/healthz') {
        return send(res, 200, { ok: true, products: catalog.products.length, bucket: !!storage, events: events.kind, billing: billing.kind, stripe: !!stripeWebhookSecret });
      }

      if (req.method === 'GET' && path === '/v1/catalog') {
        const view = url.searchParams.get('channel') === 'beta' ? views.beta : views.stable;
        if (req.headers['if-none-match'] === view.etag) return send(res, 304, null, { etag: view.etag });
        return send(res, 200, view.body, { etag: view.etag, 'cache-control': 'public, max-age=60' });
      }

      let m;
      if (req.method === 'GET' && (m = /^\/v1\/targets\/([a-z0-9-]+)$/.exec(path))) {
        const view = url.searchParams.get('channel') === 'beta' ? views.beta : views.stable;
        for (const p of view.body.products) for (const t of p.targets) if (t.id === m[1]) return send(res, 200, { product: { id: p.id, name: p.name }, ...t });
        return send(res, 404, { error: 'unknown target' });
      }

      if (req.method === 'GET' && (m = /^\/v1\/icons\/([a-z0-9-]+\.png)$/.exec(path))) {
        const png = catalog.icons?.[m[1]];
        if (!png) return send(res, 404, { error: 'unknown icon' });
        res.writeHead(200, { 'content-type': 'image/png', 'content-length': png.length, 'cache-control': 'public, max-age=86400' });
        return res.end(png);
      }

      // Permanent "latest version" link for a website button: /download/line21-hub-macos.
      if (req.method === 'GET' && (m = /^\/download\/([a-z0-9-]+)$/.exec(path))) {
        const found = findTarget(catalog, m[1]);
        const release = found && visibleReleases(found.target, 'stable').find((r) => r.artifacts?.some((a) => a.platform === 'macos'));
        const artifact = release?.artifacts.find((a) => a.platform === 'macos' && a.arch === 'universal') ?? release?.artifacts.find((a) => a.platform === 'macos');
        if (!artifact) return send(res, 404, { error: 'nothing to download yet' });
        const to = downloadPath(m[1], release.version, artifact);
        return send(res, 302, { url: to }, { location: to, 'cache-control': 'no-store' });
      }

      // Time-limited link to the installer in the private bucket. Counted as a download.
      if (req.method === 'GET' && (m = /^\/v1\/download\/([a-z0-9-]+)\/([^/]+)\/([a-z0-9]+)-([a-z0-9_]+)$/.exec(path))) {
        const [, targetId, version, platform, arch] = m.map(decodeURIComponent);
        const found = findTarget(catalog, targetId);
        const release = found?.target.releases?.find((r) => r.version === version && r.status !== 'withdrawn');
        const artifact = release?.artifacts?.find((a) => a.platform === platform && a.arch === arch);
        if (!artifact) return send(res, 404, { error: 'unknown artifact' });
        if (!storage) return send(res, 503, { error: 'downloads are not configured (no bucket)' });
        if (!limiter(req)) return send(res, 429, { error: 'slow down' });
        const installId = req.headers['x-line21-install-id'] ?? url.searchParams.get('install');
        record([{
          ts: new Date().toISOString(), type: 'download', installId: isInstallId(installId) ? installId.toLowerCase() : null,
          targetId, fromVersion: url.searchParams.get('from'), toVersion: version, hubVersion: null, os: null, arch,
          error: null, data: { via: isInstallId(installId) ? 'hub' : 'link' },
        }]);
        const signed = await storage.presign(artifact.key, artifact.key.split('/').pop());
        const expiresAt = new Date(Date.now() + storage.ttlSeconds * 1000).toISOString();
        if (url.searchParams.get('format') === 'json') return send(res, 200, { url: signed, expiresAt, size: artifact.size, sha256: artifact.sha256 });
        return send(res, 302, { url: signed, expiresAt }, { location: signed, 'cache-control': 'no-store' });
      }

      // Tauri updater endpoint: {{target}}/{{arch}}/{{current_version}}. PROXEL points its updater here.
      if (req.method === 'GET' && (m = /^\/v1\/tauri\/([a-z0-9-]+)\/(darwin|windows|linux)\/([a-z0-9_]+)\/([^/]+)$/.exec(path))) {
        const [, targetId, os, tauriArch, current] = m.map(decodeURIComponent);
        const found = findTarget(catalog, targetId);
        if (!found || found.target.kind !== 'tauri-app') return send(res, 404, { error: 'unknown tauri target' });
        const platform = { darwin: 'macos', windows: 'windows', linux: 'linux' }[os];
        const arch = { aarch64: 'arm64', x86_64: 'x64', i686: 'x86', armv7: 'armv7' }[tauriArch] ?? tauriArch;
        const channel = url.searchParams.get('channel') === 'beta' ? 'beta' : 'stable';
        for (const r of visibleReleases(found.target, channel)) {
          let newer;
          try { newer = compare(r.version, current) > 0; } catch { return send(res, 400, { error: 'bad current_version' }); }
          if (!newer) break;
          const a = r.artifacts?.find((x) => x.platform === platform && (x.arch === arch || x.arch === 'universal'));
          if (!a) continue;
          return send(res, 200, {
            version: r.version,
            notes: r.notes ?? '',
            pub_date: `${r.date}T00:00:00Z`,
            url: `${baseUrl(req)}/v1/download/${targetId}/${encodeURIComponent(r.version)}/${a.platform}-${a.arch}?from=${encodeURIComponent(current)}`,
            signature: a.tauriSignature,
          });
        }
        return send(res, 204, null);
      }

      if (req.method === 'POST' && path === '/v1/events') {
        if (!limiter(req)) return send(res, 429, { error: 'slow down' });
        const body = await readJson(req, 32 * 1024);
        let rows;
        try { rows = normalizeBatch(body); } catch (err) { return send(res, 400, { error: err.message }); }
        await record(rows);
        return send(res, 202, { accepted: rows.length });
      }

      if (req.method === 'GET' && path === '/admin') return send(res, 200, ADMIN_HTML, { 'cache-control': 'no-store' });

      if (req.method === 'GET' && path === '/v1/admin/stats') {
        if (!isAdmin(req)) return send(res, 401, { error: 'admin token required' });
        const days = Math.min(Math.max(parseInt(url.searchParams.get('days') ?? '30', 10) || 30, 1), 365);
        const rows = await events.since(new Date(Date.now() - days * 864e5).toISOString());
        const latest = Object.fromEntries([
          ...Object.entries(catalog.hosts).map(([id, h]) => [id, { label: h.name, latest: null }]),
          ...views.stable.body.products.flatMap((p) => p.targets.map((t) => [t.id, { label: t.label, latest: t.latest }])),
        ]);
        return send(res, 200, { ...computeStats(rows, { days }), targets: latest }, { 'cache-control': 'no-store' });
      }

      // Stripe webhooks: subscriptions, customers and invoices. Signed with STRIPE_WEBHOOK_SECRET.
      if (req.method === 'POST' && path === '/v1/webhooks/stripe') {
        if (!stripeWebhookSecret) return send(res, 503, { error: 'stripe webhooks are not configured' });
        const raw = await readBody(req, 1024 * 1024);
        if (!verifyStripeSignature(raw, req.headers['stripe-signature'], stripeWebhookSecret)) return send(res, 400, { error: 'bad signature' });
        let event;
        try { event = JSON.parse(raw.toString('utf8')); } catch { return send(res, 400, { error: 'invalid JSON' }); }
        if (!event?.id || !event?.type) return send(res, 400, { error: 'not a stripe event' });
        const fresh = await applyEvent(billing, event);
        return send(res, 200, { received: true, duplicate: !fresh });
      }

      if (req.method === 'GET' && path.startsWith('/v1/admin/billing')) {
        if (!isAdmin(req)) return send(res, 401, { error: 'admin token required' });
        if (path === '/v1/admin/billing/overview') {
          const [subscriptions, invoices] = await Promise.all([billing.all('subscriptions'), billing.all('invoices')]);
          return send(res, 200, billingOverview(subscriptions, invoices), { 'cache-control': 'no-store' });
        }
        if (path === '/v1/admin/billing/subscribers') {
          const [customers, subscriptions] = await Promise.all([billing.all('customers'), billing.all('subscriptions')]);
          const rows = subscriberRows(customers, subscriptions, { q: url.searchParams.get('q') ?? '', status: url.searchParams.get('status') ?? '' });
          return send(res, 200, { subscribers: rows }, { 'cache-control': 'no-store' });
        }
        if ((m = /^\/v1\/admin\/billing\/subscribers\/([A-Za-z0-9_]+)$/.exec(path))) {
          const [customer, subscriptions, invoices] = await Promise.all([
            billing.get('customers', m[1]), billing.where('subscriptions', 'customerId', m[1]), billing.where('invoices', 'customerId', m[1]),
          ]);
          if (!customer && !subscriptions.length) return send(res, 404, { error: 'unknown customer' });
          const byDate = (a, b) => (b.createdAt ?? '').localeCompare(a.createdAt ?? '');
          return send(res, 200, {
            customer: customer ?? { id: m[1] }, subscriptions: subscriptions.sort(byDate), invoices: invoices.sort(byDate),
          }, { 'cache-control': 'no-store' });
        }
        return send(res, 404, { error: 'not found' });
      }

      return send(res, 404, { error: 'not found' });
    } catch (err) {
      if (err.status) return send(res, err.status, { error: err.message });
      console.error(err);
      return send(res, 500, { error: 'internal error' });
    }
  };
}

function readBody(req, limit) {
  return new Promise((resolveBody, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(Object.assign(new Error('body too large'), { status: 413 }));
        req.destroy();
      } else chunks.push(c);
    });
    req.on('end', () => resolveBody(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function readJson(req, limit) {
  return new Promise((resolveBody, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(Object.assign(new Error('body too large'), { status: 413 }));
        req.destroy();
      } else chunks.push(c);
    });
    req.on('end', () => {
      try { resolveBody(JSON.parse(Buffer.concat(chunks).toString('utf8') || 'null')); } catch { reject(Object.assign(new Error('invalid JSON'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}

/** Per-client token bucket kept in memory. The client key is never stored. */
function rateLimiter({ perMinute }) {
  const buckets = new Map();
  return (req) => {
    const key = (req.headers['x-forwarded-for'] ?? req.socket.remoteAddress ?? '').split(',')[0].trim();
    const now = Date.now();
    const b = buckets.get(key) ?? { tokens: perMinute, at: now };
    b.tokens = Math.min(perMinute, b.tokens + ((now - b.at) / 60000) * perMinute);
    b.at = now;
    if (buckets.size > 10000) buckets.clear();
    buckets.set(key, b);
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
  };
}

async function main() {
  const catalogDir = resolve(process.env.CATALOG_DIR ?? join(here, '../../catalog'));
  const catalog = loadCatalog(catalogDir);
  const storage = createStorage(bucketConfig(), { ttlSeconds: parseInt(process.env.DOWNLOAD_TTL_SECONDS ?? '600', 10) });
  const events = process.env.DATABASE_URL
    ? await createPgStore(process.env.DATABASE_URL)
    : createJsonlStore(process.env.EVENTS_FILE ?? join(here, '../../data/events.jsonl'));
  let billing = createMemoryBillingStore();
  if (process.env.DATABASE_URL) {
    const { default: pg } = await import('pg');
    billing = await createPgBillingStore(new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 4 }));
  } else console.warn('DATABASE_URL is not set: subscribers are kept in memory only.');
  if (!process.env.ADMIN_TOKEN) console.warn('ADMIN_TOKEN is not set: the stats page is locked.');
  const app = createApp({ catalog, storage, events, billing, stripeWebhookSecret: process.env.STRIPE_WEBHOOK_SECRET ?? null, adminToken: process.env.ADMIN_TOKEN ?? null, publicBaseUrl: process.env.PUBLIC_BASE_URL ?? null });
  const port = parseInt(process.env.PORT ?? '8080', 10);
  createServer(app).listen(port, () => {
    console.log(`LINE21 catalog on :${port} · ${catalog.products.length} products · bucket ${storage ? 'on' : 'off'} · events ${events.kind}`);
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
