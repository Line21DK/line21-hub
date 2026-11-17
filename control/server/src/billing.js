import { createHmac, timingSafeEqual } from 'node:crypto';

// Subscribers and payments, mirrored from Stripe (Managed Payments) through signed webhooks.
// Stripe stays the source of truth for money; these tables are what the admin panel reads.
// Kept apart from hub_events on purpose: nothing here is ever joined with anonymous install ids.

export const KINDS = ['customers', 'subscriptions', 'invoices'];

/** Checks a Stripe-Signature header (t=…,v1=…) against the raw request body. */
export function verifyStripeSignature(rawBody, header, secret, { toleranceSeconds = 300, now = Date.now() } = {}) {
  if (!secret || !header) return false;
  const pairs = String(header).split(',').map((p) => [p.slice(0, p.indexOf('=')).trim(), p.slice(p.indexOf('=') + 1).trim()]);
  const pick = (k) => pairs.filter(([key]) => key === k).map(([, v]) => v);
  const t = Number(pick('t')[0]);
  if (!Number.isFinite(t) || Math.abs(now / 1000 - t) > toleranceSeconds) return false;
  const want = createHmac('sha256', secret).update(`${t}.`).update(rawBody).digest();
  return pick('v1').some((sig) => {
    const got = Buffer.from(sig, 'hex');
    return got.length === want.length && timingSafeEqual(got, want);
  });
}

const iso = (sec) => (sec ? new Date(sec * 1000).toISOString() : null);
const idOf = (v) => (v && typeof v === 'object' ? v.id : v) ?? null;

/** Turns one Stripe event into the rows it changes. Unknown event types change nothing. */
export function rowsFromEvent(event) {
  const o = event?.data?.object ?? {};
  const base = { livemode: !!event.livemode, eventAt: event.created ?? 0 };
  const out = [];
  switch (event.type) {
    case 'customer.created':
    case 'customer.updated':
    case 'customer.deleted':
      out.push(['customers', {
        ...base, id: o.id, email: o.email ?? null, name: o.name ?? null, country: o.address?.country ?? null,
        createdAt: iso(o.created), deleted: event.type === 'customer.deleted',
      }]);
      break;
    case 'checkout.session.completed': {
      const d = o.customer_details ?? {};
      if (idOf(o.customer)) {
        out.push(['customers', { ...base, id: idOf(o.customer), email: d.email ?? null, name: d.name ?? null, country: d.address?.country ?? null, createdAt: iso(o.created), deleted: false, partial: true }]);
      }
      break;
    }
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted':
    case 'customer.subscription.paused':
    case 'customer.subscription.resumed':
    case 'customer.subscription.trial_will_end': {
      const item = o.items?.data?.[0] ?? {};
      const price = item.price ?? o.plan ?? {};
      out.push(['subscriptions', {
        ...base, id: o.id, customerId: idOf(o.customer), status: o.status ?? null,
        product: price.metadata?.line21_product || idOf(price.product) || null,
        priceId: price.id ?? null, interval: price.recurring?.interval ?? price.interval ?? null,
        intervalCount: price.recurring?.interval_count ?? price.interval_count ?? 1,
        amount: price.unit_amount ?? price.amount ?? null, currency: price.currency ?? o.currency ?? null,
        quantity: item.quantity ?? o.quantity ?? 1,
        trialEnd: iso(o.trial_end),
        // Since API version 2025-03-31 the period lives on the item.
        currentPeriodEnd: iso(item.current_period_end ?? o.current_period_end),
        cancelAtPeriodEnd: !!o.cancel_at_period_end, canceledAt: iso(o.canceled_at), endedAt: iso(o.ended_at),
        createdAt: iso(o.created),
      }]);
      break;
    }
    case 'invoice.created':
    case 'invoice.finalized':
    case 'invoice.paid':
    case 'invoice.payment_failed':
    case 'invoice.voided':
    case 'invoice.marked_uncollectible':
      out.push(['invoices', {
        ...base, id: o.id, customerId: idOf(o.customer),
        subscriptionId: idOf(o.parent?.subscription_details?.subscription ?? o.subscription),
        status: event.type === 'invoice.payment_failed' ? 'failed' : o.status ?? null,
        amountDue: o.amount_due ?? 0, amountPaid: o.amount_paid ?? 0, currency: o.currency ?? null,
        createdAt: iso(o.created), paidAt: iso(o.status_transitions?.paid_at), hostedUrl: o.hosted_invoice_url ?? null,
      }]);
      if (idOf(o.customer) && (o.customer_email || o.customer_name)) {
        out.push(['customers', { ...base, id: idOf(o.customer), email: o.customer_email ?? null, name: o.customer_name ?? null, country: o.customer_address?.country ?? null, createdAt: null, deleted: false, partial: true }]);
      }
      break;
    default:
  }
  return out.filter(([, row]) => row.id);
}

