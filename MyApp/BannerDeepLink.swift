import Foundation

/// Banner's deep-link scheme (`banner://game/{eventID}`), shared across every surface that
/// needs to point at a specific game — CarPlay, push notifications, Live Activities, and
/// Siri/App Intents — instead of each inventing its own link format. `Match.id` is the
/// stable identifier already used for stream matching (`StreamAvailabilityStore`) and
/// reminders (`MatchNotificationService`), so no new identity scheme is introduced here.
nonisolated enum BannerDeepLink: Identifiable, Equatable {
    case game(matchID: String)

    var id: String {
        switch self {
        case .game(let matchID): return "game:\(matchID)"
        }
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "banner" else { return nil }
        switch url.host?.lowercased() {
        case "game":
            let matchID = url.pathComponents.filter { $0 != "/" }.first
            guard let matchID, !matchID.isEmpty else { return nil }
            self = .game(matchID: matchID.removingPercentEncoding ?? matchID)
        default:
            return nil
        }
    }
}

extension Match {
    /// `banner://game/{eventID}` for this match, for Live Activities, notifications, and
    /// Siri responses to link back to. Percent-encodes the ID since provider-qualified IDs
    /// (e.g. "game:espn:nba:401234") contain characters that aren't valid bare path segments.
    var deepLinkURL: URL? {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "banner://game/\(encoded)")
    }
}
