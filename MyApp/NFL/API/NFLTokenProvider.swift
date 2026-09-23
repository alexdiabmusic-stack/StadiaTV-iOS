import Foundation

actor NFLTokenProvider {
    static let shared = NFLTokenProvider()
    private struct Entry: Sendable { let token: String; let expires: Date }
    private var cached: Entry?
    private var failedUntil: Date?
    private var flight: (UUID, Task<Entry, Error>)?
    private let session: URLSession
    private let configuration: NFLClientConfiguration
    private let now: @Sendable () -> Date
    init(session: URLSession = URLSession(configuration: .ephemeral), configuration: NFLClientConfiguration = .init(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session; self.configuration = configuration; self.now = now
    }
    func validToken() async throws -> String {
        try Task.checkCancellation()
        if let cached, cached.expires.timeIntervalSince(now()) > 120 { return cached.token }
        return try await mint()
    }
    /// A late 401 for an old token must not invalidate the replacement another request already minted.
    func forceRefresh(rejectedToken: String? = nil) async throws -> String {
        if let rejectedToken, let cached, cached.token != rejectedToken,
           cached.expires.timeIntervalSince(now()) > 120 { return cached.token }
        cached = nil
        return try await mint()
    }
    func clear() { cached = nil; flight?.1.cancel(); flight = nil }
    private func mint() async throws -> String {
        if let flight { let value = try await flight.1.value; try Task.checkCancellation(); return value.token }
        if let failedUntil, failedUntil > now() { throw NFLAPIError.rateLimited(failedUntil) }
        let id = UUID(), request = try configuration.tokenRequest(), session = session, now = now
        let task = Task<Entry, Error> {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw NFLAPIError.authentication }
            if http.statusCode == 429 {
                let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
                throw NFLAPIError.rateLimited(now().addingTimeInterval(max(1, seconds.isFinite ? seconds : 60)))
            }
            guard (200...299).contains(http.statusCode) else { throw NFLAPIError.authentication }
            struct Response: Decodable { let accessToken: String }
            guard let response = try? JSONDecoder().decode(Response.self, from: data), !response.accessToken.isEmpty else { throw NFLAPIError.authentication }
            return Entry(token: response.accessToken, expires: Self.expiration(response.accessToken) ?? now().addingTimeInterval(300))
        }
        flight = (id, task)
        do {
            let value = try await task.value
            guard flight?.0 == id else { throw CancellationError() }
            cached = value; flight = nil; failedUntil = nil
            try Task.checkCancellation()
            return value.token
        } catch {
            if flight?.0 == id {
                flight = nil
                if case NFLAPIError.rateLimited(let deadline) = error { failedUntil = deadline }
                else if !(error is CancellationError) { failedUntil = now().addingTimeInterval(30) }
            }
            throw error
        }
    }
    /// Reads expiration, never authenticates or verifies a JWT.
    nonisolated static func expiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = value["exp"] as? Double, exp.isFinite else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
