import Foundation

nonisolated enum WNBAAPIError: LocalizedError, Sendable {
    case invalidURL, invalidResponse, http(Int), decoding(String), rateLimited(Date)
    /// Distinct from `.http`/`.rateLimited`: a persistent edge block or an
    /// application-layer connection drop, neither of which a quick retry resolves.
    case blocked(host: String, status: Int?)
    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse: return "WNBA returned an unexpected response."
        case .http(let code): return "WNBA is temporarily unavailable (\(code))."
        case .decoding: return "WNBA returned data that could not be read."
        case .rateLimited: return "WNBA is busy. Please try again shortly."
        case .blocked: return "WNBA data isn't available on this network."
        }
    }
}