/** Merges an incoming row into what is stored. Older events never overwrite newer ones. */
export function mergeRow(existing, row) {
  if (!existing) return { ...row, partial: undefined };
  if (row.partial) {
    // A partial row (from checkout or an invoice) only fills gaps.
    const filled = { ...existing };
    for (const [k, v] of Object.entries(row)) if (filled[k] == null && v != null) filled[k] = v;
    return filled;
  }
  if ((row.eventAt ?? 0) < (existing.eventAt ?? 0)) return existing;
  const next = { ...existing };
  for (const [k, v] of Object.entries(row)) if (k !== 'partial' && (v != null || k === 'canceledAt' || k === 'endedAt' || k === 'trialEnd')) next[k] = v;
  return next;
}

/** Applies a verified Stripe event to the store. Returns false when the event was already handled. */
export async function applyEvent(store, event) {
  if (await store.eventProcessed(event.id)) return false;
  try {
    for (const [kind, row] of rowsFromEvent(event)) await store.put(kind, mergeRow(await store.get(kind, row.id), row));
    await store.saveEvent(event, null);
  } catch (err) {
    await store.saveEvent(event, err.message).catch(() => {});
    throw err;
  }
  return true;
}

// ---------- read models for the admin panel ----------

const LIVE = ['active', 'trialing', 'past_due', 'unpaid'];
const RANK = { active: 0, trialing: 1, past_due: 2, unpaid: 3, incomplete: 4, paused: 5, canceled: 6, incomplete_expired: 7 };
const monthly = (s) => {
  const n = (s.amount ?? 0) * (s.quantity ?? 1);
  const per = { day: 30, week: 52 / 12, month: 1, year: 1 / 12 }[s.interval] ?? 1;
  return (n * per) / (s.intervalCount || 1);
};

/** One row per customer, with their most relevant subscription. */
export function subscriberRows(customers, subscriptions, { q = '', status = '' } = {}) {
  const subsBy = new Map();
  for (const s of subscriptions) (subsBy.get(s.customerId) ?? subsBy.set(s.customerId, []).get(s.customerId)).push(s);
  const known = new Map(customers.map((c) => [c.id, c]));
  for (const id of subsBy.keys()) if (!known.has(id)) known.set(id, { id, email: null, name: null });
  const needle = q.trim().toLowerCase();
  const rows = [];
  for (const c of known.values()) {
    if (c.deleted) continue;
    const subs = (subsBy.get(c.id) ?? []).sort((a, b) => (RANK[a.status] ?? 9) - (RANK[b.status] ?? 9) || (b.createdAt ?? '').localeCompare(a.createdAt ?? ''));
    const s = subs[0] ?? null;
    const row = {
      id: c.id, email: c.email, name: c.name, country: c.country ?? null, livemode: c.livemode ?? s?.livemode ?? false,
      status: s?.status ?? 'none', product: s?.product ?? null, interval: s?.interval ?? null, amount: s?.amount ?? null,
      currency: s?.currency ?? null, renewsAt: s && !s.cancelAtPeriodEnd && LIVE.includes(s.status) ? (s.status === 'trialing' ? s.trialEnd : s.currentPeriodEnd) : null,
      endsAt: s?.cancelAtPeriodEnd ? s.currentPeriodEnd : s?.endedAt ?? null, since: s?.createdAt ?? c.createdAt ?? null,
    };
    if (status && row.status !== status) continue;
    if (needle && ![row.email, row.name, row.id].some((v) => v && v.toLowerCase().includes(needle))) continue;
    rows.push(row);
  }
  return rows.sort((a, b) => (RANK[a.status] ?? 9) - (RANK[b.status] ?? 9) || (b.since ?? '').localeCompare(a.since ?? ''));
}

