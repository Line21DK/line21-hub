import AppKit
import Charts
import ControlCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: ControlStore

    var body: some View {
        Group {
            if store.loggedIn { MainView() } else { LoginView() }
        }
        .background(L21.bg)
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - Login

struct LoginView: View {
    @EnvironmentObject var store: ControlStore
    @State private var url = ""
    @State private var token = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                GlitchMark(trigger: store.glitch).frame(width: 90, height: 18)
                Text("Control").font(.system(size: 15, weight: .semibold)).foregroundStyle(L21.accentSoft)
            }
            Text("Private to LINE21. Log in with the CONTROL_TOKEN from the Railway control service.")
                .font(.system(size: 12.5)).foregroundStyle(L21.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Tag(text: "Server", color: L21.muted)
                TextField("https://…", text: $url).textFieldStyle(.plain).field()
            }
            VStack(alignment: .leading, spacing: 6) {
                Tag(text: "Token", color: L21.muted)
                SecureField("CONTROL_TOKEN", text: $token).textFieldStyle(.plain).field()
                    .onSubmit(submit)
            }
            if let error = message ?? store.error {
                Text(error).font(L21.mono(11.5, .regular)).foregroundStyle(L21.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(busy ? "Checking…" : "Log In", action: submit)
                    .buttonStyle(L21ButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || token.isEmpty || url.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(L21.panel)
        .overlay(Rectangle().strokeBorder(L21.line, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { url = store.serverURL }
    }

    private func submit() {
        busy = true
        message = nil
        Task {
            message = await store.login(url: url, token: token)
            busy = false
        }
    }
}

// MARK: - Main window

struct MainView: View {
    @EnvironmentObject var store: ControlStore

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider().overlay(L21.line)
            if let error = store.error {
                HStack(spacing: 8) {
                    Text("!").font(L21.mono(11, .bold)).foregroundStyle(L21.amber)
                    Text(error).font(.system(size: 12)).foregroundStyle(L21.amber)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(L21.amber.opacity(0.08))
            }
            switch store.tab {
            case .subscribers: SubscribersView()
            case .hubStats: HubStatsView()
            }
        }
    }
}

struct Header: View {
    @EnvironmentObject var store: ControlStore

    var body: some View {
        HStack(spacing: 14) {
            GlitchMark(trigger: store.glitch).frame(width: 72, height: 14)
            Text("Control").font(.system(size: 13, weight: .semibold)).foregroundStyle(L21.accentSoft)
            TabSwitch()
            Spacer()
            if let d = store.lastUpdated {
                Text("Updated \(Self.clock.string(from: d))").font(.system(size: 11.5)).foregroundStyle(L21.muted).monospacedDigit()
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(L21ButtonStyle(kind: .quiet))
            .help("Refresh (⌘R)")
            .disabled(store.loading)
            Menu {
                Button("Log Out") { store.logout() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(L21.muted)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// Two square tabs, the active one filled, like the website's tags.
struct TabSwitch: View {
    @EnvironmentObject var store: ControlStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ControlTab.allCases) { tab in
                Button { store.tab = tab } label: {
                    Text(tab.rawValue.uppercased()).font(L21.mono(10.5)).tracking(1.4)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(store.tab == tab ? L21.onAccent : L21.muted)
                        .background(store.tab == tab ? L21.accent : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().strokeBorder(L21.line, lineWidth: 1))
    }
}

// MARK: - Building blocks

struct Tile: View {
    var label: String
    var value: String
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Tag(text: label, color: L21.accentSoft)
            Text(value).font(L21.mono(20, .bold)).foregroundStyle(warn ? L21.amber : L21.ink)
                .lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

struct TileRow: View {
    var tiles: [Tile]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { i, tile in
                if i > 0 { Rectangle().fill(L21.line).frame(width: 1) }
                tile
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(L21.panel)
        .overlay(Rectangle().strokeBorder(L21.line, lineWidth: 1))
    }
}

struct StatusBadge: View {
    var status: String?
    var body: some View {
        Text(Format.status(status).uppercased()).font(L21.mono(10)).tracking(1.1)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Rectangle().strokeBorder(color, lineWidth: 1))
            .fixedSize()
    }
    private var color: Color {
        switch status {
        case "active", "paid": return L21.accent
        case "trialing": return L21.cyan
        case "past_due", "unpaid", "failed", "open": return L21.amber
        default: return L21.muted
        }
    }
}

struct Panel<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Tag(text: title, color: L21.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(L21.panel)
        .overlay(Rectangle().strokeBorder(L21.line, lineWidth: 1))
    }
}

extension View {
    func field() -> some View {
        self.font(.system(size: 13))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(L21.bg)
            .overlay(Rectangle().strokeBorder(L21.line, lineWidth: 1))
    }
}

// MARK: - Subscribers

struct SubscribersView: View {
    @EnvironmentObject var store: ControlStore
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TileRow(tiles: [
                Tile(label: "Active", value: "\(store.overview.active)"),
                Tile(label: "In trial", value: "\(store.overview.trialing)"),
                Tile(label: "MRR", value: Format.money(store.overview.mrr)),
                Tile(label: "Past due", value: "\(store.overview.pastDue)", warn: store.overview.pastDue > 0),
                Tile(label: "Canceled · 30d", value: "\(store.overview.canceled30d)"),
            ])
            HStack(spacing: 8) {
                TextField("Search email, name or customer id", text: $search).textFieldStyle(.plain).field()
                    .onChange(of: search) { store.search($0) }
                Picker("", selection: $store.statusFilter) {
                    Text("All statuses").tag("")
                    Text("Active").tag("active")
                    Text("In trial").tag("trialing")
                    Text("Past due").tag("past_due")
                    Text("Canceled").tag("canceled")
                }
                .labelsHidden().fixedSize()
            }
            HStack(alignment: .top, spacing: 14) {
                SubscriberListView()
                if store.selected != nil {
                    DetailPanel().frame(width: 340)
                }
            }
        }
        .padding(20)
        .onAppear { search = store.query }
    }
}

struct SubscriberListView: View {
    @EnvironmentObject var store: ControlStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(store.subscribers.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Rectangle().fill(L21.line).frame(height: 1) }
                    SubscriberRow(s: s, selected: store.selected == s.id)
                        .onTapGesture { store.selected = store.selected == s.id ? nil : s.id }
                }
                if store.subscribers.isEmpty {
                    Text(store.query.isEmpty && store.statusFilter.isEmpty
                         ? "No subscribers yet. They appear as soon as Stripe sends its first webhook."
                         : "No matches.")
                        .font(.system(size: 12.5)).foregroundStyle(L21.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            }
        }
        .background(L21.panel)
        .overlay(Rectangle().strokeBorder(L21.line, lineWidth: 1))
    }
}

struct SubscriberRow: View {
    var s: Subscriber
    var selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(Format.initials(s.name ?? s.title)).font(L21.mono(11, .bold))
                .foregroundStyle(selected ? L21.onAccent : L21.accent)
                .frame(width: 30, height: 30)
                .background(selected ? L21.accent : Color.clear)
                .overlay(Rectangle().strokeBorder(L21.accent, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(L21.ink).lineLimit(1)
                if !s.subtitle.isEmpty { Text(s.subtitle).font(.system(size: 11.5)).foregroundStyle(L21.muted).lineLimit(1) }
            }
            Spacer(minLength: 10)
            StatusBadge(status: s.status)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.plan(product: s.product, interval: s.interval)).font(.system(size: 12)).foregroundStyle(L21.accentSoft)
                Text(Format.money(s.amount, s.currency)).font(L21.mono(11.5, .regular)).foregroundStyle(L21.muted)
            }
            .frame(width: 140, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 2) {
                Text(s.endsAt != nil ? "ENDS" : "RENEWS").font(L21.mono(9.5)).tracking(1).foregroundStyle(L21.muted)
                Text(Format.day(s.endsAt ?? s.renewsAt)).font(L21.mono(11.5, .regular)).foregroundStyle(L21.accentSoft)
            }
            .frame(width: 86, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(selected ? L21.accent.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }
}

struct DetailPanel: View {
    @EnvironmentObject var store: ControlStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let d = store.detail, d.customer.id == store.selected {
                    HStack {
                        Tag(text: d.livemode ? "Customer" : "Customer · Test", color: L21.muted)
                        Spacer()
                        Button { store.selected = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(L21ButtonStyle(kind: .quiet)).help("Close")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.customer.name ?? d.customer.email ?? d.customer.id).font(.system(size: 15, weight: .semibold)).foregroundStyle(L21.ink)
                        if let email = d.customer.email { Text(email).font(.system(size: 12)).foregroundStyle(L21.accentSoft).textSelection(.enabled) }
                        Text([d.customer.country, d.customer.id].compactMap { $0 }.joined(separator: " · "))
                            .font(L21.mono(11, .regular)).foregroundStyle(L21.muted).textSelection(.enabled)
                    }
                    Button(d.livemode ? "Open in Stripe ↗" : "Open in Stripe (test) ↗") { NSWorkspace.shared.open(d.stripeURL) }
                        .buttonStyle(L21ButtonStyle(kind: .secondary))

                    Tag(text: "Subscriptions", color: L21.muted)
                    if d.subscriptions.isEmpty { Text("No subscriptions.").font(.system(size: 12)).foregroundStyle(L21.muted) }
                    ForEach(d.subscriptions) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(Format.plan(product: s.product, interval: s.interval)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(L21.ink)
                                Spacer()
                                StatusBadge(status: s.status)
                            }
                            Text("\(Format.money(s.amount, s.currency)) · \(s.status == "trialing" ? "converts" : s.cancelAtPeriodEnd == true ? "ends" : "renews") \(Format.day(s.nextDate))")
                                .font(L21.mono(11, .regular)).foregroundStyle(L21.accentSoft)
                            Text("Started \(Format.day(s.createdAt))").font(L21.mono(11, .regular)).foregroundStyle(L21.muted)
                        }
                        .padding(10).overlay(Rectangle().strokeBorder(L21.line, lineWidth: 1))
                    }

                    Tag(text: "Payments", color: L21.muted)
                    if d.invoices.isEmpty { Text("No payments yet.").font(.system(size: 12)).foregroundStyle(L21.muted) }
                    ForEach(d.invoices) { i in
                        HStack(spacing: 8) {
                            Text(Format.day(i.date)).font(L21.mono(11, .regular)).foregroundStyle(L21.accentSoft)
                            StatusBadge(status: i.status)
                            Spacer()
                            Text(Format.money(i.amount, i.currency)).font(L21.mono(11.5, .regular)).foregroundStyle(L21.ink)
                            if let link = i.hostedUrl.flatMap(URL.init(string:)) {
                                Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "arrow.up.right.square") }
                                    .buttonStyle(L21ButtonStyle(kind: .quiet)).help("Open invoice")
                            }
                        }
                    }
                } else {
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(L21.muted)
                }
            }
            .padding(14)
        }
        .background(L21.panel)
        .overlay(Rectangle().strokeBorder(L21.line, lineWidth: 1))
    }
}

