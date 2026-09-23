import Foundation

nonisolated enum NBAAPIError: LocalizedError, Sendable {
    case invalidURL, invalidResponse, http(Int), decoding(String), rateLimited(Date)
    /// Distinct from `.http` / `.rateLimited`: a persistent edge block (Akamai 403 on
    /// `cdn.nba.com`) or an application-layer connection drop (`stats.nba.com`), neither
    /// of which a quick retry will resolve. Callers should not offer an immediate Retry.
    case blocked(host: String, status: Int?)
    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse: return "NBA returned an unexpected response."
        case .http(let code): return "NBA is temporarily unavailable (\(code))."
        case .decoding: return "NBA returned data that could not be read."
        case .rateLimited: return "NBA is busy. Please try again shortly."
        case .blocked: return "NBA data isn't available on this network."
        }
    }
}
