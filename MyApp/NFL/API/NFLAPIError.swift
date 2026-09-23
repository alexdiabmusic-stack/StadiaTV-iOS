import Foundation

nonisolated enum NFLAPIError: Error, LocalizedError, Sendable {
    case invalidURL, invalidResponse, authentication, http(Int), rateLimited(Date), decoding
    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse, .decoding: return "NFL data could not be read."
        case .authentication: return "NFL authentication is temporarily unavailable."
        case .http(let code): return "NFL is temporarily unavailable (\(code))."
        case .rateLimited: return "NFL updates are temporarily delayed."
        }
    }
}
