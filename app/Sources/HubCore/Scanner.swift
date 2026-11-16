import Foundation

public enum Scanner {
    /// Installed version of each Hub-installable target, nil when it is not installed.
    public static func installedVersions(_ catalog: Catalog) -> [String: String?] {
        var out: [String: String?] = [:]
        for (_, t) in catalog.allTargets where t.hubInstallable && t.platform == "macos" {
            guard let install = t.install else { continue }
            let info = BundleInfo.read(at: URL(fileURLWithPath: install.path))
            // A bundle with another id at our path is not ours; treat it as not installed.
            let version: String? = info?.bundleId == install.bundleId ? (info?.version ?? "ukendt") : nil
            out.updateValue(version, forKey: t.id) // keep the key even when nil: "not installed" is data
        }
        return out
    }

    /// Version of each known host app installed on this Mac, e.g. DaVinci Resolve 20.2.
    public static func hostVersions(_ hosts: [String: HostApp]) -> [String: String?] {
        var out: [String: String?] = [:]
        for (id, host) in hosts {
            for path in host.macos?.appPaths ?? [] {
                if let v = BundleInfo.read(at: URL(fileURLWithPath: path))?.version {
                    out[id] = v
                    break
                }
            }
        }
        return out
    }

    public static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
