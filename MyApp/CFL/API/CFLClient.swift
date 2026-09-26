import Foundation
import OSLog

/// Primary CFL source — `echo.pims.cfl.ca` is keyless and reachable with no backend
/// (verified live this session: `/api/seasons`, `/api/teams`, `/api/venues`,
/// `/api/fixtures`, `/api/teams/{id}/roster`, `/api/stats/teamrecords`,
/// `/api/stats/playerrecords`, `/api/standings/{year}` all returned real 2026 data).
nonisolated protocol CFLClientProtocol: Sendable {
    func get<T: Decodable & Sendable>(_ endpoint: CFLEndpoint, as type: T.Type, maxAge: TimeInterval) async throws -> T
}

actor CFLClient {
    static let shared = CFLClient()
    private let session: URLSession
    private let baseURL: String
    private var retryNotBefore: Date?
    private var cache: [String: (Date, Data)] = [:]

    init(session: URLSession? = nil, baseURL: String = "https://echo.pims.cfl.ca") {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .useProtocolCachePolicy
            configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024, diskPath: "BannerTV/CFL/http-cache")
            self.session = URLSession(configuration: configuration)
        }
        self.baseURL = baseURL
    }

    func get<T: Decodable & Sendable>(_ endpoint: CFLEndpoint, as type: T.Type = T.self, maxAge: TimeInterval = 0) async throws -> T {
        let url = try endpoint.url(base: baseURL)
        let key = url.absoluteString
        if maxAge > 0, let (fetchedAt, data) = cache[key], Date().timeIntervalSince(fetchedAt) < maxAge {
            if let decoded = try? JSONDecoder().decode(T.self, from: data) { return decoded }
        }
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw CFLAPIError.rateLimited(deadline) }
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BannerTV/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw CFLAPIError.invalidResponse }
                if http.statusCode == 429 {
                    let deadline = Date().addingTimeInterval(30)
                    retryNotBefore = deadline
                    throw CFLAPIError.rateLimited(deadline)
                }
                if http.statusCode == 403 {
                    retryNotBefore = Date().addingTimeInterval(300)
                    throw CFLAPIError.blocked(host: "echo.pims.cfl.ca", status: 403)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                guard (200...299).contains(http.statusCode) else { throw CFLAPIError.http(http.statusCode) }
                do {
                    let decoded = try JSONDecoder().decode(T.self, from: data)
                    if maxAge > 0 { cache[key] = (Date(), data) }
                    return decoded
                } catch {
                    Logger(subsystem: "BannerTV", category: "CFL").error("Decode \(endpoint.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw CFLAPIError.decoding(String(describing: error))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw CFLAPIError.invalidResponse
    }
}
extension CFLClient: CFLClientProtocol {}
