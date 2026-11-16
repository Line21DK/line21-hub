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
        rows = c.allTargets.filter { $0.target.platform == "macos" && $0.target.hubInstallable }.map { p, t in
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
        let release = candidate.release, artifact = candidate.artifact
        let id = row.id
        outcomes[id] = nil
        jobs[id] = Job(step: .downloading, progress: 0)
        let installer = self.installer
        Task {
            do {
                try await installer.install(target: row.target, release: release, artifact: artifact, installedVersion: row.installed) { step, p in
                    Task { @MainActor in self.jobs[id] = Job(step: step, progress: p) }
                }
                jobs[id] = nil
                outcomes[id] = Outcome(ok: true, message: row.isInstalled ? "Updated to \(release.version). Restart Resolve to use it." : "\(release.version) is installed.")
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
