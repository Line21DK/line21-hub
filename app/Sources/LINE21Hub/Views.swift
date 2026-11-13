import AppKit
import HubCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: HubStore

    var body: some View {
        ZStack {
            L21.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Header()
                Rectangle().fill(L21.accent).frame(height: 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let error = store.loadError { Notice(text: error, color: L21.amber) }
                        if store.updatesAvailable.count > 1 { UpdateAllBanner() }
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 14) {
                                Tag(text: group.title)
                                ForEach(group.rows) { row in RowCard(row: row) }
                            }
                        }
                        if store.rows.isEmpty && store.loadError == nil { LoadingTape() }
                    }
                    .padding(24)
                }
                Footer()
            }
            Scanlines().ignoresSafeArea()
        }
        .frame(minWidth: 560, minHeight: 460)
        .sheet(item: $store.gate) { gate in GateSheet(gate: gate) }
    }

    struct Group: Identifiable {
        var id: String { title }
        var title: String
        var rows: [Row]
    }

    /// One section per host app, e.g. "DaVinci Resolve · OFX-plugins".
    private var groups: [Group] {
        let hosts = store.catalog?.hosts ?? [:]
        let grouped = Dictionary(grouping: store.rows) { row -> String in
            guard let name = row.target.host.flatMap({ hosts[$0]?.name }) else { return "Programmer" }
            return row.target.kind == .pluginBundle ? "\(name) · Plugins" : name
        }
        return grouped.keys.sorted().map { Group(title: $0, rows: grouped[$0]!.sorted { $0.product.name < $1.product.name }) }
    }
}

struct Header: View {
    @EnvironmentObject var store: HubStore

    var body: some View {
        HStack(spacing: 14) {
            GlitchMark(trigger: store.glitch).frame(width: 104, height: 21)
            Tag(text: "Hub", color: L21.accent)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Tag(text: store.checking ? "Søger…" : "Sidst tjekket", color: L21.muted)
                Text(store.lastChecked.map { Self.clock.string(from: $0) } ?? "--:--:--")
                    .font(L21.mono(13, .bold)).foregroundStyle(L21.ink).monospacedDigit()
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .bold))
                    .rotationEffect(.degrees(store.checking ? 360 : 0))
                    .animation(store.checking ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: store.checking)
            }
            .buttonStyle(L21ButtonStyle(kind: .secondary))
            .help("Søg efter opdateringer nu")
            .keyboardShortcut("r")
            .disabled(store.checking)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

struct UpdateAllBanner: View {
    @EnvironmentObject var store: HubStore
    var body: some View {
        HStack {
            StatusChip(kind: .update, text: "\(store.updatesAvailable.count) opdateringer klar")
            Spacer()
            Button("Opdater alle") { store.update(store.updatesAvailable.map(\.id)) }
                .buttonStyle(L21ButtonStyle())
        }
        .padding(14)
        .hardFrame(offset: 4, fill: L21.panel)
    }
}

struct RowCard: View {
    @EnvironmentObject var store: HubStore
    var row: Row
    @State private var showNotes = false

    private var job: Job? { store.jobs[row.id] }
    private var outcome: Outcome? { store.outcomes[row.id] }
    private var waitingForQuit: Bool { store.afterQuit.values.contains { $0.contains(row.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(row.product.name).font(.system(size: 17, weight: .bold)).foregroundStyle(L21.ink)
                        chip
                    }
                    if let summary = row.product.summary {
                        Text(summary).font(.system(size: 13)).foregroundStyle(L21.accentSoft).fixedSize(horizontal: false, vertical: true)
                    }
                    versionLine
                }
                Spacer(minLength: 12)
                action
            }

            if let job {
                VStack(alignment: .leading, spacing: 6) {
                    TapeProgress(value: job.step == .downloading ? job.progress : nil)
                    Tag(text: job.step == .waitingForAdmin ? "Godkend i macOS-dialogen" : job.step.label, color: L21.accent)
                }
            }

