import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHmac } from 'node:crypto';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp } from '../src/server.js';
import { loadCatalog } from '../src/catalog.js';
import { createJsonlStore } from '../src/events.js';
import {
  verifyStripeSignature, applyEvent, subscriberRows, billingOverview, createMemoryBillingStore, createPgBillingStore,
} from '../src/billing.js';

const SECRET = 'whsec_test';
const catalog = loadCatalog(join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'catalog'));
const sign = (body, t = Math.floor(Date.now() / 1000), secret = SECRET) =>
  `t=${t},v1=${createHmac('sha256', secret).update(`${t}.${body}`).digest('hex')}`;

const NOW = Math.floor(Date.now() / 1000);
let n = 0;
const ev = (type, object, created = NOW) => ({ id: `evt_${++n}`, type, created, livemode: false, data: { object } });
const sub = (over = {}) => ({
  id: 'sub_1', customer: 'cus_1', status: 'trialing', created: NOW - 100, trial_end: NOW + 3 * 86400, cancel_at_period_end: false,
  items: { data: [{ quantity: 1, current_period_end: NOW + 3 * 86400,
    price: { id: 'price_m', product: 'prod_x', unit_amount: 9900, currency: 'dkk', recurring: { interval: 'month', interval_count: 1 }, metadata: { line21_product: 'proxel' } } }] },
  ...over,
});

async function serve(opts = {}) {
  const billing = createMemoryBillingStore();
  const events = createJsonlStore(join(mkdtempSync(join(tmpdir(), 'l21ev-')), 'events.jsonl'));
  const server = createServer(createApp({ catalog, events, billing, stripeWebhookSecret: SECRET, adminToken: 'secret', ...opts }));
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const hook = (event, sig) => {
    const body = JSON.stringify(event);
    return fetch(`${base}/v1/webhooks/stripe`, { method: 'POST', body, headers: { 'stripe-signature': sig ?? sign(body) } });
  };
  const admin = (p) => fetch(`${base}${p}`, { headers: { authorization: 'Bearer secret' } }).then((r) => r.json());
  return { base, billing, hook, admin, close: () => server.close() };
}

test('stripe signature: valid, wrong secret, stale, tampered', () => {
  const body = '{"id":"evt_1"}';
  assert.ok(verifyStripeSignature(Buffer.from(body), sign(body), SECRET));
  assert.ok(!verifyStripeSignature(Buffer.from(body), sign(body, undefined, 'whsec_other'), SECRET));
  assert.ok(!verifyStripeSignature(Buffer.from(body), sign(body, NOW - 3600), SECRET));
  assert.ok(!verifyStripeSignature(Buffer.from(body + ' '), sign(body), SECRET));
  assert.ok(!verifyStripeSignature(Buffer.from(body), undefined, SECRET));
  // Several v1 signatures (during secret rotation): any match is enough.
  assert.ok(verifyStripeSignature(Buffer.from(body), `${sign(body)},v1=${'0'.repeat(64)}`, SECRET));
});

test('webhook: rejects unsigned and unconfigured requests', async () => {
  const s = await serve();
  assert.equal((await s.hook(ev('customer.created', { id: 'cus_1' }), 't=1,v1=00')).status, 400);
  s.close();
  const off = await serve({ stripeWebhookSecret: null });
  assert.equal((await off.hook(ev('customer.created', { id: 'cus_1' }))).status, 503);
  off.close();
});

test('webhook → subscriber list, detail and overview', async () => {
  const s = await serve();
  await s.hook(ev('checkout.session.completed', { customer: 'cus_1', created: NOW - 200, customer_details: { email: 'ann@example.com', name: 'Ann', address: { country: 'DK' } } }));
  await s.hook(ev('customer.subscription.created', sub()));
  await s.hook(ev('customer.subscription.created', sub({ id: 'sub_2', customer: 'cus_2', status: 'active',
    items: { data: [{ quantity: 1, current_period_end: NOW + 365 * 86400, price: { id: 'price_y', product: 'prod_x', unit_amount: 95040, currency: 'dkk', recurring: { interval: 'year', interval_count: 1 }, metadata: { line21_product: 'proxel' } } }] } })));
  await s.hook(ev('customer.created', { id: 'cus_2', email: 'bo@example.com', name: 'Bo', created: NOW - 50 }));
  await s.hook(ev('invoice.paid', { id: 'in_1', customer: 'cus_2', parent: { subscription_details: { subscription: 'sub_2' } }, status: 'paid', amount_paid: 95040, amount_due: 95040, currency: 'dkk', created: NOW - 40, status_transitions: { paid_at: NOW - 40 } }));

  assert.equal((await fetch(`${s.base}/v1/admin/billing/subscribers`)).status, 401, 'admin only');

  const { subscribers } = await s.admin('/v1/admin/billing/subscribers');
  assert.deepEqual(subscribers.map((r) => [r.email, r.status, r.product, r.interval]), [
    ['bo@example.com', 'active', 'proxel', 'year'],
    ['ann@example.com', 'trialing', 'proxel', 'month'],
  ]);
  assert.equal(subscribers[1].country, 'DK');
  assert.ok(subscribers[1].renewsAt, 'trial shows when it converts');

  assert.equal((await s.admin('/v1/admin/billing/subscribers?q=ANN')).subscribers.length, 1);
  assert.equal((await s.admin('/v1/admin/billing/subscribers?status=active')).subscribers[0].id, 'cus_2');

  const detail = await s.admin('/v1/admin/billing/subscribers/cus_2');
  assert.equal(detail.customer.name, 'Bo');
  assert.equal(detail.invoices[0].amountPaid, 95040);
  assert.equal(detail.invoices[0].subscriptionId, 'sub_2');

  const o = await s.admin('/v1/admin/billing/overview');
  assert.equal(o.active, 1);
  assert.equal(o.trialing, 1);
  assert.equal(o.mrr.dkk, 7920, 'yearly price counts as a twelfth per month; trials count as 0');
  assert.equal(o.revenue30d.dkk, 95040);
  s.close();
});

