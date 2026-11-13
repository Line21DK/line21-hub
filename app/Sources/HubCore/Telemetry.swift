import Foundation

/// Anonymous usage events: a random install id, the Hub/macOS version, and what was checked,
/// downloaded or installed. No names, emails, file paths or IP addresses. Can be turned off in Settings.
public actor Telemetry {
    public struct Event: Codable, Sendable {
        public var type: String
        public var targetId: String?
        public var fromVersion: String?
        public var toVersion: String?
        public var error: String?
        public var data: [String: [String: String?]]?
        public var ts: String

        public init(type: String, targetId: String? = nil, fromVersion: String? = nil, toVersion: String? = nil,
                    error: String? = nil, data: [String: [String: String?]]? = nil) {
            self.type = type
            self.targetId = targetId
            self.fromVersion = fromVersion
            self.toVersion = toVersion
            self.error = error
            self.data = data
            self.ts = ISO8601DateFormatter().string(from: Date())
        }
    }

    private struct Batch: Encodable {
        var installId: String
        var hubVersion: String
        var os: String
        var arch: String
        var events: [Event]
    }

    public let installId: String
    private let endpoint: URL
    private let hubVersion: String
    private var queue: [Event] = []
    public var enabled: Bool

    public init(baseURL: URL, installId: String, hubVersion: String, enabled: Bool) {
        self.endpoint = baseURL.appendingPathComponent("v1/events")
        self.installId = installId
        self.hubVersion = hubVersion
        self.enabled = enabled
    }

    public func setEnabled(_ on: Bool) {
        enabled = on
        if !on { queue.removeAll() }
    }

    public func track(_ event: Event) async {
        guard enabled else { return }
        queue.append(event)
        await flush()
    }

    public func flush() async {
        guard enabled, !queue.isEmpty else { return }
        let events = Array(queue.prefix(50))
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let batch = Batch(installId: installId, hubVersion: hubVersion, os: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                          arch: Self.machineArch, events: events)
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(batch)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Drop on success and on a 4xx (a bad event will never succeed); keep on network or 5xx errors.
            if status < 500 { queue.removeFirst(min(events.count, queue.count)) }
        } catch {
            if queue.count > 200 { queue.removeFirst(queue.count - 200) }
        }
    }

    public static var machineArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }
}
