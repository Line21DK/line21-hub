#!/usr/bin/env node
// Publishes one release into the catalog: hashes and signs the installer, checks that the
// bundle inside matches the target, uploads it to the bucket and writes the catalog entry.
// Afterwards: commit + push catalog/, and Railway redeploys the API with the new version.
//
//   npm run release -- --target lineseparator-ofx-macos --version 0.3.1 \
//     --file ~/Downloads/Seperator-macOS-universal.zip --notes-file notes.md --upload
import { createHash, createPrivateKey, sign } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, statSync, createReadStream } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { loadCatalog, findTarget, validate } from '../api/src/catalog.js';
import { signedMessage } from '../api/src/signing.js';
import { compare, isValid } from '../api/src/semver.js';
import { bucketConfig, createStorage } from '../api/src/storage.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const { values: o } = parseArgs({
  options: {
    target: { type: 'string' },
    version: { type: 'string' },
    file: { type: 'string' },
    platform: { type: 'string', default: 'macos' },
    arch: { type: 'string', default: 'universal' },
    channel: { type: 'string', default: 'stable' },
    notes: { type: 'string' },
    'notes-file': { type: 'string' },
    date: { type: 'string', default: new Date().toISOString().slice(0, 10) },
    'min-macos': { type: 'string' },
    'min-host': { type: 'string', multiple: true },
    'tauri-signature-file': { type: 'string' },
    key: { type: 'string', default: process.env.LINE21_SIGNING_KEY ?? join(homedir(), '.line21', 'hub-signing-key.pem') },
    catalog: { type: 'string', default: join(root, 'catalog') },
    upload: { type: 'boolean', default: false },
    'dry-run': { type: 'boolean', default: false },
  },
});

const fail = (msg) => {
  console.error(`✗ ${msg}`);
  process.exit(1);
};
for (const k of ['target', 'version', 'file']) if (!o[k]) fail(`--${k} is required`);
if (!isValid(o.version)) fail(`--version ${o.version} is not a version`);

const catalog = loadCatalog(o.catalog);
const found = findTarget(catalog, o.target);
if (!found) fail(`unknown target ${o.target}`);
const { product, target } = found;

const file = o.file.replace(/^~/, homedir());
const bytes = readFileSync(file);
const sha256 = createHash('sha256').update(bytes).digest('hex');
const size = statSync(file).size;

// The installer must contain the bundle the Hub will put at install.path, with the same id and version.
if (target.kind === 'plugin-bundle' || target.kind === 'app-bundle') {
  const bundleName = basename(target.install.path);
  let plist;
  try {
    plist = execFileSync('unzip', ['-p', file, `${bundleName}/Contents/Info.plist`], { encoding: 'utf8' });
  } catch {
    fail(`${basename(file)} has no ${bundleName}/Contents/Info.plist at its top level`);
  }
  const read = (key) => new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`).exec(plist)?.[1];
  if (read('CFBundleIdentifier') !== target.install.bundleId) fail(`bundle id is ${read('CFBundleIdentifier')}, expected ${target.install.bundleId}`);
  if (read('CFBundleShortVersionString') !== o.version) fail(`bundle version is ${read('CFBundleShortVersionString')}, but you are releasing ${o.version}. Bump the version in the build first.`);
  console.log(`✓ ${bundleName} is ${target.install.bundleId} ${o.version}`);
}

let privateKey;
try {
  privateKey = createPrivateKey(readFileSync(o.key.replace(/^~/, homedir())));
} catch {
  fail(`cannot read signing key ${o.key}. Run npm run keygen once, or pass --key.`);
}
const signature = sign(null, Buffer.from(signedMessage({ targetId: target.id, version: o.version, platform: o.platform, arch: o.arch, sha256 })), privateKey).toString('base64');

const objectKey = `${product.id}/${target.id}/${o.version}/${basename(file)}`;
const artifact = { platform: o.platform, arch: o.arch, key: objectKey, size, sha256, signature };
if (o['tauri-signature-file']) artifact.tauriSignature = readFileSync(o['tauri-signature-file'], 'utf8').trim();

const notes = o['notes-file'] ? readFileSync(o['notes-file'], 'utf8').trim() : o.notes;
let release = target.releases.find((r) => r.version === o.version);
if (release) {
  release.artifacts = (release.artifacts ?? []).filter((a) => !(a.platform === o.platform && a.arch === o.arch));
  release.artifacts.push(artifact);
  if (notes) release.notes = notes;
} else {
  if (!notes) fail('a new release needs --notes or --notes-file (what changed, shown in the Hub)');
  release = { version: o.version, channel: o.channel, date: o.date, notes, requires: {}, artifacts: [artifact] };
  target.releases.push(release);
}
if (o['min-macos']) release.requires.macos = o['min-macos'];
for (const pair of o['min-host'] ?? []) {
  const [host, v] = pair.split('=');
  (release.requires.hosts ??= {})[host] = v;
}
target.releases.sort((a, b) => compare(b.version, a.version));

const errors = validate(catalog);
if (errors.length) fail(`catalog would be invalid:\n  ${errors.join('\n  ')}`);

if (o['dry-run']) {
  console.log(JSON.stringify(release, null, 2));
  process.exit(0);
}

if (o.upload) {
  const storage = createStorage(bucketConfig());
  if (!storage) fail('--upload needs BUCKET, ENDPOINT, ACCESS_KEY_ID and SECRET_ACCESS_KEY in the environment');
  const { PutObjectCommand } = await import('@aws-sdk/client-s3');
  await storage.client.send(new PutObjectCommand({
    Bucket: storage.bucket, Key: objectKey, Body: createReadStream(file), ContentLength: size,
    ContentType: 'application/zip', Metadata: { sha256 },
  }));
  console.log(`✓ uploaded to bucket as ${objectKey}`);
} else {
  console.log(`! not uploaded. Upload ${basename(file)} to the bucket as ${objectKey}, or run again with --upload.`);
}

const { __file, ...clean } = product;
writeFileSync(join(o.catalog, 'products', __file), JSON.stringify(clean, null, 2) + '\n');
console.log(`✓ ${target.id} ${o.version} written to catalog/products/${__file}`);
console.log('  Next: git commit catalog/ && git push  (Railway redeploys the API)');
