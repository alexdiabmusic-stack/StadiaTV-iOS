import Foundation

/// Typed errors for the LaLiga official-API client. `unauthorized` is its own case
/// (rather than folding into `.http`) because it triggers the circuit-breaker cooldown
/// in `LaLigaClient` (Step 34) instead of the normal retry/backoff path — a rotated
/// public key is never something a retry fixes.
nonisolated enum LaLigaAPIError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case invalidResponse
    case unauthorized
    case notFound(String)
    case http(Int, String?)
    case decoding(String)
    case rateLimited(Date)

    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse: return "La Liga data returned an unexpected response."
        case .unauthorized: return "La Liga's official data source is temporarily unavailable."
        case .notFound: return "That La Liga data could not be found."
        case .http(let code, _): return "La Liga data is temporarily unavailable (\(code))."
        case .decoding: return "La Liga data could not be read."
        case .rateLimited: return "La Liga data is busy. Please try again shortly."
        }
    }
}
