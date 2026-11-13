import Foundation

public enum InstallStep: String, Sendable {
    case downloading, verifying, unpacking, backingUp, waitingForAdmin, installing, done

    public var label: String {
        switch self {
        case .downloading: return "Henter"
        case .verifying: return "Tjekker signatur"
        case .unpacking: return "Pakker ud"
        case .backingUp: return "Tager backup"
        case .waitingForAdmin: return "Venter på godkendelse"
        case .installing: return "Installerer"
        case .done: return "Færdig"
        }
    }
}

public enum InstallError: LocalizedError, Equatable {
    case notInstallable
    case download(String)
    case verify(VerifyError)
    case unpack(String)
    case backup(String)
    case adminCancelled
    case adminFailed(String)
    case postCheck(expected: String, got: String?)

    public var errorDescription: String? {
        switch self {
        case .notInstallable: return "Der er ingen pakke til denne Mac."
        case let .download(msg): return "Download fejlede: \(msg)"
        case let .verify(e): return e.errorDescription
        case let .unpack(msg): return "Kunne ikke pakke ud: \(msg)"
        case let .backup(msg): return "Kunne ikke tage backup, så intet er ændret: \(msg)"
        case .adminCancelled: return "Du annullerede administratorgodkendelsen. Intet er ændret."
        case let .adminFailed(msg): return "Installationen med administratorrettigheder fejlede: \(msg)"
        case let .postCheck(e, g): return "Efter installationen læser Hubben version \(g ?? "ingen"), forventede \(e)."
        }
    }

    /// Short code for the anonymous stats page.
    public var code: String {
        switch self {
        case .notInstallable: return "not_installable"
        case .download: return "download"
        case let .verify(e):
            switch e {
            case .badSignature, .missingSignature, .badPublicKey: return "signature"
            case .hashMismatch, .sizeMismatch: return "checksum"
            case .codesignFailed: return "codesign"
            default: return "bundle_mismatch"
            }
        case .unpack: return "unpack"
        case .backup: return "backup"
        case .adminCancelled: return "admin_cancelled"
        case .adminFailed: return "admin_failed"
        case .postCheck: return "post_check"
        }
    }
}

public struct Backup: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public var targetId: String
    public var version: String
    public var date: Date
    public var url: URL
}

/// Downloads, verifies and installs bundles, keeping a local backup of what it replaces.
public final class Installer: @unchecked Sendable {
    public let apiBase: URL
    public let publicKey: String
    public let backupRoot: URL
    public var installId: String?
    public var keepBackups = 3

    public init(apiBase: URL, publicKey: String, backupRoot: URL, installId: String?) {
        self.apiBase = apiBase
        self.publicKey = publicKey
        self.backupRoot = backupRoot
        self.installId = installId
    }

