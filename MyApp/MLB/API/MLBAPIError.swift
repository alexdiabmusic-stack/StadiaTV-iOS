import Foundation

nonisolated enum MLBAPIError: LocalizedError, Sendable {
    case invalidURL, invalidResponse, http(Int), decoding(String), rateLimited(Date)
    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse: return "MLB returned an unexpected response."
        case .http(let code): return "MLB is temporarily unavailable (\(code))."
        case .decoding: return "MLB returned data that could not be read."
        case .rateLimited: return "MLB is busy. Please try again shortly."
        }
    }
}
