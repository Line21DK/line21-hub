import { createServer } from 'node:http';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { timingSafeEqual } from 'node:crypto';
import { verifyStripeSignature, applyEvent, subscriberRows, billingOverview, createMemoryBillingStore, createPgBillingStore } from './billing.js';

// LINE21 Control server: private to Brian. Receives Stripe webhooks, keeps subscribers in its own
// Postgres, and serves the LINE21 Control Mac app. It shares nothing with the public Hub API except
// that it can fetch the Hub's anonymous stats (with HUB_ADMIN_TOKEN) so the app needs one login.

/** Builds the request handler. Exported so tests can run it without a network. */
export function createApp({ billing = createMemoryBillingStore(), stripeWebhookSecret = null, controlToken = null, hub = null, fetchImpl = fetch }) {
  const send = (res, status, body, headers = {}) => {
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', ...headers });
    res.end(status === 204 ? undefined : JSON.stringify(body));
  };
  const authorized = (req) => {
    if (!controlToken) return false;
    const got = Buffer.from((req.headers.authorization ?? '').replace(/^Bearer\s+/i, ''));
    const want = Buffer.from(controlToken);
    return got.length === want.length && timingSafeEqual(got, want);
  };
  const failures = new Map();
  const limited = (req) => {
    // Slows down token guessing: 20 wrong tokens per address per 10 minutes.
    const key = (req.headers['x-forwarded-for'] ?? req.socket.remoteAddress ?? '').split(',')[0].trim();
    const f = failures.get(key);
    if (f && Date.now() - f.at > 600e3) failures.delete(key);
    return (failures.get(key)?.n ?? 0) >= 20;
  };
  const fail = (req) => {
    const key = (req.headers['x-forwarded-for'] ?? req.socket.remoteAddress ?? '').split(',')[0].trim();
    const f = failures.get(key) ?? { n: 0, at: Date.now() };
    f.n++;
    if (failures.size > 10000) failures.clear();
    failures.set(key, f);
  };

  return async function handle(req, res) {
    try {
      const url = new URL(req.url, 'http://x');
      const path = url.pathname.replace(/\/+$/, '') || '/';

      if (req.method === 'GET' && path === '/healthz') return send(res, 200, { ok: true, billing: billing.kind, stripe: !!stripeWebhookSecret, hub: !!hub });

      // Stripe webhooks: customers, subscriptions and invoices. Signed with STRIPE_WEBHOOK_SECRET.
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

      if (path.startsWith('/v1/')) {
        if (limited(req)) return send(res, 429, { error: 'too many attempts, wait 10 minutes' });
        if (!authorized(req)) { fail(req); return send(res, 401, { error: 'token required' }); }
      }

      if (req.method === 'GET' && path === '/v1/overview') {
        const [subscriptions, invoices] = await Promise.all([billing.all('subscriptions'), billing.all('invoices')]);
        return send(res, 200, billingOverview(subscriptions, invoices));
      }
      if (req.method === 'GET' && path === '/v1/subscribers') {
        const [customers, subscriptions] = await Promise.all([billing.all('customers'), billing.all('subscriptions')]);
        return send(res, 200, { subscribers: subscriberRows(customers, subscriptions, { q: url.searchParams.get('q') ?? '', status: url.searchParams.get('status') ?? '' }) });
      }
      let m;
      if (req.method === 'GET' && (m = /^\/v1\/subscribers\/([A-Za-z0-9_]+)$/.exec(path))) {
        const [customer, subscriptions, invoices] = await Promise.all([
          billing.get('customers', m[1]), billing.where('subscriptions', 'customerId', m[1]), billing.where('invoices', 'customerId', m[1]),
        ]);
        if (!customer && !subscriptions.length) return send(res, 404, { error: 'unknown customer' });
        const byDate = (a, b) => (b.createdAt ?? '').localeCompare(a.createdAt ?? '');
        return send(res, 200, { customer: customer ?? { id: m[1] }, subscriptions: subscriptions.sort(byDate), invoices: invoices.sort(byDate) });
      }

      // The Hub's anonymous usage stats, fetched from the Hub API so the app needs only this server.
      if (req.method === 'GET' && path === '/v1/hub-stats') {
        if (!hub) return send(res, 503, { error: 'HUB_API_URL and HUB_ADMIN_TOKEN are not set' });
        const days = Math.min(Math.max(parseInt(url.searchParams.get('days') ?? '30', 10) || 30, 1), 365);
        const r = await fetchImpl(`${hub.url}/v1/admin/stats?days=${days}`, { headers: { authorization: `Bearer ${hub.token}` } });
        if (!r.ok) return send(res, 502, { error: `hub answered ${r.status}` });
        return send(res, 200, await r.json());
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

async function main() {
  let billing = createMemoryBillingStore();
  if (process.env.DATABASE_URL) {
    const { default: pg } = await import('pg');
    billing = await createPgBillingStore(new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 4 }));
  } else console.warn('DATABASE_URL is not set: subscribers are kept in memory only.');
  if (!process.env.CONTROL_TOKEN) console.warn('CONTROL_TOKEN is not set: the app cannot log in.');
  const hub = process.env.HUB_API_URL && process.env.HUB_ADMIN_TOKEN ? { url: process.env.HUB_API_URL.replace(/\/+$/, ''), token: process.env.HUB_ADMIN_TOKEN } : null;
  const app = createApp({ billing, stripeWebhookSecret: process.env.STRIPE_WEBHOOK_SECRET ?? null, controlToken: process.env.CONTROL_TOKEN ?? null, hub });
  const port = parseInt(process.env.PORT ?? '8080', 10);
  createServer(app).listen(port, () => console.log(`LINE21 Control server on :${port} · billing ${billing.kind} · hub stats ${hub ? 'on' : 'off'}`));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
