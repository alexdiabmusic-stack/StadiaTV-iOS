import Foundation
import OSLog

nonisolated enum NHLAPIError: LocalizedError, Sendable {
    case invalidURL, invalidResponse, http(Int), decoding(String), rateLimited(Date)
    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse: return "NHL returned an unexpected response."
        case .http(let code): return "NHL is temporarily unavailable (\(code))."
        case .decoding: return "NHL returned data that could not be read."
        case .rateLimited: return "NHL is busy. Please try again shortly."
        }
    }
}
nonisolated protocol NHLAPIClientProtocol: Sendable {
    func score(date: Date?) async throws -> NHLScoreResponse
    func schedule(date: Date) async throws -> NHLScheduleResponse
    func landing(gameID: Int) async throws -> NHLGameDTO
    func boxscore(gameID: Int) async throws -> NHLBoxscoreResponse
    func playByPlay(gameID: Int) async throws -> NHLPlayByPlayResponse
    func rightRail(gameID: Int) async throws -> NHLValue
    func standings() async throws -> NHLStandingsResponse
    func roster(team: String) async throws -> NHLRosterResponse
    func player(playerID: Int) async throws -> NHLPlayerResponse
}
actor NHLAPIClient {
    static let shared = NHLAPIClient()
    private let session: URLSession
    private let baseURL: String
    private var retryNotBefore: Date?
    init(session: URLSession = .shared, baseURL: String = "https://api-web.nhle.com/v1") {
        self.session = session; self.baseURL = baseURL
    }
    func score(date: Date? = nil) async throws -> NHLScoreResponse { try await get("score/\(date.map(NHLDate.day) ?? "now")") }
    func schedule(date: Date) async throws -> NHLScheduleResponse { try await get("schedule/\(NHLDate.day(date))") }
    func landing(gameID: Int) async throws -> NHLGameDTO { try await get("gamecenter/\(gameID)/landing") }
    func boxscore(gameID: Int) async throws -> NHLBoxscoreResponse { try await get("gamecenter/\(gameID)/boxscore") }
    func playByPlay(gameID: Int) async throws -> NHLPlayByPlayResponse { try await get("gamecenter/\(gameID)/play-by-play") }
    func rightRail(gameID: Int) async throws -> NHLValue { try await get("gamecenter/\(gameID)/right-rail") }
    func standings() async throws -> NHLStandingsResponse { try await get("standings/now") }
    func roster(team: String) async throws -> NHLRosterResponse {
        guard !team.isEmpty, team.allSatisfy(\.isLetter) else { throw NHLAPIError.invalidURL }
        return try await get("roster/\(team.uppercased())/current")
    }
    func player(playerID: Int) async throws -> NHLPlayerResponse { try await get("player/\(playerID)/landing") }

    private func get<T: Decodable & Sendable>(_ path: String) async throws -> T {
        guard let components = URLComponents(string: baseURL + "/" + path), let url = components.url else { throw NHLAPIError.invalidURL }
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw NHLAPIError.rateLimited(deadline) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw NHLAPIError.invalidResponse }
                if http.statusCode == 429 {
                    let deadline = Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"))
                    retryNotBefore = deadline
                    throw NHLAPIError.rateLimited(deadline)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                guard (200...299).contains(http.statusCode) else { throw NHLAPIError.http(http.statusCode) }
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch {
                    Logger(subsystem: "BannerTV", category: "NHL").error("Decode \(path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw NHLAPIError.decoding(String(describing: error))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw NHLAPIError.invalidResponse
    }
    private static func retryDate(_ value: String?) -> Date {
        if let value, let seconds = Double(value) { return Date().addingTimeInterval(max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return value.flatMap(formatter.date) ?? Date().addingTimeInterval(60)
    }
}
// Keep protocol isolation inference separate from the actor's own executor.
extension NHLAPIClient: NHLAPIClientProtocol {}

nonisolated enum NHLDate {
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}
