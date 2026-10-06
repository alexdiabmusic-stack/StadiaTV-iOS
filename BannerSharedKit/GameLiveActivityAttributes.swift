#if os(iOS) || os(visionOS)
import ActivityKit
import Foundation

/// Shared by the main app (`LiveActivityManager` starts/updates/ends the Activity) and the
/// `BannerLiveActivityExtension` widget extension (renders it) through this framework —
/// one source of truth instead of hand-synced duplicate files in each target.
public struct GameLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var homeScore: String
        public var awayScore: String
        /// e.g. "3rd · 8:42" or "7:00 PM ET" — the same `Match.statusDetail` text shown elsewhere.
        public var statusDetail: String
        /// "LIVE" / "Final" / "Upcoming" — `GameState.label`.
        public var stateLabel: String

        public init(homeScore: String, awayScore: String, statusDetail: String, stateLabel: String) {
            self.homeScore = homeScore
            self.awayScore = awayScore
            self.statusDetail = statusDetail
            self.stateLabel = stateLabel
        }
    }

    public let matchID: String
    public let league: String
    public let homeName: String
    public let awayName: String
    public let homeAbbreviation: String
    public let awayAbbreviation: String

    public init(matchID: String, league: String, homeName: String, awayName: String, homeAbbreviation: String, awayAbbreviation: String) {
        self.matchID = matchID
        self.league = league
        self.homeName = homeName
        self.awayName = awayName
        self.homeAbbreviation = homeAbbreviation
        self.awayAbbreviation = awayAbbreviation
    }
}
#endif