export function billingOverview(subscriptions, invoices, { now = Date.now() } = {}) {
  const count = (st) => subscriptions.filter((s) => s.status === st).length;
  const monthStart = new Date(now); monthStart.setUTCDate(1); monthStart.setUTCHours(0, 0, 0, 0);
  const ms = monthStart.toISOString();
  const d30 = new Date(now - 30 * 864e5).toISOString();
  const mrr = {};
  for (const s of subscriptions) if (s.status === 'active' || s.status === 'past_due') mrr[s.currency ?? '?'] = (mrr[s.currency ?? '?'] ?? 0) + monthly(s);
  const revenue30d = {};
  for (const i of invoices) if (i.status === 'paid' && (i.paidAt ?? i.createdAt ?? '') >= d30) revenue30d[i.currency ?? '?'] = (revenue30d[i.currency ?? '?'] ?? 0) + (i.amountPaid ?? 0);
  for (const k of Object.keys(mrr)) mrr[k] = Math.round(mrr[k]);
  return {
    active: count('active'), trialing: count('trialing'), pastDue: count('past_due') + count('unpaid'),
    newThisMonth: subscriptions.filter((s) => (s.createdAt ?? '') >= ms && !String(s.status).startsWith('incomplete')).length,
    canceled30d: subscriptions.filter((s) => (s.canceledAt ?? s.endedAt ?? '') >= d30 && s.status === 'canceled').length,
    mrr, revenue30d,
  };
}

// ---------- stores ----------

export function createMemoryBillingStore() {
  const tables = Object.fromEntries(KINDS.map((k) => [k, new Map()]));
  const events = new Map();
  return {
    kind: 'memory',
    async eventProcessed(id) { return !!events.get(id)?.processedAt; },
    async saveEvent(e, error) { events.set(e.id, { id: e.id, type: e.type, error, processedAt: error ? null : new Date().toISOString() }); },
    async get(kind, id) { return tables[kind].get(id) ?? null; },
    async put(kind, row) { tables[kind].set(row.id, row); },
    async all(kind) { return [...tables[kind].values()]; },
    async where(kind, field, value) { return [...tables[kind].values()].filter((r) => r[field] === value); },
    events,
  };
}

const COLUMNS = {
  customers: ['id', 'email', 'name', 'country', 'livemode', 'deleted', 'createdAt', 'eventAt'],
  subscriptions: ['id', 'customerId', 'status', 'product', 'priceId', 'interval', 'intervalCount', 'amount', 'currency', 'quantity',
    'trialEnd', 'currentPeriodEnd', 'cancelAtPeriodEnd', 'canceledAt', 'endedAt', 'createdAt', 'livemode', 'eventAt'],
  invoices: ['id', 'customerId', 'subscriptionId', 'status', 'amountDue', 'amountPaid', 'currency', 'createdAt', 'paidAt', 'hostedUrl', 'livemode', 'eventAt'],
};
const snake = (k) => k.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);
const TS = new Set(['createdAt', 'trialEnd', 'currentPeriodEnd', 'canceledAt', 'endedAt', 'paidAt']);

