import AppKit
import HubCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: HubStore

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider().overlay(L21.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = store.loadError { Notice(text: error, color: L21.amber) }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Tag(text: group.title, color: L21.muted)
                            VStack(spacing: 0) {
                                ForEach(Array(group.rows.enumerated()), id: \.element.id) { i, row in
                                    if i > 0 { Rectangle().fill(L21.line).frame(height: 1) }
                                    RowView(row: row)
                                }
                            }
                            .background(L21.panel)
                            .overlay(Rectangle().strokeBorder(L21.line, lineWidth: 1))
                        }
                    }
                    if store.rows.isEmpty && store.loadError == nil { LoadingTape() }
                }
                .padding(20)
            }
            Footer()
        }
        .background(L21.bg)
        .frame(minWidth: 520, minHeight: 380)
        .sheet(item: $store.gate) { gate in GateSheet(gate: gate) }
    }

    struct Group: Identifiable {
        var id: String { title }
        var title: String
        var rows: [Row]
    }

    /// One section per host app, e.g. "DaVinci Resolve".
    private var groups: [Group] {
        let hosts = store.catalog?.hosts ?? [:]
        let grouped = Dictionary(grouping: store.rows) { row -> String in
            row.target.host.flatMap { hosts[$0]?.name } ?? "Apps"
        }
        return grouped.keys.sorted().map { Group(title: $0, rows: grouped[$0]!.sorted { $0.product.name < $1.product.name }) }
    }
}

/// Compact toolbar: wordmark, last check, refresh, and "Update All" when there is more than one.
struct Header: View {
    @EnvironmentObject var store: HubStore

