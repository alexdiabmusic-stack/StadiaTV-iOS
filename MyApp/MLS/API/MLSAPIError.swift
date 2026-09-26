import Foundation

/// Typed errors for the MLS stats-api client. `notFound`/`badRequest` distinguish
/// the two error shapes actually observed live — `{"error_code":"MLS-002-ERR",
/// "message":"Requested resource does not exist","error":"Not found"}` for 404, and
/// `{"error_code":"MLS-001-ERR","message":"validating query parameters: ...",
/// "error":"Bad Request"}` for 400 — from a generic HTTP failure, so callers can
/// degrade gracefully instead of showing a raw status code.
nonisolated enum MLSAPIError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case invalidResponse
    case badRequest(String)      // 400 — usually a query-parameter validation failure
    case notFound(String)        // 404
    case http(Int, String?)
    case decoding(String)
    case rateLimited(Date)

    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse: return "MLS data returned an unexpected response."
        case .badRequest: return "This MLS data route is unavailable."
        case .notFound: return "That MLS data could not be found."
        case .http(let code, _): return "MLS data is temporarily unavailable (\(code))."
        case .decoding: return "MLS data could not be read."
        case .rateLimited: return "MLS data is busy. Please try again shortly."
        }
    }
}
