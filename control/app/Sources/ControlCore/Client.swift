import Foundation

/// Talks to the LINE21 Control server with the CONTROL_TOKEN as a bearer token.
public struct ControlClient {
    public enum Failure: Error, LocalizedError, Equatable {
        case unauthorized, tooManyAttempts, server(String), offline(String)
        public var errorDescription: String? {
            switch self {
            case .unauthorized: return "The token was not accepted."
            case .tooManyAttempts: return "Too many wrong tokens. Wait 10 minutes."
            case .server(let m): return m
            case .offline(let m): return "Can't reach the server: \(m)"
            }
        }
    }

    public var baseURL: URL
    public var token: String
    public var session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func overview() async throws -> Overview { try await get("v1/overview") }

    public func subscribers(query: String = "", status: String = "") async throws -> [Subscriber] {
        let list: SubscriberList = try await get("v1/subscribers", [URLQueryItem(name: "q", value: query), URLQueryItem(name: "status", value: status)])
        return list.subscribers
    }

    public func subscriber(_ id: String) async throws -> SubscriberDetail { try await get("v1/subscribers/\(id)") }

    public func hubStats(days: Int) async throws -> HubStats { try await get("v1/hub-stats", [URLQueryItem(name: "days", value: String(days))]) }

    func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Failure.offline(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try JSONDecoder().decode(T.self, from: data)
        case 401: throw Failure.unauthorized
        case 429: throw Failure.tooManyAttempts
        default: throw Failure.server((try? JSONDecoder().decode(APIError.self, from: data))?.error ?? "Server answered \(status).")
        }
    }
}
