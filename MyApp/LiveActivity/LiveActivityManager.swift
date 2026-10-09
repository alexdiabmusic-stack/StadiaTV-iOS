#if (os(iOS) || os(visionOS)) && canImport(ActivityKit)
import ActivityKit
import BannerSharedKit
import Foundation

/// Starts/updates/ends Banner's single game Live Activity. Reuses `Match`/`GameState`
/// directly — no separate Live Activity data model. Tracks at most one Activity at a
/// time and re-evaluates which game deserves it on every call to `reconcile`, per the
/// product's priority order, instead of spawning one Activity per live game.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private enum Priority: Int, Comparable {
        case followedLeague = 0, followedTeam = 1, listening = 2, favoriteTeam = 3, explicit = 4
        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private var activity: Activity<GameLiveActivityAttributes>?
    private(set) var trackedMatchID: String?
    private var trackedPriority: Priority?
    private var explicitMatchID: String?

    private init() {}

    /// "Track this game" — wins over every automatic candidate until cleared or the game ends.
    func setExplicitlyTracked(matchID: String?) {
        explicitMatchID = matchID
    }

    /// Call whenever the already-polled live-match list changes (e.g. from `LiveViewModel`'s
    /// existing refresh) — this does not poll on its own, so it adds no new network traffic.
    ///
    /// Priority: explicitly tracked > favorite team > game currently being listened to >
    /// followed team > followed league. `favoriteMatchIDs` and `followedTeamMatchIDs` are
    /// the same set today (both come from `PreferencesStore.isFavoriteMatch`) but are kept
    /// as separate parameters since product intent treats "favorite" and "followed" as
    /// distinct priority tiers that may diverge later.
    func reconcile(
        liveMatches: [Match],
        favoriteMatchIDs: Set<String>,
        listeningMatchID: String?,
        followedTeamMatchIDs: Set<String>,
        followedLeagueMatchIDs: Set<String>
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let candidate = bestCandidate(
            liveMatches: liveMatches, favoriteMatchIDs: favoriteMatchIDs, listeningMatchID: listeningMatchID,
            followedTeamMatchIDs: followedTeamMatchIDs, followedLeagueMatchIDs: followedLeagueMatchIDs)

        guard let candidate else {
            end()
            return
        }

        if trackedMatchID == candidate.match.id {
            update(candidate.match)
        } else if trackedPriority == nil || candidate.priority >= (trackedPriority ?? .followedLeague) {
            end()
            start(candidate.match, priority: candidate.priority)
        }
    }

    private func bestCandidate(
        liveMatches: [Match], favoriteMatchIDs: Set<String>, listeningMatchID: String?,
        followedTeamMatchIDs: Set<String>, followedLeagueMatchIDs: Set<String>
    ) -> (match: Match, priority: Priority)? {
        if let explicitMatchID, let match = liveMatches.first(where: { $0.id == explicitMatchID }) {
            return (match, .explicit)
        }
        if let match = liveMatches.first(where: { favoriteMatchIDs.contains($0.id) }) {
            return (match, .favoriteTeam)
        }
        if let listeningMatchID, let match = liveMatches.first(where: { $0.id == listeningMatchID }) {
            return (match, .listening)
        }
        if let match = liveMatches.first(where: { followedTeamMatchIDs.contains($0.id) }) {
            return (match, .followedTeam)
        }
        if let match = liveMatches.first(where: { followedLeagueMatchIDs.contains($0.id) }) {
            return (match, .followedLeague)
        }
        return nil
    }

    private func start(_ match: Match, priority: Priority) {
        let attributes = GameLiveActivityAttributes(
            matchID: match.id, league: match.league.shortName,
            homeName: match.home.displayName, awayName: match.away.displayName,
            homeAbbreviation: match.home.abbreviation, awayAbbreviation: match.away.abbreviation)
        let content = ActivityContent(state: contentState(for: match), staleDate: nil)
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            trackedMatchID = match.id
            trackedPriority = priority
        } catch {
            activity = nil
            trackedMatchID = nil
            trackedPriority = nil
        }
    }

    private func update(_ match: Match) {
        guard let activity else { return }
        if match.state == .final {
            Task { await activity.end(ActivityContent(state: contentState(for: match), staleDate: nil), dismissalPolicy: .after(.now.advanced(by: 300))) }
            self.activity = nil
            trackedMatchID = nil
            trackedPriority = nil
            return
        }
        Task { await activity.update(ActivityContent(state: contentState(for: match), staleDate: nil)) }
    }

    private func end() {
        guard let activity else { return }
        Task { await activity.end(activity.content, dismissalPolicy: .immediate) }
        self.activity = nil
        trackedMatchID = nil
        trackedPriority = nil
    }

    private func contentState(for match: Match) -> GameLiveActivityAttributes.ContentState {
        GameLiveActivityAttributes.ContentState(
            homeScore: match.home.score ?? "0", awayScore: match.away.score ?? "0",
            statusDetail: match.statusDetail, stateLabel: match.state.label)
    }
}
#else
import Foundation

/// Live Activities have no native macOS/tvOS equivalent (ActivityKit's `Activity` APIs
/// are unavailable there). This stub keeps the call sites in ContentView.swift and
/// CarPlayPlaybackCoordinator.swift platform-agnostic.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private(set) var trackedMatchID: String?

    private init() {}

    func setExplicitlyTracked(matchID: String?) {}

    func reconcile(
        liveMatches: [Match],
        favoriteMatchIDs: Set<String>,
        listeningMatchID: String?,
        followedTeamMatchIDs: Set<String>,
        followedLeagueMatchIDs: Set<String>
    ) {}
}
#endif
