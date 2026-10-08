import Foundation

/// Whether a refresh was asked for, or is just the app keeping itself current.
nonisolated enum RefreshOrigin: Sendable {
    /// Pull-to-refresh, a Refresh button, adding or editing a playlist.
    case userInitiated
    /// Launch- and schedule-driven refreshes nobody asked for.
    case automatic
}

/// How the large downloads (playlists, guides) behave on a constrained network.
nonisolated enum NetworkPolicy {

    /// Low Data Mode asks apps to stop refreshing on their own. An automatic refresh is therefore
    /// held back while it is on, but only when there is a cached copy to keep using: a first
    /// download is never optional, and anything the user asked for always goes ahead.
    static func defersInLowDataMode(_ origin: RefreshOrigin, hasCachedCopy: Bool) -> Bool {
        origin == .automatic && hasCachedCopy
    }

    /// The session for a large download. A deferrable one is refused by the system while Low Data
    /// Mode is on; the request fails at once instead of spending the user's data.
    static func bulkSession(deferrable: Bool) -> URLSession {
        deferrable ? deferrableBulkSession : standardBulkSession
    }

    /// Configuration shared by every large download, for callers that need to adjust it
    /// (the guide downloader disables caching) before making their own session.
    static func bulkConfiguration(allowsConstrainedAccess: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        // A playlist or guide can be tens of megabytes; on a slow link two minutes aborted it.
        configuration.timeoutIntervalForResource = 600
        configuration.allowsConstrainedNetworkAccess = allowsConstrainedAccess
        return configuration
    }

    /// True when `error` is the system declining a request because Low Data Mode is on, as opposed
    /// to a real failure.
    static func isLowDataModeRefusal(_ error: Error) -> Bool {
        (error as? URLError)?.networkUnavailableReason == .constrained
    }

    private static let standardBulkSession = URLSession(configuration: bulkConfiguration(allowsConstrainedAccess: true))
    private static let deferrableBulkSession = URLSession(configuration: bulkConfiguration(allowsConstrainedAccess: false))
}
