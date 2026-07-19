import Foundation
import SwiftUI
import Combine

// MARK: - Team model

struct Team: Identifiable, Hashable {
    let id: String
    let displayName: String
    let shortDisplayName: String
    let abbreviation: String
    let logoURL: URL?
}

/// A favorited team, stored with enough context to rebuild it without a network call.
struct FavoriteTeam: Codable, Hashable, Identifiable {
    var leaguePath: String
    var teamID: String
    var displayName: String
    var abbreviation: String
    var logoURLString: String?

    var id: String { "\(leaguePath)-\(teamID)" }
    var logoURL: URL? { logoURLString.flatMap(URL.init(string:)) }

    init(team: Team, league: League) {
        self.leaguePath = league.path
        self.teamID = team.id
        self.displayName = team.displayName
        self.abbreviation = team.abbreviation
        self.logoURLString = team.logoURL?.absoluteString
    }
}

// MARK: - Persisted preferences

enum MatchReminderLeadTime: Int, Codable, CaseIterable, Identifiable {
    case sixty = 60
    case thirty = 30
    case ten = 10
    case five = 5

    var id: Int { rawValue }
    var minutes: Int { rawValue }

    var label: String {
        switch self {
        case .sixty: return "1 hour before"
        case .thirty: return "30 minutes before"
        case .ten: return "10 minutes before"
        case .five: return "5 minutes before"
        }
    }
}

struct UserPreferences: Codable, Equatable {
    var hasCompletedOnboarding = false
    var selectedLeagueIDs: Set<String> = []   // League.path values
    var favoriteTeams: [FavoriteTeam] = []
    var matchNotificationsEnabled = false
    var matchReminderLeadTime: MatchReminderLeadTime = .thirty
    var cloudSyncEnabled = false
}

/// Owns the user's onboarding selections (sports/leagues/favorite teams) and
/// persists them to `UserDefaults` so the app remembers settings between launches.
@MainActor
final class PreferencesStore: ObservableObject {
    @Published private(set) var prefs: UserPreferences

    private let defaultsKey = "stadiatv.preferences.v1"
    private let favoriteTeamNotificationPromptKey = "stadiatv.favoriteTeamNotificationPromptAnswered.v1"

    init() {
        CloudSyncService.shared.start()
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            prefs = decoded
        } else if let cloud: UserPreferences = CloudSyncService.shared.load(UserPreferences.self, for: .preferences) {
            prefs = cloud
        } else {
            prefs = UserPreferences()
        }
        CloudSyncService.shared.setEnabled(prefs.cloudSyncEnabled)
        NotificationCenter.default.addObserver(
            forName: .stadiatvCloudSyncDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let preferencesStore = self else { return }
            Task { @MainActor in
                preferencesStore.applyCloudPreferencesIfNeeded()
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        UserDefaults.standard.set(prefs.cloudSyncEnabled, forKey: CloudSyncService.enabledDefaultsKey)
        CloudSyncService.shared.save(prefs, for: .preferences)
    }

    private func applyCloudPreferencesIfNeeded() {
        guard prefs.cloudSyncEnabled,
              let cloud: UserPreferences = CloudSyncService.shared.load(UserPreferences.self, for: .preferences),
              cloud != prefs else { return }
        prefs = cloud
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: Onboarding

    var hasCompletedOnboarding: Bool { prefs.hasCompletedOnboarding }

    func completeOnboarding() {
        prefs.hasCompletedOnboarding = true
        persist()
    }

    func resetOnboarding() {
        prefs.hasCompletedOnboarding = false
        persist()
    }

    var matchNotificationsEnabled: Bool { prefs.matchNotificationsEnabled }
    var matchReminderLeadTime: MatchReminderLeadTime { prefs.matchReminderLeadTime }
    var cloudSyncEnabled: Bool { prefs.cloudSyncEnabled }

    var shouldPromptForFavoriteTeamNotifications: Bool {
        !prefs.favoriteTeams.isEmpty
            && !prefs.matchNotificationsEnabled
            && !UserDefaults.standard.bool(forKey: favoriteTeamNotificationPromptKey)
    }

    func setMatchNotificationsEnabled(_ enabled: Bool) {
        prefs.matchNotificationsEnabled = enabled
        persist()
    }

    func markFavoriteTeamNotificationPromptAnswered() {
        UserDefaults.standard.set(true, forKey: favoriteTeamNotificationPromptKey)
    }

    func setMatchReminderLeadTime(_ leadTime: MatchReminderLeadTime) {
        prefs.matchReminderLeadTime = leadTime
        persist()
    }

    func setCloudSyncEnabled(_ enabled: Bool) {
        prefs.cloudSyncEnabled = enabled
        CloudSyncService.shared.setEnabled(enabled)
        persist()
    }

    // MARK: Leagues

    /// The leagues the user follows, in the catalog's canonical order.
    /// Falls back to the full catalog when nothing has been chosen yet.
    var followedLeagues: [League] {
        let selected = League.all.filter { prefs.selectedLeagueIDs.contains($0.path) }
        return selected.isEmpty ? League.all : selected
    }

    func isLeagueSelected(_ league: League) -> Bool {
        prefs.selectedLeagueIDs.contains(league.path)
    }

    func toggleLeague(_ league: League) {
        if prefs.selectedLeagueIDs.contains(league.path) {
            prefs.selectedLeagueIDs.remove(league.path)
        } else {
            prefs.selectedLeagueIDs.insert(league.path)
        }
        persist()
    }

    func setLeagues(_ leagues: Set<League>) {
        prefs.selectedLeagueIDs = Set(leagues.map(\.path))
        persist()
    }

    // MARK: Favorite teams

    func isFavorite(_ team: Team, in league: League) -> Bool {
        prefs.favoriteTeams.contains { $0.leaguePath == league.path && $0.teamID == team.id }
    }

    func toggleFavorite(_ team: Team, in league: League) {
        if let index = prefs.favoriteTeams.firstIndex(where: { $0.leaguePath == league.path && $0.teamID == team.id }) {
            prefs.favoriteTeams.remove(at: index)
        } else {
            prefs.favoriteTeams.append(FavoriteTeam(team: team, league: league))
        }
        persist()
    }

    var favoriteTeams: [FavoriteTeam] { prefs.favoriteTeams }

    var favoriteTeamNames: Set<String> {
        Set(prefs.favoriteTeams.map { $0.displayName.lowercased() })
    }

    /// True when a match involves one of the user's favorite teams.
    func isFavoriteMatch(_ match: Match) -> Bool {
        let names = favoriteTeamNames
        guard !names.isEmpty else { return false }
        return names.contains(match.home.displayName.lowercased())
            || names.contains(match.away.displayName.lowercased())
    }
}