export async function createPgBillingStore(pool) {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS billing_events (
      id text PRIMARY KEY, type text NOT NULL, created timestamptz, livemode boolean NOT NULL DEFAULT false,
      received_at timestamptz NOT NULL DEFAULT now(), processed_at timestamptz, error text, payload jsonb NOT NULL);
    CREATE TABLE IF NOT EXISTS customers (
      id text PRIMARY KEY, email text, name text, country text, livemode boolean NOT NULL DEFAULT false,
      deleted boolean NOT NULL DEFAULT false, created_at timestamptz, event_at bigint NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS subscriptions (
      id text PRIMARY KEY, customer_id text, status text, product text, price_id text, interval text,
      interval_count integer, amount bigint, currency text, quantity integer, trial_end timestamptz,
      current_period_end timestamptz, cancel_at_period_end boolean NOT NULL DEFAULT false, canceled_at timestamptz,
      ended_at timestamptz, created_at timestamptz, livemode boolean NOT NULL DEFAULT false, event_at bigint NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS subscriptions_customer ON subscriptions (customer_id);
    CREATE TABLE IF NOT EXISTS invoices (
      id text PRIMARY KEY, customer_id text, subscription_id text, status text, amount_due bigint, amount_paid bigint,
      currency text, created_at timestamptz, paid_at timestamptz, hosted_url text, livemode boolean NOT NULL DEFAULT false,
      event_at bigint NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS invoices_customer ON invoices (customer_id);`);
  const select = (kind) => `SELECT ${COLUMNS[kind].map((c) => `${snake(c)} AS "${c}"`).join(', ')} FROM ${kind}`;
  const fromDb = (r) => {
    if (!r) return null;
    for (const k of Object.keys(r)) {
      if (r[k] instanceof Date) r[k] = r[k].toISOString();
      else if (typeof r[k] === 'string' && /^(amount|amountDue|amountPaid|eventAt)$/.test(k)) r[k] = Number(r[k]);
    }
    return r;
  };
  return {
    kind: 'postgres',
    async eventProcessed(id) {
      const { rows } = await pool.query('SELECT processed_at FROM billing_events WHERE id = $1', [id]);
      return !!rows[0]?.processed_at;
    },
    async saveEvent(e, error) {
      await pool.query(
        `INSERT INTO billing_events (id, type, created, livemode, processed_at, error, payload)
         VALUES ($1, $2, to_timestamp($3), $4, CASE WHEN $5::text IS NULL THEN now() END, $5, $6)
         ON CONFLICT (id) DO UPDATE SET processed_at = EXCLUDED.processed_at, error = EXCLUDED.error`,
        [e.id, e.type, e.created ?? 0, !!e.livemode, error, JSON.stringify(e)],
      );
    },
    async get(kind, id) {
      const { rows } = await pool.query(`${select(kind)} WHERE id = $1`, [id]);
      return fromDb(rows[0]);
    },
    async put(kind, row) {
      const cols = COLUMNS[kind];
      const vals = cols.map((c) => (TS.has(c) ? row[c] ?? null : row[c] ?? (c === 'livemode' || c === 'deleted' || c === 'cancelAtPeriodEnd' ? false : c === 'eventAt' ? 0 : null)));
      await pool.query(
        `INSERT INTO ${kind} (${cols.map(snake).join(', ')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')})
         ON CONFLICT (id) DO UPDATE SET ${cols.slice(1).map((c) => `${snake(c)} = EXCLUDED.${snake(c)}`).join(', ')}`,
        vals,
      );
    },
    async all(kind) {
      const { rows } = await pool.query(select(kind));
      return rows.map(fromDb);
    },
    async where(kind, field, value) {
      if (!COLUMNS[kind].includes(field)) throw new Error('bad field');
      const { rows } = await pool.query(`${select(kind)} WHERE ${snake(field)} = $1`, [value]);
      return rows.map(fromDb);
    },
  };
}
