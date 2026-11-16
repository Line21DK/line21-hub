import { appendFile, readFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

// Anonymous usage events. installId is a random UUID the Hub creates on first launch; nothing
// ties it to a person, and the server never stores IP addresses.
export const EVENT_TYPES = ['check', 'download', 'install_ok', 'install_fail', 'rollback', 'uninstall', 'open', 'support_click'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const short = (v, n = 64) => (v == null ? null : String(v).slice(0, n));

export function isInstallId(v) {
  return UUID.test(v ?? '');
}

export function normalizeBatch(body) {
  if (!body || typeof body !== 'object') throw new Error('body must be an object');
  const installId = isInstallId(body.installId) ? body.installId.toLowerCase() : null;
  if (!installId) throw new Error('installId must be a UUID');
  const events = Array.isArray(body.events) ? body.events : [];
  if (!events.length || events.length > 50) throw new Error('events must hold 1 to 50 items');
  const now = Date.now();
  return events.map((e) => {
    if (!EVENT_TYPES.includes(e?.type)) throw new Error(`unknown event type ${e?.type}`);
    let ts = Date.parse(e.ts ?? '');
    if (!Number.isFinite(ts) || ts > now + 5 * 60e3 || ts < now - 30 * 864e5) ts = now;
    const data = e.data && typeof e.data === 'object' && !Array.isArray(e.data) ? e.data : {};
    return {
      ts: new Date(ts).toISOString(),
      type: e.type,
      installId,
      targetId: short(e.targetId),
      fromVersion: short(e.fromVersion, 32),
      toVersion: short(e.toVersion, 32),
      hubVersion: short(body.hubVersion, 32),
      os: short(body.os, 32),
      arch: short(body.arch, 16),
      error: short(e.error, 300),
      data: JSON.stringify(data).length <= 4000 ? data : {},
    };
  });
}

/** Fallback store: one JSON line per event. Put the file on a Railway volume to keep it. */
export function createJsonlStore(path) {
  return {
    kind: 'jsonl',
    async insert(rows) {
      await mkdir(dirname(path), { recursive: true });
      await appendFile(path, rows.map((r) => JSON.stringify(r)).join('\n') + '\n');
    },
    async since(iso) {
      let text = '';
      try {
        text = await readFile(path, 'utf8');
      } catch {
        return [];
      }
      return text.split('\n').filter(Boolean).map((l) => JSON.parse(l)).filter((r) => r.ts >= iso);
    },
  };
}

export async function createPgStore(url) {
  const { default: pg } = await import('pg');
  const pool = new pg.Pool({ connectionString: url, max: 4 });
  await pool.query(`CREATE TABLE IF NOT EXISTS hub_events (
    id bigserial PRIMARY KEY,
    ts timestamptz NOT NULL,
    type text NOT NULL,
    install_id uuid,
    target_id text,
    from_version text,
    to_version text,
    hub_version text,
    os text,
    arch text,
    error text,
    data jsonb NOT NULL DEFAULT '{}'
  );
  CREATE INDEX IF NOT EXISTS hub_events_ts ON hub_events (ts);`);
  const cols = ['ts', 'type', 'install_id', 'target_id', 'from_version', 'to_version', 'hub_version', 'os', 'arch', 'error', 'data'];
  return {
    kind: 'postgres',
    async insert(rows) {
      const values = [];
      const tuples = rows.map((r, i) => {
        values.push(r.ts, r.type, r.installId, r.targetId, r.fromVersion, r.toVersion, r.hubVersion, r.os, r.arch, r.error, JSON.stringify(r.data ?? {}));
        return '(' + cols.map((_, j) => `$${i * cols.length + j + 1}`).join(',') + ')';
      });
      await pool.query(`INSERT INTO hub_events (${cols.join(',')}) VALUES ${tuples.join(',')}`, values);
    },
    async since(iso) {
      const { rows } = await pool.query(
        `SELECT ts, type, install_id AS "installId", target_id AS "targetId", from_version AS "fromVersion",
                to_version AS "toVersion", hub_version AS "hubVersion", os, arch, error, data
         FROM hub_events WHERE ts >= $1 ORDER BY ts`,
        [iso],
      );
      return rows.map((r) => ({ ...r, ts: new Date(r.ts).toISOString() }));
    },
  };
}

const inc = (obj, key, n = 1) => {
  obj[key] = (obj[key] ?? 0) + n;
};
const bucket = (obj, k) => (obj[k ?? '?'] ??= {});

/** Aggregates for the stats page. Computed in memory, which is fine until events reach the millions. */
export function computeStats(rows, { days }) {
  const activeInstalls = new Set();
  const events = {};
  const downloads = {};
  const installs = {};
  const failures = {};
  const lastCheck = new Map();
  const daily = {};
  for (const r of rows) {
    inc(events, r.type);
    const d = (daily[r.ts.slice(0, 10)] ??= { active: new Set(), downloads: 0, installs: 0, failures: 0 });
    if (r.installId) {
      activeInstalls.add(r.installId);
      d.active.add(r.installId);
    }
    if (r.type === 'download') {
      inc(bucket(downloads, r.targetId), r.toVersion ?? '?');
      d.downloads++;
    } else if (r.type === 'install_ok') {
      inc(bucket(installs, r.targetId), r.toVersion ?? '?');
      d.installs++;
    } else if (r.type === 'install_fail') {
      inc(bucket(failures, r.targetId), r.error ?? 'unknown');
      d.failures++;
    } else if (r.type === 'check' && r.installId) {
      lastCheck.set(r.installId, r);
    }
  }
  // What people have installed right now, from each Hub's most recent check.
  const installed = {};
  const hostVersions = {};
  const hubVersions = {};
  const osVersions = {};
  for (const r of lastCheck.values()) {
    inc(hubVersions, r.hubVersion ?? '?');
    inc(osVersions, r.os ?? '?');
    for (const [t, v] of Object.entries(r.data?.installed ?? {})) inc(bucket(installed, t), v ?? 'not installed');
    for (const [h, v] of Object.entries(r.data?.hosts ?? {})) inc(bucket(hostVersions, h), v ?? '?');
  }
  return {
    days,
    activeInstalls: activeInstalls.size,
    reportingHubs: lastCheck.size,
    events,
    downloads,
    installs,
    failures,
    installed,
    hostVersions,
    hubVersions,
    osVersions,
    daily: Object.entries(daily)
      .sort(([a], [b]) => (a < b ? -1 : 1))
      .map(([day, d]) => ({ day, active: d.active.size, downloads: d.downloads, installs: d.installs, failures: d.failures })),
  };
}
