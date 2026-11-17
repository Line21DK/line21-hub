import ControlCore
import Foundation
import Security

enum ControlTab: String, CaseIterable, Identifiable {
    case subscribers = "Subscribers"
    case hubStats = "Hub Stats"
    var id: String { rawValue }
}

@MainActor
final class ControlStore: ObservableObject {
    @Published var serverURL: String
    @Published private(set) var loggedIn = false
    @Published var tab: ControlTab = .subscribers { didSet { Task { await refresh() } } }

    @Published var overview = Overview()
    @Published var subscribers: [Subscriber] = []
    @Published var query = ""
    @Published var statusFilter = "" { didSet { Task { await loadSubscribers() } } }
    @Published var selected: String? { didSet { Task { await loadDetail() } } }
    @Published var detail: SubscriberDetail?

    @Published var hubStats: HubStats?
    @Published var days = 30 { didSet { Task { await loadHubStats() } } }

    @Published var loading = false
    @Published var error: String?
    @Published var lastUpdated: Date?
    @Published var glitch = 0

    private var token: String?
    private var timer: Timer?
    private var searchTask: Task<Void, Never>?

    static let defaultURL = Bundle.main.object(forInfoDictionaryKey: "LINE21ControlURL") as? String ?? ""

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? Self.defaultURL
        token = Keychain.read()
        loggedIn = token != nil && client != nil
    }

    private var client: ControlClient? {
        guard let token, let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { return nil }
        return ControlClient(baseURL: url, token: token)
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(quiet: true) }
        }
    }

    /// Checks the token against the server before saving it.
    func login(url: String, token newToken: String) async -> String? {
        let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: url.trimmingCharacters(in: .whitespaces)), base.scheme?.hasPrefix("http") == true else { return "Enter the server address, starting with https://" }
        do {
            _ = try await ControlClient(baseURL: base, token: trimmed).overview()
        } catch {
            return error.localizedDescription
        }
        serverURL = url.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        Keychain.save(trimmed)
        token = trimmed
        loggedIn = true
        glitch += 1
        await refresh()
        return nil
    }

    func logout() {
        Keychain.delete()
        token = nil
        loggedIn = false
        overview = Overview()
        subscribers = []
        detail = nil
        selected = nil
        hubStats = nil
    }

    func refresh(quiet: Bool = false) async {
        guard loggedIn else { return }
        if !quiet { loading = true }
        defer { loading = false }
        switch tab {
        case .subscribers:
            await loadSubscribers()
            await loadDetail()
        case .hubStats:
            await loadHubStats()
        }
    }

    func search(_ text: String) {
        query = text
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await loadSubscribers()
        }
    }

    func loadSubscribers() async {
        guard let client else { return }
        await run {
            async let o = client.overview()
            async let list = client.subscribers(query: self.query, status: self.statusFilter)
            self.overview = try await o
            self.subscribers = try await list
        }
    }

    func loadDetail() async {
        guard let client, let id = selected else { detail = nil; return }
        await run {
            let d = try await client.subscriber(id)
            if self.selected == id { self.detail = d }
        }
    }

    func loadHubStats() async {
        guard let client else { return }
        await run { self.hubStats = try await client.hubStats(days: self.days) }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
            error = nil
            lastUpdated = Date()
        } catch ControlClient.Failure.unauthorized {
            logout()
            error = "The token was not accepted. Log in again."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The Control token lives in the login Keychain, never in a file.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dk.line21.control",
        kSecAttrAccount as String: "control-token",
    ]

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
