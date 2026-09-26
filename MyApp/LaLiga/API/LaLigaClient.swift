import Foundation
#if DEBUG
import OSLog
#endif

nonisolated protocol LaLigaClientProtocol: Sendable {
    func competitions() async throws -> LaLigaValue
    func subscriptions(offset: Int, limit: Int) async throws -> LaLigaValue
    func rounds(subscriptionSlug: String) async throws -> LaLigaValue
    func standing(subscriptionSlug: String) async throws -> LaLigaValue
    func matches(subscriptionSlug: String, competition: String, limit: Int, offset: Int) async throws -> LaLigaValue
    func squad(teamSlug: String, subscriptionSlug: String) async throws -> LaLigaValue
    func playerStats(subscriptionSlug: String, limit: Int, offset: Int) async throws -> LaLigaValue
}

/// LaLiga's official-site API, fronted by Azure API Management. Public website key
/// (`LaLigaProviderConfiguration`), no user auth. Owns retry/backoff, 429 cooldown,
/// and the 401 circuit breaker (Step 34) so none of that leaks into mapping or UI code.
actor LaLigaClient {
    static let shared = LaLigaClient()
    private let session: URLSession
    private var retryNotBefore: Date?
    /// Set once a 401 is observed; requests short-circuit for this cooldown instead
    /// of retrying every poll tick — a rotated public key is never something a user
    /// or a retry loop can fix (Step 34).
    private var unauthorizedUntil: Date?

    init(session: URLSession = .shared) { self.session = session }

    func competitions() async throws -> LaLigaValue { try await get(.competitions()) }
    func subscriptions(offset: Int = 0, limit: Int = 100) async throws -> LaLigaValue { try await get(.subscriptions(offset: offset, limit: limit)) }
    func rounds(subscriptionSlug: String) async throws -> LaLigaValue { try await get(.rounds(subscriptionSlug: subscriptionSlug)) }
    func standing(subscriptionSlug: String) async throws -> LaLigaValue { try await get(.standing(subscriptionSlug: subscriptionSlug)) }
    func matches(subscriptionSlug: String, competition: String = LaLigaProviderConfiguration.competitionSlug, limit: Int = 100, offset: Int = 0) async throws -> LaLigaValue {
        try await get(.matches(subscriptionSlug: subscriptionSlug, competition: competition, limit: limit, offset: offset))
    }
    func squad(teamSlug: String, subscriptionSlug: String) async throws -> LaLigaValue { try await get(.squad(teamSlug: teamSlug, subscriptionSlug: subscriptionSlug)) }
    func playerStats(subscriptionSlug: String, limit: Int = 100, offset: Int = 0) async throws -> LaLigaValue { try await get(.playerStats(subscriptionSlug: subscriptionSlug, limit: limit, offset: offset)) }

    private func get(_ endpoint: LaLigaEndpoint) async throws -> LaLigaValue {
        if let unauthorizedUntil, unauthorizedUntil > Date() { throw LaLigaAPIError.unauthorized }
        let url = try endpoint.url()
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw LaLigaAPIError.rateLimited(deadline) }
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            request.setValue(LaLigaProviderConfiguration.subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BannerTV/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw LaLigaAPIError.invalidResponse }
                if http.statusCode == 401 {
                    unauthorizedUntil = Date().addingTimeInterval(600)
                    #if DEBUG
                    Logger(subsystem: "BannerTV", category: "LaLiga").error("LaLiga APIM key rejected (401) — official provider disabled for 10 minutes.")
                    #endif
                    throw LaLigaAPIError.unauthorized
                }
                if http.statusCode == 429 {
                    let deadline = Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"))
                    retryNotBefore = deadline
                    throw LaLigaAPIError.rateLimited(deadline)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                if http.statusCode == 404 { throw LaLigaAPIError.notFound(endpoint.path) }
                guard (200...299).contains(http.statusCode) else { throw LaLigaAPIError.http(http.statusCode, nil) }
                unauthorizedUntil = nil
                do { return try JSONDecoder().decode(LaLigaValue.self, from: data) }
                catch {
                    #if DEBUG
                    Logger(subsystem: "BannerTV", category: "LaLiga").error("Decode \(endpoint.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    #endif
                    throw LaLigaAPIError.decoding(String(describing: error))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw LaLigaAPIError.invalidResponse
    }

    private static func retryDate(_ value: String?) -> Date {
        if let value, let seconds = Double(value) { return Date().addingTimeInterval(max(1, seconds)) }
        return Date().addingTimeInterval(60)
    }
}
extension LaLigaClient: LaLigaClientProtocol {}
