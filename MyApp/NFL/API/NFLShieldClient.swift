import Foundation
import OSLog

actor NFLShieldClient {
    static let shared = NFLShieldClient()
    private let session: URLSession
    private let tokens: NFLTokenProvider
    private let configuration: NFLClientConfiguration
    private struct Flight {
        let id: UUID
        let task: Task<Data, Error>
        var waiters: Set<UUID>
    }
    private var flights: [NFLEndpoint: Flight] = [:]
    private var cache: [NFLEndpoint: (Date, Data)] = [:]
    private var retryNotBefore: Date?
    init(session: URLSession = URLSession(configuration: .ephemeral), tokens: NFLTokenProvider = .shared,
         configuration: NFLClientConfiguration = .init()) {
        self.session = session; self.tokens = tokens; self.configuration = configuration
    }
    func get<T: Decodable & Sendable>(_ endpoint: NFLEndpoint, as type: T.Type, maxAge: TimeInterval = 0) async throws -> T {
        let data = try await data(endpoint, maxAge: maxAge)
        try Task.checkCancellation()
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            Logger(subsystem: "BannerTV", category: "NFL").error("NFL decode failed for \(endpoint.path, privacy: .public)")
            throw NFLAPIError.decoding
        }
    }
    func week(for date: Date) async throws -> NFLWeek { try await get(.week(date: date), as: NFLWeek.self, maxAge: 3600) }
    func weeklyGameDetails(_ week: NFLWeek, drives: Bool = true) async throws -> NFLWeeklyResponse {
        try await get(.weekly(week, drives: drives), as: NFLWeeklyResponse.self, maxAge: drives ? 8 : 30)
    }
    func weeks(season: Int, type: NFLSeasonType) async throws -> NFLValue {
        try await get(.weeks(season: season, type: type), as: NFLValue.self, maxAge: 3600)
    }
    func standings(_ week: NFLWeek) async throws -> NFLValue { try await get(.resource("standings", week: week), as: NFLValue.self, maxAge: 900) }
    func injuries(_ week: NFLWeek) async throws -> NFLValue {
        var endpoint = NFLEndpoint.resource("injuries", week: week)
        var rows: [NFLValue] = [], seen = Set<String>()
        for _ in 0..<64 {
            let page = try await get(endpoint, as: NFLValue.self, maxAge: 900)
            rows += page["injuries"].array
            guard let token = page["pagination"]["token"].string, !token.isEmpty else { return .object(["injuries": .array(rows)]) }
            guard seen.insert(token).inserted else { throw NFLAPIError.invalidResponse }
            // Verified against Shield: pageToken advances the cursor; token is ignored.
            endpoint.query["pageToken"] = token
        }
        throw NFLAPIError.invalidResponse
    }
    func rosters(season: Int) async throws -> NFLValue { try await get(.seasonResource("rosters", season: season), as: NFLValue.self, maxAge: 14400) }
    func team(id: String) async throws -> NFLValue { try await get(try .team(id), as: NFLValue.self, maxAge: 86400) }
    func liveGameSummaries(_ week: NFLWeek) async throws -> NFLValue {
        try await get(.resource("stats/live/game-summaries", week: week), as: NFLValue.self, maxAge: 5)
    }
    private func data(_ endpoint: NFLEndpoint, maxAge: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        if let cached = cache[endpoint], Date().timeIntervalSince(cached.0) < maxAge { return cached.1 }
        if let retryNotBefore, retryNotBefore > Date() { throw NFLAPIError.rateLimited(retryNotBefore) }
        let waiter = UUID()
        let flight: Flight
        if var existing = flights[endpoint] {
            existing.waiters.insert(waiter); flights[endpoint] = existing; flight = existing
        } else {
            let created = Flight(id: UUID(), task: Task { try await self.fetch(endpoint) }, waiters: [waiter])
            flights[endpoint] = created; flight = created
        }
        return try await withTaskCancellationHandler {
            do {
                let data = try await flight.task.value
                if flights[endpoint]?.id == flight.id {
                    cache[endpoint] = (Date(), data)
                    release(endpoint, flightID: flight.id, waiter: waiter, completed: true)
                }
                if cache.count > 100, let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key { cache[oldest] = nil }
                try Task.checkCancellation()
                return data
            } catch {
                release(endpoint, flightID: flight.id, waiter: waiter, completed: true)
                throw error
            }
        } onCancel: {
            Task { await self.release(endpoint, flightID: flight.id, waiter: waiter, completed: false) }
        }
    }
    private func release(_ endpoint: NFLEndpoint, flightID: UUID, waiter: UUID, completed: Bool) {
        guard var flight = flights[endpoint], flight.id == flightID else { return }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty {
            if !completed { flight.task.cancel() }
            flights[endpoint] = nil
        } else { flights[endpoint] = flight }
    }
    private func fetch(_ endpoint: NFLEndpoint) async throws -> Data {
        var token = try await tokens.validToken(), refreshed = false, failures = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: try endpoint.url(host: configuration.host), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.allHTTPHeaderFields = configuration.headers(token: token)
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw NFLAPIError.invalidResponse }
                if http.statusCode == 401 || http.statusCode == 403 {
                    guard !refreshed else { throw NFLAPIError.authentication }
                    token = try await tokens.forceRefresh(rejectedToken: token); refreshed = true
                    continue
                }
                if http.statusCode == 429 {
                    let deadline = Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"))
                    retryNotBefore = deadline
                    throw NFLAPIError.rateLimited(deadline)
                }
                if (500...599).contains(http.statusCode), failures < 2 {
                    failures += 1; try await Task.sleep(for: .seconds(pow(2, Double(failures)))); continue
                }
                guard (200...299).contains(http.statusCode) else { throw NFLAPIError.http(http.statusCode) }
                #if DEBUG
                await NFLPayloadRecorder.shared.record(data, endpoint: endpoint)
                #endif
                return data
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard failures < 2 else { throw error }
                failures += 1; try await Task.sleep(for: .seconds(pow(2, Double(failures))))
            }
        }
    }
    private static func retryDate(_ value: String?) -> Date {
        if let value, let seconds = Double(value), seconds.isFinite { return Date().addingTimeInterval(max(1, seconds)) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return value.flatMap(f.date) ?? Date().addingTimeInterval(60)
    }
}

#if DEBUG
actor NFLPayloadRecorder {
    static let shared = NFLPayloadRecorder()
    func record(_ data: Data, endpoint: NFLEndpoint) {
        guard ProcessInfo.processInfo.environment["NFL_RECORD_PAYLOADS"] == "1",
              data.count < 20_000_000,
              let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let directory = root.appendingPathComponent("NFLFixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only GET response bodies; request headers and identity/token responses are never recorded.
        let name = endpoint.path.replacingOccurrences(of: "/", with: "_") + ".json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
#endif