// MARK: - Hub stats

struct HubStatsView: View {
    @EnvironmentObject var store: ControlStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Tag(text: "Anonymous usage from LINE21 Hub", color: L21.muted)
                    Spacer()
                    Picker("", selection: $store.days) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .labelsHidden().fixedSize()
                }
                if let s = store.hubStats {
                    TileRow(tiles: [
                        Tile(label: "Active Hubs", value: "\(s.activeInstalls)"),
                        Tile(label: "Downloads", value: "\(s.total(s.downloads))"),
                        Tile(label: "Installs", value: "\(s.total(s.installs))"),
                        Tile(label: "Failures", value: "\(s.total(s.failures))", warn: s.total(s.failures) > 0),
                    ])
                    Panel(title: "Active Hubs per day") {
                        if s.daily.isEmpty {
                            Text("No data yet.").font(.system(size: 12)).foregroundStyle(L21.muted)
                        } else {
                            Chart(s.daily) { d in
                                BarMark(x: .value("Day", d.day), y: .value("Active", d.active)).foregroundStyle(L21.teal)
                            }
                            .chartXAxis(.hidden)
                            .frame(height: 120)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        Panel(title: "Installed right now") { Breakdown(stats: s, table: s.installed) }
                        Panel(title: "Downloads per version") { Breakdown(stats: s, table: s.downloads) }
                        Panel(title: "Completed updates") { Breakdown(stats: s, table: s.installs) }
                        Panel(title: "Failures") { Breakdown(stats: s, table: s.failures) }
                        Panel(title: "Host apps") { Breakdown(stats: s, table: s.hostVersions) }
                        Panel(title: "macOS and Hub version") { Breakdown(stats: s, table: ["macOS": s.osVersions, "LINE21 Hub": s.hubVersions], labels: false) }
                    }
                } else if store.error == nil {
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(L21.muted)
                }
            }
            .padding(20)
        }
    }
}

/// A target name, then its values with counts, largest first.
struct Breakdown: View {
    var stats: HubStats
    var table: [String: [String: Int]]
    var labels = true

    var body: some View {
        if table.isEmpty {
            Text("No data yet.").font(.system(size: 12)).foregroundStyle(L21.muted)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(table.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(labels ? stats.label(key) : key).font(.system(size: 12, weight: .semibold)).foregroundStyle(L21.ink)
                        ForEach(table[key, default: [:]].sorted { $0.value > $1.value }, id: \.key) { item in
                            HStack {
                                Text(item.key).font(L21.mono(11.5, .regular)).foregroundStyle(L21.accentSoft)
                                if stats.targets?[key]?.latest == item.key { Text("▶ latest").font(L21.mono(10, .regular)).foregroundStyle(L21.muted) }
                                Spacer()
                                Text("\(item.value)").font(L21.mono(11.5)).foregroundStyle(L21.ink).monospacedDigit()
                            }
                            Rectangle().fill(L21.line).frame(height: 1)
                        }
                    }
                }
            }
        }
    }
}