test('events are applied once, and older events never overwrite newer ones', async () => {
  const store = createMemoryBillingStore();
  const canceled = ev('customer.subscription.deleted', sub({ status: 'canceled', canceled_at: NOW, ended_at: NOW }), NOW + 10);
  const stale = ev('customer.subscription.updated', sub({ status: 'active' }), NOW + 5);
  assert.equal(await applyEvent(store, canceled), true);
  assert.equal(await applyEvent(store, canceled), false, 'duplicate delivery is ignored');
  await applyEvent(store, stale);
  assert.equal((await store.get('subscriptions', 'sub_1')).status, 'canceled');
});

test('a partial customer from checkout fills gaps but does not overwrite', async () => {
  const store = createMemoryBillingStore();
  await applyEvent(store, ev('customer.created', { id: 'cus_9', email: 'real@example.com', name: null }, NOW));
  await applyEvent(store, ev('checkout.session.completed', { customer: 'cus_9', customer_details: { email: 'other@example.com', name: 'Cee' } }, NOW + 1));
  const c = await store.get('customers', 'cus_9');
  assert.equal(c.email, 'real@example.com');
  assert.equal(c.name, 'Cee');
});

test('overview counts churn and past due', () => {
  const now = Date.parse('2026-11-17T12:00:00Z');
  const subs = [
    { status: 'active', amount: 9900, quantity: 1, interval: 'month', currency: 'dkk', createdAt: '2026-11-02T00:00:00Z' },
    { status: 'past_due', amount: 9900, quantity: 1, interval: 'month', currency: 'dkk', createdAt: '2026-10-01T00:00:00Z' },
    { status: 'canceled', canceledAt: '2026-11-10T00:00:00Z', createdAt: '2026-09-01T00:00:00Z' },
    { status: 'incomplete_expired', createdAt: '2026-11-05T00:00:00Z' },
  ];
  const o = billingOverview(subs, [], { now });
  assert.deepEqual([o.active, o.pastDue, o.canceled30d, o.newThisMonth, o.mrr.dkk], [1, 1, 1, 1, 19800]);
  assert.equal(subscriberRows([], subs.map((x, i) => ({ ...x, id: `s${i}`, customerId: `c${i}` }))).length, 4);
});

// Runs against a real Postgres when PG_TEST_URL is set (CI does not have one).
test('postgres store round trip', { skip: !process.env.PG_TEST_URL }, async () => {
  const { default: pg } = await import('pg');
  const pool = new pg.Pool({ connectionString: process.env.PG_TEST_URL });
  await pool.query('DROP TABLE IF EXISTS billing_events, customers, subscriptions, invoices');
  const store = await createPgBillingStore(pool);
  const e = ev('customer.subscription.created', sub());
  assert.equal(await applyEvent(store, e), true);
  assert.equal(await applyEvent(store, e), false);
  await applyEvent(store, ev('invoice.payment_failed', { id: 'in_9', customer: 'cus_1', subscription: 'sub_1', status: 'open', amount_due: 9900, currency: 'dkk', created: NOW }));
  const s = await store.get('subscriptions', 'sub_1');
  assert.equal(s.amount, 9900);
  assert.equal(s.product, 'proxel');
  assert.equal(typeof s.trialEnd, 'string');
  assert.equal((await store.where('invoices', 'customerId', 'cus_1'))[0].status, 'failed');
  assert.equal((await store.all('subscriptions')).length, 1);
  await pool.end();
});
