import Foundation

/// Typed errors for the FotMob client. FotMob is a keyless web JSON API — there is
/// no `unauthorized` case here the way there is for LaLiga's APIM key, since FotMob
/// requests carry no credential to reject; a persistent block shows up as `.http`
/// or `.blocked` instead.
nonisolated enum FotMobAPIError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case invalidResponse
    /// Sustained non-200s that look like a network-level block (e.g. captive
    /// portal, corporate proxy) rather than a transient server error.
    case blocked
    case notFound(String)
    case http(Int, String?)
    case decoding(String)
    case rateLimited(Date)

    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse: return "Live match data returned an unexpected response."
        case .blocked: return "Live match data isn't available on this network."
        case .notFound: return "That live match data could not be found."
        case .http(let code, _): return "Live match data is temporarily unavailable (\(code))."
        case .decoding: return "Live match data could not be read."
        case .rateLimited: return "Live match data is busy. Please try again shortly."
        }
    }
}
