import Foundation

nonisolated enum CFLAPIError: LocalizedError, Sendable {
    case invalidURL, invalidResponse, http(Int), decoding(String), rateLimited(Date)
    case blocked(host: String, status: Int?)
    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse: return "CFL returned an unexpected response."
        case .http(let code): return "CFL is temporarily unavailable (\(code))."
        case .decoding: return "CFL returned data that could not be read."
        case .rateLimited: return "CFL is busy. Please try again shortly."
        case .blocked: return "CFL data isn't available on this network."
        }
    }
}
