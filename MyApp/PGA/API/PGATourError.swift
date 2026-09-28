import Foundation

nonisolated enum PGATourError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case http(Int)
    case graphQLError(String)
    case decoding(String)
    case authenticationFailed
    case rateLimited(until: Date)
    case decompression(String)
    case oversizedPayload
    case invalidTourCode(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "PGA TOUR returned an unexpected response."
        case .http(let code): return "PGA TOUR data is unavailable (\(code))."
        case .graphQLError(let message): return "PGA TOUR GraphQL error: \(message)"
        case .decoding(let message): return "PGA TOUR returned data this app couldn't read: \(message)"
        case .authenticationFailed: return "PGA TOUR provider configuration failed authentication."
        case .rateLimited: return "PGA TOUR is limiting requests. Retrying after the server's requested delay."
        case .decompression(let message): return "A compressed PGA TOUR update could not be read: \(message)"
        case .oversizedPayload: return "A PGA TOUR update exceeded the safe size limit."
        case .invalidTourCode(let code): return "Unsupported tour code: \(code)"
        }
    }

    /// Transient statuses worth retrying with backoff. Matches the reference
    /// client conventions (408/429/500/502/503/504); everything else (most
    /// 4xx, GraphQL validation failures) fails fast instead of looping.
    static func isTransient(httpStatus: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(httpStatus)
    }
}

/// The PGA TOUR-family tour codes the API exposes. Only "R" (PGA TOUR) is
/// wired end-to-end today; the others are modeled so they can be enabled
/// later without redesigning the domain.
nonisolated enum PGATourCode: String, Sendable, CaseIterable, Codable {
    case pgaTour = "R"
    case pgaTourChampions = "S"
    case kornFerryTour = "H"
    case pgaTourAmericas = "Y"

    init?(validating raw: String) {
        self.init(rawValue: raw)
    }
}
