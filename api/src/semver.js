// Minimal semver: MAJOR.MINOR.PATCH with optional -prerelease. Enough for release ordering.
export function parse(v) {
  const m = /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?$/.exec(String(v).trim());
  if (!m) return null;
  return { major: +m[1], minor: +(m[2] ?? 0), patch: +(m[3] ?? 0), pre: m[4] ? m[4].split('.') : [] };
}

export function compare(a, b) {
  const x = parse(a), y = parse(b);
  if (!x || !y) throw new Error(`Invalid version: ${!x ? a : b}`);
  for (const k of ['major', 'minor', 'patch']) if (x[k] !== y[k]) return x[k] < y[k] ? -1 : 1;
  if (!x.pre.length && !y.pre.length) return 0;
  if (!x.pre.length) return 1;
  if (!y.pre.length) return -1;
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const p = x.pre[i], q = y.pre[i];
    if (p === undefined) return -1;
    if (q === undefined) return 1;
    const pn = /^\d+$/.test(p), qn = /^\d+$/.test(q);
    if (pn && qn && +p !== +q) return +p < +q ? -1 : 1;
    if (pn !== qn) return pn ? -1 : 1;
    if (p !== q) return p < q ? -1 : 1;
  }
  return 0;
}

export const isValid = (v) => parse(v) !== null;
