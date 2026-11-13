import XCTest
@testable import HubCore

final class HubCoreTests: XCTestCase {
    func testSemVer() {
        XCTAssertEqual(SemVer.compare("0.10.0", "0.9.9"), .orderedDescending)
        XCTAssertEqual(SemVer.compare("1.0.0-beta.2", "1.0.0"), .orderedAscending)
        XCTAssertEqual(SemVer.compare("1.0.0-beta.10", "1.0.0-beta.2"), .orderedDescending)
        XCTAssertEqual(SemVer.compare("v1.2", "1.2.0"), .orderedSame)
    }

    /// Signed by tools/release.mjs with a throwaway key: proves Node and CryptoKit agree on the bytes.
    func testSignatureFromReleaseToolVerifies() throws {
        let publicKey = "ab0XFw9+zx8DVgHjCxvJLLn2TOqm2PW1gi/auGzVGw8="
        let sha = "3df04214a07fb8c08149f4dd41bfde01499f47f41b24270f0c21cb2d1008d268"
        let sig = "auynd1VUjTFaz613a4SiMVYBcN/DsD5L5JDPCXpjkCllpDY4H2eYr+Yk3oE2JXJE4LoKKFoYNPLxlhxUnN2yDg=="
        let key = try Curve25519PublicKey(publicKey)
        let message = Verifier.signedMessage(targetId: "lineseparator-ofx-macos", version: "0.3.1", platform: "macos", arch: "universal", sha256: sha)
        XCTAssertTrue(key.isValidSignature(Data(base64Encoded: sig)!, for: message))
        let other = Verifier.signedMessage(targetId: "lineseparator-ofx-macos", version: "0.3.2", platform: "macos", arch: "universal", sha256: sha)
        XCTAssertFalse(key.isValidSignature(Data(base64Encoded: sig)!, for: other))
    }

    func testShellQuoting() {
        XCTAssertEqual(Installer.shellQuote("/Library/OFX/Plugins/It's.bundle"), "'/Library/OFX/Plugins/It'\\''s.bundle'")
        XCTAssertEqual(Installer.appleScriptEscape("a \"b\" \\c"), "a \\\"b\\\" \\\\c")
    }

    func testReleasesAfterAndInstallable() {
        let a = Artifact(platform: "macos", arch: "universal", size: 1, sha256: "", signature: nil, download: "/x")
        let t = Target(id: "t", label: "T", kind: .pluginBundle, platform: "macos", host: nil,
                       install: .init(path: "/tmp/x.bundle", bundleId: "x"), url: nil, latest: "0.4.0", withdrawn: [],
                       releases: [
                           Release(version: "0.4.0", channel: "stable", date: "", notes: "", requires: .init(macos: "14.0", hosts: nil), artifacts: [a]),
                           Release(version: "0.3.1", channel: "stable", date: "", notes: "", requires: .init(macos: "11.0", hosts: nil), artifacts: [a]),
                           Release(version: "0.3.0", channel: "stable", date: "", notes: "", requires: .init(macos: nil, hosts: nil), artifacts: [a]),
                       ])
        XCTAssertEqual(t.releases(after: "0.3.0").map(\.version), ["0.4.0", "0.3.1"])
        XCTAssertEqual(t.installable(macOS: "13.6.0", arch: "arm64")?.0.version, "0.3.1")
        XCTAssertEqual(t.installable(macOS: "15.1.0", arch: "arm64")?.0.version, "0.4.0")
    }
}

import CryptoKit
private func Curve25519PublicKey(_ b64: String) throws -> Curve25519.Signing.PublicKey {
    try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: b64)!)
}
