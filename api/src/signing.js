// The exact bytes an artifact signature covers. The Hub app builds the same string
// (app/Sources/LINE21Hub/Verifier.swift), so keep both in step.
// Binding target, version and platform stops a valid file being replayed as another release.
export function signedMessage({ targetId, version, platform, arch, sha256 }) {
  return `line21-hub-artifact-v1\n${targetId}\n${version}\n${platform}-${arch}\n${sha256.toLowerCase()}\n`;
}