    var body: some View {
        HStack(spacing: 12) {
            GlitchMark(trigger: store.glitch).frame(width: 72, height: 14)
            Text("Hub").font(.system(size: 13, weight: .semibold)).foregroundStyle(L21.accentSoft)
            Spacer()
            Text(status).font(.system(size: 11.5)).foregroundStyle(L21.muted).monospacedDigit()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(store.checking ? 360 : 0))
                    .animation(store.checking ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: store.checking)
            }
            .buttonStyle(L21ButtonStyle(kind: .quiet))
            .help("Check for updates (⌘R)")
            .keyboardShortcut("r")
            .disabled(store.checking)
            if store.updatesAvailable.count > 1 {
                Button("Update All (\(store.updatesAvailable.count))") { store.update(store.updatesAvailable.map(\.id)) }
                    .buttonStyle(L21ButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var status: String {
        if store.checking { return "Checking…" }
        guard let d = store.lastChecked else { return "" }
        return "Checked \(Self.clock.string(from: d))"
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// Small square with the product's initials, so each row reads as an app, not a web card.
struct ProductBadge: View {
    var name: String
    var highlighted: Bool
    var body: some View {
        Text(initials).font(L21.mono(12, .bold))
            .foregroundStyle(highlighted ? L21.onAccent : L21.accent)
            .frame(width: 34, height: 34)
            .background(highlighted ? L21.accent : Color.clear)
            .overlay(Rectangle().strokeBorder(L21.accent, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
    private var initials: String {
        let caps = name.filter(\.isUppercase)
        return String((caps.count >= 2 ? caps : name).prefix(2)).uppercased()
    }
}

struct RowView: View {
    @EnvironmentObject var store: HubStore
    var row: Row
    @State private var showNotes = false

    private var job: Job? { store.jobs[row.id] }
    private var outcome: Outcome? { store.outcomes[row.id] }
    private var waitingForQuit: Bool { store.afterQuit.values.contains { $0.contains(row.id) } }
    private var updateReady: Bool { row.hasUpdate && row.isInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProductBadge(name: row.product.name, highlighted: updateReady)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.product.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(L21.ink)
                    HStack(spacing: 6) {
                        versionText
                        Text("·").foregroundStyle(L21.line)
                        statusText
                        if !notes.isEmpty {
                            Text("·").foregroundStyle(L21.line)
                            Button(showNotes ? "Hide notes" : "What's new") {
                                withAnimation(.easeOut(duration: 0.15)) { showNotes.toggle() }
                            }
                            .buttonStyle(.plain).foregroundStyle(L21.accent)
                        }
                    }
                    .font(.system(size: 11.5))
                }
                Spacer(minLength: 12)
                action
            }

            if let job {
                HStack(spacing: 10) {
                    TapeProgress(value: job.step == .downloading ? job.progress : nil)
                    Text(job.step == .waitingForAdmin ? "Approve in the macOS dialog" : job.step.label)
                        .font(.system(size: 11.5)).foregroundStyle(L21.accentSoft).fixedSize()
                }
                .padding(.leading, 46)
            }

            if let outcome {
                HStack(alignment: .top, spacing: 8) {
                    Text(outcome.message).font(.system(size: 12)).foregroundStyle(outcome.ok ? L21.accentSoft : L21.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { store.dismissOutcome(row.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(L21ButtonStyle(kind: .quiet)).help("Dismiss")
                }
                .padding(.leading, 46)
            }

            if row.withdrawnInstalled {
                Notice(text: "Version \(row.installed ?? "") has been withdrawn. Update, or restore a backup.", color: L21.amber)
                    .padding(.leading, 46)
            }

            if showNotes { ReleaseNotes(releases: notes).padding(.leading, 46) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    /// What changed between the installed version and the newest, or the newest notes if nothing is newer.
    private var notes: [Release] {
        updateReady ? row.newReleases : Array(row.target.releases.prefix(1))
    }

    private var versionText: some View {
        HStack(spacing: 4) {
            Text(row.installed ?? "Ikke installeret").foregroundStyle(updateReady ? L21.muted : L21.accentSoft)
            if updateReady, let new = row.candidate?.release.version {
                Text("→").foregroundStyle(L21.accent)
                Text(new).foregroundStyle(L21.ink)
            }
        }
        .font(L21.mono(11.5, .medium))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusText: some View {
        if job != nil {
            Text("Working").foregroundStyle(L21.accent)
        } else if waitingForQuit {
            Text("Waiting for Resolve to quit").foregroundStyle(L21.amber)
        } else if let reason = row.blockedReason {
            Text(reason).foregroundStyle(L21.amber)
        } else if updateReady {
            HStack(spacing: 4) { Circle().fill(L21.red).frame(width: 6, height: 6); Text("New version").foregroundStyle(L21.ink) }
        } else if row.isInstalled {
            Text("Up to date").foregroundStyle(L21.muted)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder private var action: some View {
        if job == nil && !waitingForQuit && row.hasUpdate {
            HStack(spacing: 8) {
                if store.needsAdmin(row) {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(L21.muted)
                        .help("Plugins live in a folder macOS protects. You will be asked for your Mac password.")
                        .accessibilityLabel("Requires password")
                }
                Button(row.isInstalled ? "Update" : "Install") { store.update([row.id]) }
                    .buttonStyle(L21ButtonStyle(kind: row.isInstalled ? .primary : .secondary))
                    .keyboardShortcut(store.updatesAvailable.count == 1 && row.isInstalled ? .defaultAction : nil)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if let path = row.target.install?.path, row.isInstalled {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        let backups = store.backups(for: row)
        if !backups.isEmpty {
            Menu("Restore Backup") {
                ForEach(backups) { b in
                    Button("\(b.version) · \(b.date.formatted(date: .abbreviated, time: .shortened))") { store.restore(b, row: row) }
                }
            }
        }
        if let home = row.product.homepage, let url = URL(string: home) {
            Button("Open Project Page") { NSWorkspace.shared.open(url) }
        }
    }
}

struct ReleaseNotes: View {
    var releases: [Release]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(releases) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(r.version).font(L21.mono(12, .bold)).foregroundStyle(L21.ink)
                        Tag(text: r.date, color: L21.muted)
                        if r.channel == "beta" { Tag(text: "Beta", color: L21.amber) }
                    }
                    ForEach(Array(r.notes.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                        Text(Self.markdown(String(line))).font(.system(size: 12.5)).foregroundStyle(L21.accentSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func markdown(_ line: String) -> AttributedString {
        let text = line.hasPrefix("- ") ? "• " + line.dropFirst(2) : line
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

struct Notice: View {
    var text: String
    var color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(color).frame(width: 3)
            Text(text).font(.system(size: 12.5)).foregroundStyle(L21.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

struct LoadingTape: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Tag(text: "Rewinding tape…")
            TapeProgress(value: nil).frame(maxWidth: 240)
        }
        .padding(.vertical, 40)
    }
}

/// Asks to close the host app. Offers to wait instead, so nobody loses work.
struct GateSheet: View {
    @EnvironmentObject var store: HubStore
    var gate: HostGate

    private var names: String {
        store.rows.filter { gate.targetIds.contains($0.id) }.map(\.product.name).formatted(.list(type: .and, width: .standard))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(gate.hostName) is open").font(.system(size: 17, weight: .semibold)).foregroundStyle(L21.ink)
            Text("\(names) can't be replaced while \(gate.hostName) is running. Save your project first. The Hub updates as soon as it has quit.")
                .font(.system(size: 13)).foregroundStyle(L21.accentSoft).fixedSize(horizontal: false, vertical: true)
            if gate.waitingForQuit {
                VStack(alignment: .leading, spacing: 6) {
                    TapeProgress(value: nil)
                    Text("Waiting for \(gate.hostName) to quit. Answer its save dialog if it asks.")
                        .font(.system(size: 12)).foregroundStyle(L21.accentSoft)
                }
            }
            HStack(spacing: 12) {
                Button("Cancel") { store.cancelGate() }
                    .buttonStyle(L21ButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("When I Quit It") { store.deferUntilQuit(gate) }
                    .buttonStyle(L21ButtonStyle(kind: .secondary))
                    .disabled(gate.waitingForQuit)
                Button("Quit \(gate.hostName)") { store.quitHost(gate) }
                    .buttonStyle(L21ButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(gate.waitingForQuit)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(L21.bg)
    }
}

struct Footer: View {
    @EnvironmentObject var store: HubStore
    @State private var showSupport = false

    var body: some View {
        HStack(spacing: 12) {
            if let support = store.catalog?.support, support.enabled, !support.tiers.isEmpty {
                Button { showSupport.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cup.and.saucer").font(.system(size: 11))
                        Text(support.title).font(.system(size: 11.5))
                    }
                    .foregroundStyle(L21.muted)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSupport, arrowEdge: .top) { SupportView(support: support) }
            }
            Spacer()
            Text("v\(Config.hubVersion)").font(L21.mono(10.5, .regular)).foregroundStyle(L21.muted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(L21.line).frame(height: 1) }
    }
}

struct SupportView: View {
    @EnvironmentObject var store: HubStore
    var support: Support

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(support.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(L21.ink)
            if let message = support.message {
                Text(message).font(.system(size: 12.5)).foregroundStyle(L21.accentSoft).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(support.tiers) { tier in
                    Button { store.openSupport(tier) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tier.label).font(.system(size: 13, weight: .bold))
                            Text(price(tier)).font(L21.mono(11, .regular)).opacity(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(L21ButtonStyle(kind: .secondary))
                }
            }
            Text("Payment opens in your browser").font(.system(size: 11)).foregroundStyle(L21.muted)
        }
        .padding(18)
        .frame(width: 320)
        .background(L21.bg)
    }

    private func price(_ t: Support.Tier) -> String {
        guard let amount = t.amount else { return "Your choice" }
        return amount.formatted(.currency(code: t.currency ?? "DKK").precision(.fractionLength(0)))
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: HubStore
    @State private var url = ""

    var body: some View {
        Form {
            Section {
                Picker("Releases", selection: $store.channel) {
                    Text("Stable").tag("stable")
                    Text("Stable and beta").tag("beta")
                }
                Toggle("Notify me about new versions", isOn: $store.notificationsOn)
                Toggle("Open LINE21 Hub at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
            }
            Section {
                Toggle("Share anonymous usage stats", isOn: $store.telemetryOn)
                Text("Helps LINE21 see which versions are in use and whether updates fail. The Hub sends a random ID plus macOS and app versions. Never your name, email, files or projects.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Show Backups in Finder") {
                    try? FileManager.default.createDirectory(at: Installer.defaultBackupRoot, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Installer.defaultBackupRoot)
                }
                TextField("Catalog server", text: $url, prompt: Text(Config.defaultCatalogURL.absoluteString))
                    .onSubmit {
                        store.catalogURLString = url
                        store.reconnect()
                    }
            } header: { Text("Advanced") }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { url = store.catalogURLString }
    }
}
