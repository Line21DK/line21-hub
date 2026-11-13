import CryptoKit
import Foundation

public enum VerifyError: LocalizedError, Equatable {
    case sizeMismatch(expected: Int, got: Int)
    case hashMismatch
    case missingSignature
    case badSignature
    case badPublicKey
    case bundleMissing(String)
    case bundleIdMismatch(expected: String, got: String?)
    case versionMismatch(expected: String, got: String?)
    case codesignFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .sizeMismatch(e, g): return "Filen har en forkert størrelse (\(g) bytes, forventede \(e))."
        case .hashMismatch: return "Filens checksum passer ikke med kataloget."
        case .missingSignature: return "Udgivelsen er ikke signeret."
        case .badSignature: return "Signaturen er ugyldig. Pakken er ikke fra LINE21 eller er blevet ændret."
        case .badPublicKey: return "Hubbens offentlige nøgle mangler eller er ugyldig."
        case let .bundleMissing(name): return "Pakken indeholder ikke \(name)."
        case let .bundleIdMismatch(e, g): return "Pakken er \(g ?? "ukendt"), forventede \(e)."
        case let .versionMismatch(e, g): return "Pakken er version \(g ?? "ukendt"), forventede \(e)."
        case let .codesignFailed(msg): return "macOS' kodesignatur-tjek fejlede: \(msg)"
        }
    }
}

public enum Verifier {
    /// The bytes a release signature covers. Must match api/src/signing.js exactly.
    public static func signedMessage(targetId: String, version: String, platform: String, arch: String, sha256: String) -> Data {
        Data("line21-hub-artifact-v1\n\(targetId)\n\(version)\n\(platform)-\(arch)\n\(sha256.lowercased())\n".utf8)
    }

    public static func sha256(of file: URL) throws -> (hex: String, size: Int) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += chunk.count
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    /// Size, checksum and Ed25519 signature of a downloaded installer.
    public static func verifyArtifact(file: URL, artifact: Artifact, targetId: String, version: String, publicKeyBase64: String) throws {
        let (hex, size) = try sha256(of: file)
        guard size == artifact.size else { throw VerifyError.sizeMismatch(expected: artifact.size, got: size) }
        guard hex == artifact.sha256.lowercased() else { throw VerifyError.hashMismatch }
        guard let sigB64 = artifact.signature, let sig = Data(base64Encoded: sigB64) else { throw VerifyError.missingSignature }
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { throw VerifyError.badPublicKey }
        let message = signedMessage(targetId: targetId, version: version, platform: artifact.platform, arch: artifact.arch, sha256: hex)
        guard key.isValidSignature(sig, for: message) else { throw VerifyError.badSignature }
    }

    /// The unpacked bundle must be the product the catalog promised, at the promised version.
    public static func verifyBundle(at bundle: URL, bundleId: String, version: String) throws {
        let info = BundleInfo.read(at: bundle)
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw VerifyError.bundleMissing(bundle.lastPathComponent) }
        guard info?.bundleId == bundleId else { throw VerifyError.bundleIdMismatch(expected: bundleId, got: info?.bundleId) }
        guard info?.version == version else { throw VerifyError.versionMismatch(expected: version, got: info?.version) }
        // A bundle that carries a code signature must still be intact. Ad-hoc signatures pass this too.
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/_CodeSignature").path) {
            let result = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
            guard result.status == 0 else { throw VerifyError.codesignFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}

public struct BundleInfo: Equatable {
    public var bundleId: String?
    public var version: String?

    public static func read(at bundle: URL) -> BundleInfo? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return BundleInfo(
            bundleId: dict["CFBundleIdentifier"] as? String,
            version: (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String)
        )
    }
}

public enum Shell {
    public struct Result {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    @discardableResult
    public static func run(_ tool: String, _ args: [String]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }
}
