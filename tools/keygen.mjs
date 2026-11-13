#!/usr/bin/env node
// Creates the Ed25519 key pair that signs every release.
// The private key stays on the release machine (never in git, never on Railway).
// The public key goes into the Hub app's Info.plist (LINE21SigningPublicKey).
import { generateKeyPairSync } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

const out = process.argv[2] ?? join(homedir(), '.line21', 'hub-signing-key.pem');
if (existsSync(out)) {
  console.error(`${out} already exists. Delete it yourself if you really want a new key: every installed Hub trusts the old one.`);
  process.exit(1);
}
const { privateKey, publicKey } = generateKeyPairSync('ed25519');
mkdirSync(dirname(out), { recursive: true, mode: 0o700 });
writeFileSync(out, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
const raw = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url');
console.log(`Private key: ${out}  (back it up somewhere safe, e.g. your password manager)`);
console.log(`Public key (base64, put in app/Resources/Info.plist → LINE21SigningPublicKey):\n${raw.toString('base64')}`);
