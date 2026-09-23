import Foundation

nonisolated enum F1LiveTimingEndpoint {
    static let topics = ["Heartbeat", "DriverList", "ExtrapolatedClock", "RaceControlMessages", "SessionInfo", "SessionStatus", "SessionData", "LapCount", "TimingData", "TimingStats", "TimingAppData", "TrackStatus", "WeatherData", "TeamRadio", "TopThree", "CarData.z", "Position.z", "TimingDataF1", "PitLaneTimeCollection", "PitStopSeries", "LapSeries", "CurrentTyres", "TyreStintSeries", "ChampionshipPrediction", "DriverRaceInfo", "OvertakeSeries"]
    static func url(path: String, websocket: Bool = false, query: [String: String] = [:]) throws -> URL {
        var components = URLComponents(); components.scheme = websocket ? "wss" : "https"
        components.host = "livetiming.formula1.com"; components.path = path
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw F1LiveTimingError.invalidResponse }
        return url
    }
    static func archive(_ path: String) throws -> URL {
        guard !path.contains(".."), !path.contains(":") else { throw F1LiveTimingError.invalidResponse }
        return try url(path: "/static/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
nonisolated enum F1LiveTimingError: LocalizedError, Sendable {
    case invalidResponse, http(Int), protocolFailure(String), decompression, oversizedPayload, staleConnection
    case rateLimited(until: Date)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "F1 returned an unexpected response."
        case .rateLimited: "F1 is limiting requests. Retrying after the server’s requested delay."
        case .http(let code): "F1 timing is unavailable (\(code))."
        case .protocolFailure(let message): "F1 connection: \(message)"
        case .decompression: "A compressed F1 update could not be read."
        case .oversizedPayload: "F1 update exceeded the safe size limit."
        case .staleConnection: "Live timing stopped responding."
        }
    }
}
nonisolated enum F1ConnectionState: String, Codable, Sendable {
    case disconnected, negotiating, connecting, subscribing, connected, reconnecting, failed
}
nonisolated enum F1Date {
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        let f = ISO8601DateFormatter()
        if let date = f.date(from: string) { return date }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: string)
    }
    /// Fields explicitly named Utc sometimes omit the trailing Z in archives.
    /// Keep this separate from local SessionInfo.StartDate / GmtOffset parsing.
    static func utc(_ string: String?) -> Date? {
        guard let string else { return nil }
        return parse(string) ?? parse(string + "Z")
    }
    static func duration(_ string: String?) -> Double? {
        guard let string else { return nil }
        let values = string.split(separator: ":").compactMap { Double($0) }
        guard !values.isEmpty, values.count == string.split(separator: ":").count else { return nil }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), values.count <= 3 else { return nil }
        let duration = values.reduce(0) { $0 * 60 + $1 }
        return duration.isFinite && duration <= 604800 ? duration : nil
    }
}

nonisolated enum F1RetryPolicy {
    static func delay(_ header: String?, now: Date = Date()) -> Double {
        if let seconds = header.flatMap(Double.init), seconds.isFinite { return max(1, seconds) }
        if let header {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return max(1, date.timeIntervalSince(now)) }
        }
        return 60
    }
}
