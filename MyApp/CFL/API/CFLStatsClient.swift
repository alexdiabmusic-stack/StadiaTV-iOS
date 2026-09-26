import Foundation
import OSLog

/// League leaders only (verified live: `api.stats.cfl.ca/stats/leaders/{year}` returns
/// offence/defence/special_teams groups for real 2026 data) — a separate host from
/// `CFLClient`, never consulted by the live Game Centre poll path.
actor CFLStatsClient {
    static let shared = CFLStatsClient()
    private let session: URLSession
    private let baseURL: String
    private var cache: [String: (Date, Data)] = [:]

    init(session: URLSession? = nil, baseURL: String = "https://api.stats.cfl.ca") {
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.baseURL = baseURL
    }

    func leaders(year: Int) async throws -> CFLValue { try await get(.leaders(year: year), maxAge: 900) }

    private func get(_ endpoint: CFLEndpoint, maxAge: TimeInterval) async throws -> CFLValue {
        let url = try endpoint.url(base: baseURL)
        let key = url.absoluteString
        if maxAge > 0, let (fetchedAt, data) = cache[key], Date().timeIntervalSince(fetchedAt) < maxAge,
           let decoded = try? JSONDecoder().decode(CFLValue.self, from: data) { return decoded }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CFLAPIError.invalidResponse }
        if http.statusCode == 403 { throw CFLAPIError.blocked(host: "api.stats.cfl.ca", status: 403) }
        guard (200...299).contains(http.statusCode) else { throw CFLAPIError.http(http.statusCode) }
        do {
            let decoded = try JSONDecoder().decode(CFLValue.self, from: data)
            cache[key] = (Date(), data)
            return decoded
        } catch {
            Logger(subsystem: "BannerTV", category: "CFLStats").error("Decode \(endpoint.path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw CFLAPIError.decoding(String(describing: error))
        }
    }
}
