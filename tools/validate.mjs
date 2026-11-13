#!/usr/bin/env node
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadCatalog, publicCatalog } from '../api/src/catalog.js';

const dir = process.argv[2] ?? join(dirname(fileURLToPath(import.meta.url)), '..', 'catalog');
try {
  const catalog = loadCatalog(dir);
  const { body } = publicCatalog(catalog);
  for (const p of body.products) for (const t of p.targets) console.log(`✓ ${t.id.padEnd(28)} latest ${t.latest ?? '—'}  (${t.releases.length} releases)`);
} catch (err) {
  console.error(err.message);
  process.exit(1);
}
