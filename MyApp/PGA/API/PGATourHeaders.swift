import Foundation

/// Builds the header set every PGA TOUR request needs. Centralized so no
/// individual service reconstructs (or drifts from) the frontend's contract.
/// Without `x-api-key` and `x-pgat-platform`, the endpoint returns HTTP 503.
nonisolated enum PGATourRequestHeaders {
    static func apply(
        to request: inout URLRequest,
        configuration: PGATourProviderConfiguration,
        accept: String = "application/graphql-response+json, application/json"
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(configuration.currentFrontendAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue(configuration.platformHeader, forHTTPHeaderField: "x-pgat-platform")
        request.setValue("https://www.pgatour.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.pgatour.com/", forHTTPHeaderField: "Referer")
        request.setValue("BannerTV/1.0 (+PGA TOUR native client)", forHTTPHeaderField: "User-Agent")
    }
}
