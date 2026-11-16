import Foundation

/// The catalog as served by GET /v1/catalog. Mirrors api/src/catalog.js → publicCatalog().
public struct Catalog: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var channel: String
    public var hosts: [String: HostApp]
    public var support: Support?
    public var products: [Product]

    public var allTargets: [(product: Product, target: Target)] {
        products.flatMap { p in p.targets.map { (p, $0) } }
    }
}

public struct HostApp: Codable, Equatable, Sendable {
    public var name: String
    public var macos: MacHost?

    public struct MacHost: Codable, Equatable, Sendable {
        public var bundleIds: [String]?
        public var bundleIdPrefixes: [String]?
        public var appPaths: [String]?
    }
}

public struct Support: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var title: String
    public var message: String?
    public var tiers: [Tier]

    public struct Tier: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var label: String
        public var amount: Double?
        public var currency: String?
        public var url: URL
    }
}

public struct Product: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String?
    public var homepage: String?
    /// Path on the catalog server, e.g. /v1/icons/floatblur.png.
    public var icon: String?
    public var targets: [Target]
}

public struct Target: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pluginBundle = "plugin-bundle"
        case appBundle = "app-bundle"
        case tauriApp = "tauri-app"
        case webApp = "web-app"
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var platform: String
    public var host: String?
    public var install: Install?
    public var url: URL?
    public var latest: String?
    public var withdrawn: [String]
    public var releases: [Release]

    public struct Install: Codable, Equatable, Sendable {
        public var path: String
        public var bundleId: String
    }

    /// Installed by the Hub itself (copy a bundle into place), as opposed to apps that update themselves.
    public var hubInstallable: Bool { kind == .pluginBundle || kind == .appBundle }
}

public struct Release: Codable, Equatable, Identifiable, Sendable {
    public var id: String { version }
    public var version: String
    public var channel: String
    public var date: String
    public var notes: String
    public var requires: Requirements
    public var artifacts: [Artifact]

    public struct Requirements: Codable, Equatable, Sendable {
        public var macos: String?
        public var hosts: [String: String]?
    }
}

public struct Artifact: Codable, Equatable, Sendable {
    public var platform: String
    public var arch: String
    public var size: Int
    public var sha256: String
    public var signature: String?
    public var download: String
}

public extension Target {
    /// Releases newer than `installed`, newest first. Everything if nothing is installed.
    func releases(after installed: String?) -> [Release] {
        guard let installed else { return releases }
        return releases.filter { SemVer.compare($0.version, installed) == .orderedDescending }
    }

    /// The newest release this Mac can run, and the artifact to install for it.
    func installable(macOS: String, arch: String) -> (release: Release, artifact: Artifact)? {
        for r in releases {
            if let min = r.requires.macos, SemVer.compare(macOS, min) == .orderedAscending { continue }
            let pick = r.artifacts.first { $0.platform == "macos" && $0.arch == arch }
                ?? r.artifacts.first { $0.platform == "macos" && $0.arch == "universal" }
            if let pick { return (release: r, artifact: pick) }
        }
        return nil
    }
}
