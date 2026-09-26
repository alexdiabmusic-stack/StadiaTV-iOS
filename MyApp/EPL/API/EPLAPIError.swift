import Foundation

/// Typed errors for the PulseLive/SDP client. `notEnabled`/`notFound` distinguish the
/// two documented `application/problem+json` shapes (Steps 74–75 of the EPL spec) from
/// a generic HTTP failure so callers can degrade gracefully instead of showing a raw
/// status code.
nonisolated enum EPLAPIError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case invalidResponse
    case notEnabled(String)      // 400 "This endpoint is not enabled for API access" / similar
    case notFound(String)        // 404 "Could not find requested entity"
    case http(Int, String?)
    case decoding(String)
    case rateLimited(Date)

    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse: return "Premier League data returned an unexpected response."
        case .notEnabled: return "This Premier League data route is unavailable."
        case .notFound: return "That Premier League data could not be found."
        case .http(let code, _): return "Premier League data is temporarily unavailable (\(code))."
        case .decoding: return "Premier League data could not be read."
        case .rateLimited: return "Premier League data is busy. Please try again shortly."
        }
    }
}
