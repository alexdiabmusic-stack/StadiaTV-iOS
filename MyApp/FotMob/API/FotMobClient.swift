import Foundation
#if DEBUG
import OSLog
#endif

nonisolated protocol FotMobClientProtocol: Sendable {
    func leagues(id: Int, season: String?) async throws -> FotMobValue
    func matches(date: String, timezone: String?) async throws -> FotMobValue
    func matchDetails(matchId: String) async throws -> FotMobValue
    /// Returns raw bytes — the response is a gzip-compressed static file (verified
    /// live 2026-09-24: magic bytes `1f 8b`, no `Content-Encoding` header, so
    /// `URLSession` never auto-decompresses it), not JSON. `FotMobCommentaryMapper`
    /// owns decompression + decoding.
    func liveTickerRaw(ltcUrl: String) async throws -> Data
}

/// FotMob's keyless web JSON API. No auth, no user credential — owns retry/backoff
/// and honors `Cache-Control` (Step 33) rather than forcing a faster interval or
/// appending cache-busting parameters. Unlike `LaLigaClient`, there is no 401
/// circuit breaker: a keyless API has nothing to reject a credential on, so a
/// sustained block surfaces as `.blocked`/`.http` instead.
actor FotMobClient {
    static let shared = FotMobClient()
    private let session: URLSession
    private var retryNotBefore: Date?

    init(session: URLSession = .shared) { self.session = session }

    func leagues(id: Int, season: String? = nil) async throws -> FotMobValue { try await getValue(.leagues(id: id, season: season)) }
    func matches(date: String, timezone: String? = nil) async throws -> FotMobValue { try await getValue(.matches(date: date, timezone: timezone)) }
    func matchDetails(matchId: String) async throws -> FotMobValue { try await getValue(.matchDetails(matchId: matchId)) }

    func liveTickerRaw(ltcUrl: String) async throws -> Data {
        try await getData(URLRequestSource.direct(ltcUrl))
    }

    private enum URLRequestSource { case endpoint(FotMobEndpoint), direct(String) }

    private func resolvedURL(_ source: URLRequestSource) throws -> URL {
        switch source {
        case .endpoint(let endpoint): return try endpoint.url()
        case .direct(let raw):
            guard let url = URL(string: raw) else { throw FotMobAPIError.invalidURL }
            return url
        }
    }

    private func getValue(_ endpoint: FotMobEndpoint) async throws -> FotMobValue {
        let data = try await fetch(.endpoint(endpoint))
        do { return try JSONDecoder().decode(FotMobValue.self, from: data) }
        catch { throw FotMobAPIError.decoding(String(describing: error)) }
    }

    private func getData(_ source: URLRequestSource) async throws -> Data {
        try await fetch(source)
    }

    private func fetch(_ source: URLRequestSource) async throws -> Data {
        let url = try resolvedURL(source)
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw FotMobAPIError.rateLimited(deadline) }
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // A browser UA — FotMob's web routes are not documented for non-browser
            // clients (verified reachable live 2026-09-24 with this UA).
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw FotMobAPIError.invalidResponse }
                if http.statusCode == 429 {
                    let deadline = Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"))
                    retryNotBefore = deadline
                    throw FotMobAPIError.rateLimited(deadline)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                if http.statusCode == 403 || http.statusCode == 404 { throw FotMobAPIError.notFound(url.path) }
                guard (200...299).contains(http.statusCode) else { throw FotMobAPIError.http(http.statusCode, nil) }
                return data
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw FotMobAPIError.blocked }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw FotMobAPIError.invalidResponse
    }

    private static func retryDate(_ value: String?) -> Date {
        if let value, let seconds = Double(value) { return Date().addingTimeInterval(max(1, seconds)) }
        return Date().addingTimeInterval(60)
    }
}
extension FotMobClient: FotMobClientProtocol {}