    public static var defaultBackupRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LINE21 Hub/Backups", isDirectory: true)
    }

    /// Does replacing this path need an administrator password?
    public static func needsAdmin(for installPath: String) -> Bool {
        let fm = FileManager.default
        let parent = (installPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) { return !fm.isWritableFile(atPath: (parent as NSString).deletingLastPathComponent) }
        if !fm.isWritableFile(atPath: parent) { return true }
        return fm.fileExists(atPath: installPath) && !fm.isWritableFile(atPath: installPath)
    }

    public func install(
        target: Target, release: Release, artifact: Artifact, installedVersion: String?,
        progress: @escaping @Sendable (InstallStep, Double?) -> Void
    ) async throws {
        guard target.hubInstallable, let install = target.install else { throw InstallError.notInstallable }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("LINE21Hub-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }

        // 1. Download through the API, which hands out a short-lived bucket link.
        progress(.downloading, 0)
        guard let downloadURL = URL(string: artifact.download, relativeTo: apiBase),
              var comps = URLComponents(url: downloadURL, resolvingAgainstBaseURL: true) else { throw InstallError.notInstallable }
        if let installedVersion { comps.queryItems = [URLQueryItem(name: "from", value: installedVersion)] }
        var request = URLRequest(url: comps.url!)
        if let installId { request.setValue(installId, forHTTPHeaderField: "X-Line21-Install-Id") }
        let zip = staging.appendingPathComponent("package.zip")
        do {
            try await Downloader.download(request, to: zip, expectedSize: artifact.size) { progress(.downloading, $0) }
        } catch {
            throw InstallError.download(error.localizedDescription)
        }

        // 2. Checksum + signature, before anything is unpacked.
        progress(.verifying, nil)
        do {
            try Verifier.verifyArtifact(file: zip, artifact: artifact, targetId: target.id, version: release.version, publicKeyBase64: publicKey)
        } catch let e as VerifyError { throw InstallError.verify(e) }

        // 3. Unpack and check that the bundle is what the catalog promised.
        progress(.unpacking, nil)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard ditto.status == 0 else { throw InstallError.unpack(ditto.stderr) }
        let bundleName = (install.path as NSString).lastPathComponent
        let newBundle = unpacked.appendingPathComponent(bundleName, isDirectory: true)
        do {
            try Verifier.verifyBundle(at: newBundle, bundleId: install.bundleId, version: release.version)
        } catch let e as VerifyError { throw InstallError.verify(e) }

        // 4. Back up what is there now.
        if fm.fileExists(atPath: install.path) {
            progress(.backingUp, nil)
            try backup(targetId: target.id, installPath: install.path, version: installedVersion ?? "ukendt")
        }

        // 5. Swap it in.
        try await replace(installPath: install.path, with: newBundle, label: target.label, progress: progress)

        let now = BundleInfo.read(at: URL(fileURLWithPath: install.path))
        guard now?.version == release.version else { throw InstallError.postCheck(expected: release.version, got: now?.version) }
        progress(.done, 1)
    }

    /// Puts a backup back in place.
    public func restore(_ backup: Backup, target: Target, progress: @escaping @Sendable (InstallStep, Double?) -> Void) async throws {
        guard let install = target.install else { throw InstallError.notInstallable }
        let bundle = backup.url.appendingPathComponent((install.path as NSString).lastPathComponent)
        guard BundleInfo.read(at: bundle)?.bundleId == install.bundleId else {
            throw InstallError.verify(.bundleIdMismatch(expected: install.bundleId, got: BundleInfo.read(at: bundle)?.bundleId))
        }
        try await replace(installPath: install.path, with: bundle, label: target.label, progress: progress)
        progress(.done, 1)
    }

    public func backups(for targetId: String) -> [Backup] {
        let dir = backupRoot.appendingPathComponent(targetId, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return items.compactMap { url -> Backup? in
            let name = url.lastPathComponent
            guard let sep = name.lastIndex(of: "_") else { return nil }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return Backup(targetId: targetId, version: String(name[..<sep]), date: date, url: url)
        }.sorted { $0.date > $1.date }
    }

    func backup(targetId: String, installPath: String, version: String) throws {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dir = backupRoot.appendingPathComponent(targetId, isDirectory: true).appendingPathComponent("\(version)_\(stamp)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let r = try Shell.run("/usr/bin/ditto", [installPath, dir.appendingPathComponent((installPath as NSString).lastPathComponent).path])
            guard r.status == 0 else { throw InstallError.backup(r.stderr) }
        } catch let e as InstallError {
            throw e
        } catch {
            throw InstallError.backup(error.localizedDescription)
        }
        for old in backups(for: targetId).dropFirst(keepBackups) { try? fm.removeItem(at: old.url) }
    }

    func replace(installPath: String, with source: URL, label: String, progress: @escaping @Sendable (InstallStep, Double?) -> Void) async throws {
        if !Self.needsAdmin(for: installPath) {
            progress(.installing, nil)
            do {
                try replaceAsUser(installPath: installPath, source: source)
                return
            } catch {
                // Fall through: some file inside the old bundle was not ours to delete.
            }
        }
        progress(.waitingForAdmin, nil)
        try await replaceAsAdmin(installPath: installPath, source: source, label: label)
        progress(.installing, nil)
    }

    func replaceAsUser(installPath: String, source: URL) throws {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: installPath)
        let temp = URL(fileURLWithPath: installPath + ".l21new")
        try? fm.removeItem(at: temp)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try Shell.run("/usr/bin/ditto", [source.path, temp.path])
        guard r.status == 0 else { throw InstallError.adminFailed(r.stderr) }
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", temp.path])
        if fm.fileExists(atPath: installPath) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: temp, to: dest)
    }

    /// One macOS password prompt; every step runs as root in a single shell so nothing is left half-done.
    func replaceAsAdmin(installPath: String, source: URL, label: String) async throws {
        let parent = (installPath as NSString).deletingLastPathComponent
        let temp = installPath + ".l21new"
        let q = Self.shellQuote
        let command = [
            "set -e",
            "/bin/mkdir -p \(q(parent))",
            "/bin/rm -rf \(q(temp))",
            "/usr/bin/ditto \(q(source.path)) \(q(temp))",
            "/usr/sbin/chown -R root:wheel \(q(temp))",
            "/bin/chmod -R go-w \(q(temp))",
            "/usr/bin/xattr -dr com.apple.quarantine \(q(temp)) 2>/dev/null || true",
            "/bin/rm -rf \(q(installPath))",
            "/bin/mv \(q(temp)) \(q(installPath))",
        ].joined(separator: "; ")
        let prompt = "LINE21 Hub vil opdatere \(label) i \(parent)."
        let script = "do shell script \"\(Self.appleScriptEscape(command))\" with administrator privileges with prompt \"\(Self.appleScriptEscape(prompt))\""
        let result = try await Task.detached { try Shell.run("/usr/bin/osascript", ["-e", script]) }.value
        if result.status != 0 {
            if result.stderr.contains("-128") { throw InstallError.adminCancelled }
            throw InstallError.adminFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// URLSession download with progress, bridged to async.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let destination: URL
    private let expectedSize: Int
    private let onProgress: (Double) -> Void

    private init(destination: URL, expectedSize: Int, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    static func download(_ request: URLRequest, to destination: URL, expectedSize: Int, onProgress: @escaping (Double) -> Void) async throws {
        let d = Downloader(destination: destination, expectedSize: expectedSize, onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            d.continuation = c
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(max(expectedSize, 1))
        onProgress(min(1, Double(totalBytesWritten) / total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "serveren svarede \(http.statusCode)"]))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
