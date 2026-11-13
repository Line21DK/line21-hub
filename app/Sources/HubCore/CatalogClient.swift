import Foundation

/// Fetches the catalog with ETag caching and keeps the last good copy on disk for offline starts.
public actor CatalogClient {
    public let baseURL: URL
    private let cacheFile: URL
    private var etag: String?
    private var cached: Catalog?

    public init(baseURL: URL, cacheDirectory: URL) {
        self.baseURL = baseURL
        self.cacheFile = cacheDirectory.appendingPathComponent("catalog.json")
        if let data = try? Data(contentsOf: cacheFile), let c = try? JSONDecoder().decode(Catalog.self, from: data) {
            cached = c
        }
    }

    public var lastKnown: Catalog? { cached }

    public func fetch(channel: String) async throws -> Catalog {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/catalog"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "channel", value: channel)]
        var request = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if let etag, cached?.channel == channel { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 304, let cached { return cached }
        guard status == 200 else { throw URLError(.badServerResponse) }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        cached = catalog
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
        return catalog
    }
}
