import AppKit
import HubCore
import ServiceManagement
import SwiftUI
import UserNotifications

enum Config {
    static let info = Bundle.main.infoDictionary ?? [:]
    static var hubVersion: String { info["CFBundleShortVersionString"] as? String ?? "0.0.0" }
    static var defaultCatalogURL: URL { URL(string: info["LINE21CatalogURL"] as? String ?? "http://localhost:8080")! }
    static var publicKey: String { info["LINE21SigningPublicKey"] as? String ?? "" }
    static let checkInterval: TimeInterval = 4 * 3600

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LINE21 Hub", isDirectory: true)
    }

    static var installId: String {
        let key = "installId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

/// One row in the Hub: a target, what is installed, and what we could install.
struct Row: Identifiable {
    var product: Product
    var target: Target
    var installed: String?
    var isInstalled: Bool
    var candidate: (release: Release, artifact: Artifact)?
    var newReleases: [Release]
    var withdrawnInstalled: Bool
    var blockedReason: String?

    var id: String { target.id }
    var hasUpdate: Bool {
        guard let c = candidate else { return false }
        guard let installed, isInstalled else { return true }
        return SemVer.compare(c.release.version, installed) == .orderedDescending
    }
}

/// An app that updates itself (PROXEL) or lives on the web (Gearbank): the Hub only opens or downloads it.
struct OtherApp: Identifiable {
    var product: Product
    var target: Target
    var installed: String?
    var id: String { target.id }
}

/// A newer version of the Hub itself. It is not a row: it shows as a banner and replaces the running app.
struct HubUpdate: Equatable {
    var target: Target
    var release: Release
    var artifact: Artifact
    var newReleases: [Release]
}

struct Job: Equatable {
    var step: InstallStep
    var progress: Double?
}

struct Outcome: Equatable {
    var ok: Bool
    var message: String
}

/// Asks the user to quit a host app before its plugin is replaced.
struct HostGate: Identifiable {
    var id: String { hostId }
    var hostId: String
    var hostName: String
    var targetIds: [String]
    var waitingForQuit = false
}

@MainActor
final class HubStore: ObservableObject {
    @Published private(set) var catalog: Catalog?
    @Published private(set) var rows: [Row] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checking = false
    @Published private(set) var loadError: String?
    @Published private(set) var jobs: [String: Job] = [:]
    @Published private(set) var outcomes: [String: Outcome] = [:]
    @Published private(set) var afterQuit: [String: Set<String>] = [:] // hostId -> target ids
    @Published private(set) var others: [OtherApp] = []
    @Published private(set) var hubUpdate: HubUpdate?
    @Published private(set) var hubJob: Job?
    @Published private(set) var hubError: String?
    @Published var gate: HostGate?
    @Published var glitch = 0

    // Settings. @AppStorage does not publish from an ObservableObject, so each one announces itself.
    @AppStorage("channel") var channel = "stable" { willSet { objectWillChange.send() } didSet { Task { await refresh() } } }
    @AppStorage("notifications") var notificationsOn = true { willSet { objectWillChange.send() } }
    @AppStorage("telemetry") var telemetryOn = true { willSet { objectWillChange.send() } didSet { Task { await telemetry.setEnabled(telemetryOn) } } }
    @AppStorage("catalogURL") var catalogURLString = "" { willSet { objectWillChange.send() } }

    private var client: CatalogClient
    private var installer: Installer
    private let telemetry: Telemetry
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastCheckEvent: Date?

    var apiBase: URL { URL(string: catalogURLString).flatMap { $0.scheme == nil ? nil : $0 } ?? Config.defaultCatalogURL }

    init() {
        let base = URL(string: UserDefaults.standard.string(forKey: "catalogURL") ?? "").flatMap { $0.scheme == nil ? nil : $0 } ?? Config.defaultCatalogURL
        client = CatalogClient(baseURL: base, cacheDirectory: Config.supportDirectory)
        installer = Installer(apiBase: base, publicKey: Config.publicKey, backupRoot: Installer.defaultBackupRoot, installId: Config.installId)
        telemetry = Telemetry(baseURL: base, installId: Config.installId, hubVersion: Config.hubVersion,
                              enabled: UserDefaults.standard.object(forKey: "telemetry") as? Bool ?? true)
    }

    func start() {
        Task {
            if let cached = await client.lastKnown { apply(cached) }
            await refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Config.checkInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.hostQuit(app) }
        })
        if notificationsOn {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    /// Point the Hub at another catalog server (Settings → Advanced).
    func reconnect() {
        let base = apiBase
        client = CatalogClient(baseURL: base, cacheDirectory: Config.supportDirectory)
        installer = Installer(apiBase: base, publicKey: Config.publicKey, backupRoot: Installer.defaultBackupRoot, installId: Config.installId)
        Task { await refresh() }
    }

    // MARK: Checking

    func refresh() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let c = try await client.fetch(channel: channel)
            loadError = nil
            apply(c)
            lastChecked = Date()
            notifyNewVersions()
            await reportCheck()
        } catch {
            loadError = catalog == nil
                ? "Can't reach the catalog server at \(apiBase.host ?? apiBase.absoluteString). Check your connection, or change the server in Settings → Advanced."
                : "Offline: showing the last known versions."
        }
    }

    private func apply(_ c: Catalog) {
        catalog = c
        rescan()
    }

    func rescan() {
        guard let c = catalog else { return }
        let installed = Scanner.installedVersions(c)
        let macOS = Scanner.macOSVersion
        let hostVersions = Scanner.hostVersions(c.hosts)
        let selfId = Bundle.main.bundleIdentifier ?? "dk.line21.hub"
        hubUpdate = c.allTargets.first { $0.target.install?.bundleId == selfId }.flatMap { _, t in
            guard let c = t.installable(macOS: macOS, arch: Telemetry.machineArch),
                  SemVer.compare(c.release.version, Config.hubVersion) == .orderedDescending else { return nil }
            return HubUpdate(target: t, release: c.release, artifact: c.artifact, newReleases: t.releases(after: Config.hubVersion))
        }
        others = c.allTargets.filter { _, t in
            (t.kind == .tauriApp && t.platform == "macos") || t.kind == .webApp
        }.map { p, t in
            OtherApp(product: p, target: t, installed: t.install.flatMap { BundleInfo.read(at: URL(fileURLWithPath: $0.path))?.version })
        }
        rows = c.allTargets.filter { $0.target.platform == "macos" && $0.target.hubInstallable && $0.target.install?.bundleId != selfId }.map { p, t in
            let v = installed[t.id] ?? nil
            let candidate = t.installable(macOS: macOS, arch: Telemetry.machineArch)
            var blocked: String?
            if candidate == nil, let newest = t.releases.first {
                if let min = newest.requires.macos, SemVer.compare(macOS, min) == .orderedAscending {
                    blocked = "Requires macOS \(min)"
                } else {
                    blocked = "No package for this Mac yet"
                }
            }
            if let r = candidate?.release, let host = t.host, let min = r.requires.hosts?[host],
               let hv = hostVersions[host] ?? nil, SemVer.compare(hv, min) == .orderedAscending {
                blocked = "Requires \(c.hosts[host]?.name ?? host) \(min)"
            }
            return Row(product: p, target: t, installed: v, isInstalled: v != nil, candidate: blocked == nil ? candidate : nil,
                       newReleases: t.releases(after: v), withdrawnInstalled: v.map { t.withdrawn.contains($0) } ?? false,
                       blockedReason: blocked)
        }
    }

    var updatesAvailable: [Row] { rows.filter { $0.isInstalled && $0.hasUpdate } }

    private func reportCheck() async {
        guard let c = catalog else { return }
        if let last = lastCheckEvent, Date().timeIntervalSince(last) < 6 * 3600 { return }
        lastCheckEvent = Date()
        let installed = Scanner.installedVersions(c)
        let hosts = Scanner.hostVersions(c.hosts)
        await telemetry.track(.init(type: "check", data: ["installed": installed, "hosts": hosts]))
    }

    private func notifyNewVersions() {
        guard notificationsOn else { return }
        var seen = Set(UserDefaults.standard.stringArray(forKey: "notified") ?? [])
        for row in updatesAvailable {
            guard let r = row.candidate?.release else { continue }
            let key = "\(row.id)@\(r.version)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let content = UNMutableNotificationContent()
            content.title = "\(row.product.name) \(r.version) is available"
            content.body = "You have \(row.installed ?? "an older version"). Open LINE21 Hub to update."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
        UserDefaults.standard.set(Array(seen), forKey: "notified")
        NSApp.dockTile.badgeLabel = updatesAvailable.isEmpty ? nil : "\(updatesAvailable.count)"
    }

    // MARK: Installing

    func needsAdmin(_ row: Row) -> Bool {
        row.target.install.map { Installer.needsAdmin(for: $0.path) } ?? false
    }

    func update(_ ids: [String]) {
        let rowsToRun = rows.filter { ids.contains($0.id) && $0.candidate != nil && jobs[$0.id] == nil }
        guard !rowsToRun.isEmpty, let c = catalog else { return }
        // Group by host: if Resolve is open, ask once for all its plugins.
        for (hostId, group) in Dictionary(grouping: rowsToRun, by: { $0.target.host ?? "" }) {
            if let host = c.hosts[hostId], !HostApps.running(host).isEmpty {
                gate = HostGate(hostId: hostId, hostName: host.name, targetIds: group.map(\.id))
            } else {
                for row in group { run(row) }
            }
        }
    }

    func quitHost(_ gate: HostGate) {
        guard let host = catalog?.hosts[gate.hostId] else { return }
        self.gate?.waitingForQuit = true
        afterQuit[gate.hostId, default: []].formUnion(gate.targetIds)
        for app in HostApps.running(host) { app.terminate() } // Polite quit: Resolve still asks to save.
    }

    func deferUntilQuit(_ gate: HostGate) {
        afterQuit[gate.hostId, default: []].formUnion(gate.targetIds)
        self.gate = nil
    }

    func cancelGate() {
        if let g = gate { afterQuit[g.hostId] = nil }
        gate = nil
    }

    private func hostQuit(_ app: NSRunningApplication?) {
        guard let c = catalog else { return }
        for (hostId, ids) in afterQuit {
            guard let host = c.hosts[hostId], HostApps.matches(app, host), HostApps.running(host).isEmpty else { continue }
            afterQuit[hostId] = nil
            if gate?.hostId == hostId { gate = nil }
            for row in rows where ids.contains(row.id) { run(row) }
        }
    }

    private func run(_ row: Row) {
        guard let candidate = row.candidate else { return }
        run(row, release: candidate.release, artifact: candidate.artifact)
    }

    private func run(_ row: Row, release: Release, artifact: Artifact) {
        let id = row.id
        let reinstall = row.installed == release.version
        outcomes[id] = nil
        jobs[id] = Job(step: .downloading, progress: 0)
        let installer = self.installer
        Task {
            do {
                try await installer.install(target: row.target, release: release, artifact: artifact, installedVersion: row.installed) { step, p in
                    Task { @MainActor in self.jobs[id] = Job(step: step, progress: p) }
                }
                jobs[id] = nil
                let host = row.target.host.flatMap { catalog?.hosts[$0]?.name } ?? "the host app"
                outcomes[id] = Outcome(ok: true, message: reinstall ? "\(release.version) was downloaded and installed again."
                                       : row.isInstalled ? "Updated to \(release.version). Restart \(host) to use it." : "\(release.version) is installed.")
                glitch += 1
                await telemetry.track(.init(type: "install_ok", targetId: id, fromVersion: row.installed, toVersion: release.version))
            } catch {
                jobs[id] = nil
                let e = error as? InstallError
                outcomes[id] = Outcome(ok: false, message: e?.errorDescription ?? error.localizedDescription)
                await telemetry.track(.init(type: "install_fail", targetId: id, fromVersion: row.installed, toVersion: release.version, error: e?.code ?? "other"))
            }
            rescan()
            notifyNewVersions()
        }
    }

    // MARK: Updating the Hub itself

    /// Downloads and verifies the new Hub like any other package, replaces this app where it lives, and relaunches.
    func updateHub() {
        guard let u = hubUpdate, hubJob == nil else { return }
        let appPath = Bundle.main.bundlePath
        if appPath.contains("/AppTranslocation/") || appPath.hasPrefix("/Volumes/") {
            hubError = "Move LINE21 Hub to your Applications folder and open it from there, then update."
            return
        }
        var target = u.target
        target.install?.path = appPath // Replace the copy that is running, wherever the user keeps it.
        hubError = nil
        hubJob = Job(step: .downloading, progress: 0)
        let installer = self.installer
        let from = Config.hubVersion
        Task {
            do {
                try await installer.install(target: target, release: u.release, artifact: u.artifact, installedVersion: from) { step, p in
                    Task { @MainActor in self.hubJob = Job(step: step, progress: p) }
                }
                await telemetry.track(.init(type: "install_ok", targetId: target.id, fromVersion: from, toVersion: u.release.version))
                relaunch(appPath)
            } catch {
                hubJob = nil
                let e = error as? InstallError
                hubError = e?.errorDescription ?? error.localizedDescription
                await telemetry.track(.init(type: "install_fail", targetId: target.id, fromVersion: from, toVersion: u.release.version, error: e?.code ?? "other"))
            }
        }
    }

    private func relaunch(_ path: String) {
        // A tiny shell waits until this process is gone, then opens the new bundle.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh",
                       String(ProcessInfo.processInfo.processIdentifier), path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Row menu

    /// The installed version's package, if the catalog still has it for this Mac.
    func reinstallPackage(_ row: Row) -> (release: Release, artifact: Artifact)? {
        guard let v = row.installed, let r = row.target.releases.first(where: { $0.version == v }) else { return nil }
        let arch = Telemetry.machineArch
        guard let a = r.artifacts.first(where: { $0.platform == "macos" && $0.arch == arch })
                ?? r.artifacts.first(where: { $0.platform == "macos" && $0.arch == "universal" }) else { return nil }
        return (r, a)
    }

    /// Download the installed version again and replace the bundle with a verified copy.
    func reinstall(_ row: Row) {
        guard jobs[row.id] == nil, let pkg = reinstallPackage(row) else { return }
        if let host = row.target.host.flatMap({ catalog?.hosts[$0] }), !HostApps.running(host).isEmpty {
            outcomes[row.id] = Outcome(ok: false, message: "Quit \(host.name) first, then reinstall.")
            return
        }
        run(row, release: pkg.release, artifact: pkg.artifact)
    }

    /// Checks the installed bundle: right bundle ID, a version the catalog knows, and an intact code signature.
    func verifyInstallation(_ row: Row) {
        guard let install = row.target.install, let v = row.installed else { return }
        let id = row.id
        jobs[id] = Job(step: .verifying, progress: nil)
        let known = row.target.releases.contains { $0.version == v } || row.target.withdrawn.contains(v)
        Task.detached {
            var result: Outcome
            do {
                try Verifier.verifyBundle(at: URL(fileURLWithPath: install.path), bundleId: install.bundleId, version: v)
                result = known
                    ? Outcome(ok: true, message: "Installation is OK: \(v), bundle ID and code signature check out.")
                    : Outcome(ok: false, message: "The bundle looks intact, but \(v) is not a LINE21 release. Reinstall to be safe.")
            } catch {
                result = Outcome(ok: false, message: "\((error as? VerifyError)?.errorDescription ?? error.localizedDescription) Reinstall to repair it.")
            }
            await MainActor.run {
                self.jobs[id] = nil
                self.outcomes[id] = result
            }
        }
    }

    /// Moves the plugin to the Trash (macOS asks for the password when the folder is protected).
    func uninstall(_ row: Row) {
        guard let path = row.target.install?.path, row.isInstalled else { return }
        if let host = row.target.host.flatMap({ catalog?.hosts[$0] }), !HostApps.running(host).isEmpty {
            outcomes[row.id] = Outcome(ok: false, message: "Quit \(host.name) first, then uninstall.")
            return
        }
        let id = row.id, from = row.installed
        NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in
            Task { @MainActor in
                if let error {
                    self.outcomes[id] = Outcome(ok: false, message: "Couldn't move it to the Trash: \(error.localizedDescription)")
                } else {
                    self.outcomes[id] = Outcome(ok: true, message: "Moved to the Trash. Install it again any time.")
                    await self.telemetry.track(.init(type: "uninstall", targetId: id, fromVersion: from))
                }
                self.rescan()
            }
        }
    }

    func open(_ app: OtherApp) {
        if app.target.kind == .webApp, let url = app.target.url {
            NSWorkspace.shared.open(url)
        } else if let path = app.target.install?.path, app.installed != nil {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSWorkspace.shared.open(apiBase.appendingPathComponent("download").appendingPathComponent(app.target.id))
        }
        Task { await telemetry.track(.init(type: "open", targetId: app.id)) }
    }

    func iconURL(_ product: Product) -> URL? {
        product.icon.flatMap { URL(string: $0, relativeTo: apiBase) }
    }

    func backups(for row: Row) -> [Backup] { installer.backups(for: row.id) }

    func restore(_ backup: Backup, row: Row) {
        if let host = row.target.host.flatMap({ catalog?.hosts[$0] }), !HostApps.running(host).isEmpty {
            outcomes[row.id] = Outcome(ok: false, message: "Quit \(host.name) first, then the backup can be restored.")
            return
        }
        let id = row.id
        jobs[id] = Job(step: .installing, progress: nil)
        let installer = self.installer
        Task {
            do {
                try await installer.restore(backup, target: row.target) { step, p in
                    Task { @MainActor in self.jobs[id] = Job(step: step, progress: p) }
                }
                outcomes[id] = Outcome(ok: true, message: "Version \(backup.version) has been restored.")
                await telemetry.track(.init(type: "rollback", targetId: id, fromVersion: row.installed, toVersion: backup.version))
            } catch {
                outcomes[id] = Outcome(ok: false, message: (error as? InstallError)?.errorDescription ?? error.localizedDescription)
            }
            jobs[id] = nil
            rescan()
        }
    }

    func dismissOutcome(_ id: String) { outcomes[id] = nil }

    // MARK: Support

    func openSupport(_ tier: Support.Tier) {
        NSWorkspace.shared.open(tier.url)
        Task { await telemetry.track(.init(type: "support_click", data: ["tier": ["id": tier.id]])) }
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            objectWillChange.send()
        }
    }
}

enum HostApps {
    static func matches(_ app: NSRunningApplication?, _ host: HostApp) -> Bool {
        guard let app else { return false }
        let id = app.bundleIdentifier ?? ""
        if host.macos?.bundleIds?.contains(id) == true { return true }
        if host.macos?.bundleIdPrefixes?.contains(where: { id.hasPrefix($0) }) == true { return true }
        return app.localizedName?.hasPrefix(host.name) == true
    }

    static func running(_ host: HostApp) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { matches($0, host) && !$0.isTerminated }
    }
}
