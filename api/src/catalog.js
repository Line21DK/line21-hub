import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { compare, isValid } from './semver.js';

export const KINDS = ['plugin-bundle', 'app-bundle', 'tauri-app', 'web-app'];
export const PLATFORMS = ['macos', 'windows', 'linux', 'web'];
export const CHANNELS = ['stable', 'beta'];
const CHANNEL_RANK = { stable: 0, beta: 1 };

export function loadCatalog(dir) {
  const hosts = JSON.parse(readFileSync(join(dir, 'hosts.json'), 'utf8'));
  const files = readdirSync(join(dir, 'products')).filter((f) => f.endsWith('.json')).sort();
  const products = files.map((f) => {
    const p = JSON.parse(readFileSync(join(dir, 'products', f), 'utf8'));
    p.__file = f;
    return p;
  });
  let support = null;
  try {
    support = JSON.parse(readFileSync(join(dir, 'support.json'), 'utf8'));
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
  // Product icons (catalog/icons/*.png), kept in memory and served by the API.
  const icons = {};
  const iconDir = join(dir, 'icons');
  if (existsSync(iconDir)) {
    for (const f of readdirSync(iconDir).filter((n) => /^[a-z0-9-]+\.png$/.test(n))) icons[f] = readFileSync(join(iconDir, f));
  }
  const catalog = { hosts, products, support, icons };
  const errors = validate(catalog);
  if (errors.length) {
    const e = new Error(`Catalog is invalid:\n- ${errors.join('\n- ')}`);
    e.errors = errors;
    throw e;
  }
  return catalog;
}

export function validate({ hosts, products, support, icons }) {
  const errors = [];
  for (const t of support?.tiers ?? []) {
    if (!t.id || !t.label) errors.push(`support.json: every tier needs id and label`);
    if (!/^https:\/\//.test(t.url ?? '')) errors.push(`support.json › ${t.id}: url must be https`);
  }
  const productIds = new Set();
  const targetIds = new Set();
  for (const p of products) {
    const where = p.__file ?? p.id;
    if (!/^[a-z0-9-]+$/.test(p.id ?? '')) errors.push(`${where}: product id must be lowercase-kebab`);
    if (productIds.has(p.id)) errors.push(`${where}: duplicate product id ${p.id}`);
    productIds.add(p.id);
    if (!p.name) errors.push(`${where}: missing name`);
    if (p.icon && icons && !icons[p.icon]) errors.push(`${where}: icon ${p.icon} is not in catalog/icons (lowercase .png)`);
    if (!Array.isArray(p.targets) || !p.targets.length) errors.push(`${where}: needs at least one target`);
    for (const t of p.targets ?? []) {
      const tw = `${where} › ${t.id}`;
      if (!/^[a-z0-9-]+$/.test(t.id ?? '')) errors.push(`${tw}: target id must be lowercase-kebab`);
      if (targetIds.has(t.id)) errors.push(`${tw}: duplicate target id (must be unique across the catalog)`);
      targetIds.add(t.id);
      if (!KINDS.includes(t.kind)) errors.push(`${tw}: kind must be one of ${KINDS.join(', ')}`);
      if (!PLATFORMS.includes(t.platform)) errors.push(`${tw}: platform must be one of ${PLATFORMS.join(', ')}`);
      if (t.host && !hosts[t.host]) errors.push(`${tw}: unknown host ${t.host} (add it to hosts.json)`);
      if (t.kind === 'plugin-bundle' || t.kind === 'app-bundle') {
        if (!t.install?.path?.startsWith('/')) errors.push(`${tw}: install.path must be absolute`);
        if (!t.install?.bundleId) errors.push(`${tw}: install.bundleId is required`);
      }
      if (t.kind === 'web-app' && !/^https:\/\//.test(t.url ?? '')) errors.push(`${tw}: web-app needs an https url`);
      const versions = new Set();
      for (const r of t.releases ?? []) {
        const rw = `${tw} @ ${r.version}`;
        if (!isValid(r.version)) errors.push(`${rw}: invalid version`);
        if (versions.has(r.version)) errors.push(`${rw}: duplicate version`);
        versions.add(r.version);
        if (!CHANNELS.includes(r.channel)) errors.push(`${rw}: channel must be ${CHANNELS.join(' or ')}`);
        if (r.status && !['active', 'withdrawn'].includes(r.status)) errors.push(`${rw}: status must be active or withdrawn`);
        if (!/^\d{4}-\d{2}-\d{2}$/.test(r.date ?? '')) errors.push(`${rw}: date must be YYYY-MM-DD`);
        if (r.requires?.macos && !isValid(r.requires.macos)) errors.push(`${rw}: requires.macos must be a version`);
        for (const [h, v] of Object.entries(r.requires?.hosts ?? {})) {
          if (!hosts[h]) errors.push(`${rw}: requires unknown host ${h}`);
          if (!isValid(v)) errors.push(`${rw}: requires.hosts.${h} must be a version`);
        }
        const slots = new Set();
        for (const a of r.artifacts ?? []) {
          const aw = `${rw} [${a.platform}-${a.arch}]`;
          if (!a.platform || !a.arch) errors.push(`${aw}: artifact needs platform and arch`);
          if (slots.has(`${a.platform}-${a.arch}`)) errors.push(`${aw}: duplicate artifact platform/arch`);
          slots.add(`${a.platform}-${a.arch}`);
          if (!a.key) errors.push(`${aw}: missing bucket key`);
          if (!/^[0-9a-f]{64}$/.test(a.sha256 ?? '')) errors.push(`${aw}: sha256 must be 64 hex chars`);
          if (!Number.isInteger(a.size) || a.size <= 0) errors.push(`${aw}: size must be a positive integer`);
          if (t.kind !== 'web-app' && !a.signature) errors.push(`${aw}: missing ed25519 signature`);
          if (t.kind === 'tauri-app' && !a.tauriSignature) errors.push(`${aw}: tauri-app artifacts need tauriSignature`);
        }
      }
    }
  }
  return errors;
}

export function findTarget(catalog, targetId) {
  for (const p of catalog.products) for (const t of p.targets) if (t.id === targetId) return { product: p, target: t };
  return null;
}

export function visibleReleases(target, channel = 'stable') {
  const rank = CHANNEL_RANK[channel] ?? 0;
  return (target.releases ?? [])
    .filter((r) => r.status !== 'withdrawn' && CHANNEL_RANK[r.channel] <= rank)
    .sort((a, b) => compare(b.version, a.version));
}

export function downloadPath(targetId, version, a) {
  return `/v1/download/${encodeURIComponent(targetId)}/${encodeURIComponent(version)}/${a.platform}-${a.arch}`;
}

/** The catalog as the Hub and other clients see it: no bucket keys, newest release first. */
export function publicCatalog(catalog, { channel = 'stable' } = {}) {
  const products = catalog.products.map((p) => ({
    id: p.id,
    name: p.name,
    summary: p.summary ?? null,
    homepage: p.homepage ?? null,
    icon: p.icon ? `/v1/icons/${p.icon}` : null,
    targets: p.targets.map((t) => {
      const releases = visibleReleases(t, channel).map((r) => ({
        version: r.version,
        channel: r.channel,
        date: r.date,
        notes: r.notes ?? '',
        requires: r.requires ?? {},
        artifacts: (r.artifacts ?? []).map((a) => ({
          platform: a.platform,
          arch: a.arch,
          size: a.size,
          sha256: a.sha256,
          signature: a.signature ?? null,
          download: downloadPath(t.id, r.version, a),
        })),
      }));
      return {
        id: t.id,
        label: t.label ?? p.name,
        kind: t.kind,
        platform: t.platform,
        host: t.host ?? null,
        install: t.install ?? null,
        url: t.url ?? null,
        latest: releases[0]?.version ?? null,
        withdrawn: (t.releases ?? []).filter((r) => r.status === 'withdrawn').map((r) => r.version),
        releases,
      };
    }),
  }));
  const support = catalog.support?.enabled ? { ...catalog.support } : null;
  const body = { schemaVersion: 1, channel, hosts: catalog.hosts, support, products };
  const etag = '"' + createHash('sha256').update(JSON.stringify(body)).digest('hex').slice(0, 32) + '"';
  return { body, etag };
}