            if let outcome {
                HStack(alignment: .top, spacing: 8) {
                    Text(outcome.ok ? "▶" : "✕").font(L21.mono(11, .bold)).foregroundStyle(outcome.ok ? L21.accent : L21.red)
                    Text(outcome.message).font(.system(size: 12.5)).foregroundStyle(L21.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { store.dismissOutcome(row.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(L21ButtonStyle(kind: .quiet)).help("Skjul")
                }
            }

            if row.withdrawnInstalled {
                Notice(text: "Din version \(row.installed ?? "") er trukket tilbage. Opdater, eller læg en backup tilbage.", color: L21.amber)
            }

            if !notes.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showNotes.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(showNotes ? "▼" : "▶").font(L21.mono(9, .bold))
                        Text("Hvad er nyt").font(.system(size: 12.5, weight: .semibold))
                    }
                }
                .buttonStyle(L21ButtonStyle(kind: .quiet))
                if showNotes { ReleaseNotes(releases: notes) }
            }
        }
        .padding(16)
        .hardFrame(row.hasUpdate && row.isInstalled ? L21.accent : L21.line, offset: row.hasUpdate && row.isInstalled ? 6 : 4, fill: L21.panel)
        .contextMenu { menu }
    }

    /// What changed between the installed version and the newest, or the newest notes if nothing is newer.
    private var notes: [Release] {
        row.isInstalled && row.hasUpdate ? row.newReleases : Array(row.target.releases.prefix(1))
    }

    @ViewBuilder private var chip: some View {
        if job != nil {
            StatusChip(kind: .working, text: "Arbejder")
        } else if waitingForQuit {
            StatusChip(kind: .blocked, text: "Venter på Resolve")
        } else if let reason = row.blockedReason {
            StatusChip(kind: .blocked, text: reason)
        } else if !row.isInstalled {
            StatusChip(kind: .notInstalled, text: "Ikke installeret")
        } else if row.hasUpdate {
            StatusChip(kind: .update, text: "Ny version")
        } else {
            StatusChip(kind: .current, text: "Opdateret")
        }
    }

    @ViewBuilder private var versionLine: some View {
        HStack(spacing: 8) {
            Text(row.installed ?? "—").foregroundStyle(row.hasUpdate ? L21.muted : L21.ink)
            if row.hasUpdate, let new = row.candidate?.release.version {
                Text("→").foregroundStyle(L21.accent)
                Text(new).foregroundStyle(L21.ink)
            }
        }
        .font(L21.mono(14, .bold))
        .monospacedDigit()
        .accessibilityLabel(row.hasUpdate ? "Installeret \(row.installed ?? "ingen"), ny version \(row.candidate?.release.version ?? "")" : "Version \(row.installed ?? "ingen")")
    }

    @ViewBuilder private var action: some View {
        if job == nil && !waitingForQuit && row.hasUpdate {
            VStack(alignment: .trailing, spacing: 6) {
                Button(row.isInstalled ? "Opdater" : "Installer") { store.update([row.id]) }
                    .buttonStyle(L21ButtonStyle())
                    .keyboardShortcut(store.updatesAvailable.count == 1 && row.isInstalled ? .defaultAction : nil)
                if store.needsAdmin(row) {
                    Label("Kræver adgangskode", systemImage: "lock.fill")
                        .font(.system(size: 11)).foregroundStyle(L21.muted)
                        .help("Plugins ligger i \((row.target.install?.path as NSString?)?.deletingLastPathComponent ?? "en systemmappe"), som macOS beskytter. Du bliver bedt om din Mac-adgangskode.")
                }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if let path = row.target.install?.path, row.isInstalled {
            Button("Vis i Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        let backups = store.backups(for: row)
        if !backups.isEmpty {
            Menu("Læg backup tilbage") {
                ForEach(backups) { b in
                    Button("\(b.version) · \(b.date.formatted(date: .abbreviated, time: .shortened))") { store.restore(b, row: row) }
                }
            }
        }
        if let home = row.product.homepage, let url = URL(string: home) {
            Button("Åbn projektside") { NSWorkspace.shared.open(url) }
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().strokeBorder(L21.line, lineWidth: 1))
    }

    static func markdown(_ line: String) -> AttributedString {
        let text = line.hasPrefix("- ") ? "▸ " + line.dropFirst(2) : line
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
            Tag(text: "Spoler tapen…")
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
            HStack(spacing: 8) {
                Text("❚❚").font(L21.mono(12, .bold)).foregroundStyle(L21.amber)
                Tag(text: "Pause", color: L21.amber)
            }
            Text("\(gate.hostName) er åben").font(.system(size: 20, weight: .bold)).foregroundStyle(L21.ink)
            Text("\(names) kan ikke udskiftes, mens \(gate.hostName) kører. Gem dit projekt først. Hubben opdaterer selv, så snart programmet er lukket.")
                .font(.system(size: 13)).foregroundStyle(L21.accentSoft).fixedSize(horizontal: false, vertical: true)
            if gate.waitingForQuit {
                VStack(alignment: .leading, spacing: 6) {
                    TapeProgress(value: nil)
                    Tag(text: "Venter på at \(gate.hostName) lukker. Svar på gem-dialogen i programmet.", color: L21.accent)
                }
            }
            HStack(spacing: 12) {
                Button("Annullér") { store.cancelGate() }
                    .buttonStyle(L21ButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Når jeg lukker det") { store.deferUntilQuit(gate) }
                    .buttonStyle(L21ButtonStyle(kind: .secondary))
                    .disabled(gate.waitingForQuit)
                Button("Luk \(gate.hostName)") { store.quitHost(gate) }
                    .buttonStyle(L21ButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(gate.waitingForQuit)
            }
        }
        .padding(24)
        .frame(width: 460)
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
            Text("LINE21 Hub \(Config.hubVersion)").font(L21.mono(10.5, .regular)).foregroundStyle(L21.muted)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(L21.line).frame(height: 1) }
    }
}

struct SupportView: View {
    @EnvironmentObject var store: HubStore
    var support: Support

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(support.title).font(.system(size: 16, weight: .bold)).foregroundStyle(L21.ink)
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
            Tag(text: "Betaling åbner i din browser", color: L21.muted)
        }
        .padding(18)
        .frame(width: 320)
        .background(L21.bg)
    }

    private func price(_ t: Support.Tier) -> String {
        guard let amount = t.amount else { return "Du vælger" }
        return amount.formatted(.currency(code: t.currency ?? "DKK").precision(.fractionLength(0)))
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: HubStore
    @State private var url = ""

    var body: some View {
        Form {
            Section {
                Picker("Udgivelser", selection: $store.channel) {
                    Text("Stabile").tag("stable")
                    Text("Stabile og beta").tag("beta")
                }
                Toggle("Vis en notifikation, når der er nyt", isOn: $store.notificationsOn)
                Toggle("Start LINE21 Hub ved login", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
            }
            Section {
                Toggle("Del anonym brugsstatistik", isOn: $store.telemetryOn)
                Text("Hjælper LINE21 med at se, hvilke versioner der bruges, og om opdateringer fejler. Hubben sender et tilfældigt id, macOS- og programversioner. Aldrig navn, e-mail, filer eller projekter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Vis backups i Finder") {
                    try? FileManager.default.createDirectory(at: Installer.defaultBackupRoot, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Installer.defaultBackupRoot)
                }
                TextField("Katalogserver", text: $url, prompt: Text(Config.defaultCatalogURL.absoluteString))
                    .onSubmit {
                        store.catalogURLString = url
                        store.reconnect()
                    }
            } header: { Text("Avanceret") }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { url = store.catalogURLString }
    }
}
