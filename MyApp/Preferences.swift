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
    let canonicalIDString: String?

    init(id: String, displayName: String, shortDisplayName: String, abbreviation: String, logoURL: URL?, canonicalIDString: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.shortDisplayName = shortDisplayName
        self.abbreviation = abbreviation
        self.logoURL = logoURL
        self.canonicalIDString = canonicalIDString
    }
}

/// A favorited team, stored with enough context to rebuild it without a network call.
struct FavoriteTeam: Codable, Hashable, Identifiable {
    var leaguePath: String
    var teamID: String
    var displayName: String
    var abbreviation: String
    var logoURLString: String?
    var canonicalTeamIDString: String?

    var id: String { "\(leaguePath)-\(teamID)" }
    var logoURL: URL? { logoURLString.flatMap(URL.init(string:)) }
    var canonicalTeamID: String { canonicalTeamIDString ?? "team:\(leaguePath):legacy:\(teamID)" }

    init(team: Team, league: League) {
        self.leaguePath = league.path
        self.teamID = team.id
        self.displayName = team.displayName
        self.abbreviation = team.abbreviation
        self.logoURLString = team.logoURL?.absoluteString
        self.canonicalTeamIDString = team.canonicalIDString
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

enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

struct UserPreferences: Codable, Equatable {
    var hasCompletedOnboarding = false
    var selectedLeagueIDs: Set<String> = []   // League.path values
    var favoriteTeams: [FavoriteTeam] = []
    var matchNotificationsEnabled = false
    var matchReminderLeadTime: MatchReminderLeadTime = .thirty
    var morningDigestEnabled = false
    var cloudSyncEnabled = false
    var appearance: AppAppearance = .dark
    var preferredStreamLanguages: Set<String> = ["en"]   // StreamLanguage.code values
    var spoilerFreeMode = false
    var showLiveScoreBadge = true
    var showLiveScoreBar = false

    // Live TV display preferences
    var showChannelNumbers: Bool = false
    var guideProgrammeTitleLines: Int = 1
    var epgHighlightCurrentProgramme: Bool = true
    var playerPanelTimeoutSeconds: Int = 4
    var guideTimeScaleMinutes: Int = 60
    var playerBarActions: [String] = PlayerBarAction.defaultOrder.map(\.rawValue)

    init() {}

    private enum CodingKeys: String, CodingKey {
        case hasCompletedOnboarding, selectedLeagueIDs, favoriteTeams
        case matchNotificationsEnabled, matchReminderLeadTime, morningDigestEnabled, cloudSyncEnabled
        case appearance, preferredStreamLanguages, spoilerFreeMode, showLiveScoreBadge, showLiveScoreBar
        case showChannelNumbers, guideProgrammeTitleLines, epgHighlightCurrentProgramme
        case playerPanelTimeoutSeconds, guideTimeScaleMinutes, playerBarActions
    }

    /// Decodes leniently so preferences saved by older app versions
    /// (missing newly added keys) still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        selectedLeagueIDs = try container.decodeIfPresent(Set<String>.self, forKey: .selectedLeagueIDs) ?? []
        favoriteTeams = try container.decodeIfPresent([FavoriteTeam].self, forKey: .favoriteTeams) ?? []
        matchNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .matchNotificationsEnabled) ?? false
        matchReminderLeadTime = try container.decodeIfPresent(MatchReminderLeadTime.self, forKey: .matchReminderLeadTime) ?? .thirty
        morningDigestEnabled = try container.decodeIfPresent(Bool.self, forKey: .morningDigestEnabled) ?? false
        cloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .cloudSyncEnabled) ?? false
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .dark
        preferredStreamLanguages = try container.decodeIfPresent(Set<String>.self, forKey: .preferredStreamLanguages) ?? ["en"]
        spoilerFreeMode = try container.decodeIfPresent(Bool.self, forKey: .spoilerFreeMode) ?? false
        showLiveScoreBadge = try container.decodeIfPresent(Bool.self, forKey: .showLiveScoreBadge) ?? true
        showLiveScoreBar = try container.decodeIfPresent(Bool.self, forKey: .showLiveScoreBar) ?? false
        showChannelNumbers = try container.decodeIfPresent(Bool.self, forKey: .showChannelNumbers) ?? false
        guideProgrammeTitleLines = try container.decodeIfPresent(Int.self, forKey: .guideProgrammeTitleLines) ?? 1
        epgHighlightCurrentProgramme = try container.decodeIfPresent(Bool.self, forKey: .epgHighlightCurrentProgramme) ?? true
        playerPanelTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .playerPanelTimeoutSeconds) ?? 4
        guideTimeScaleMinutes = try container.decodeIfPresent(Int.self, forKey: .guideTimeScaleMinutes) ?? 60
        playerBarActions = try container.decodeIfPresent([String].self, forKey: .playerBarActions)
            ?? PlayerBarAction.defaultOrder.map(\.rawValue)
    }
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
        if prefs.preferredStreamLanguages.isEmpty {
            prefs.preferredStreamLanguages = ["en"]
            persist()
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
    var morningDigestEnabled: Bool { prefs.morningDigestEnabled }
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

    func setMorningDigestEnabled(_ enabled: Bool) {
        prefs.morningDigestEnabled = enabled
        persist()
    }

    func setCloudSyncEnabled(_ enabled: Bool) {
        prefs.cloudSyncEnabled = enabled
        CloudSyncService.shared.setEnabled(enabled)
        persist()
    }

    // MARK: Appearance

    var appearance: AppAppearance { prefs.appearance }

    func setAppearance(_ appearance: AppAppearance) {
        prefs.appearance = appearance
        persist()
    }

    // MARK: Stream languages

    var preferredStreamLanguages: Set<String> { prefs.preferredStreamLanguages }

    func isStreamLanguageSelected(_ language: StreamLanguage) -> Bool {
        prefs.preferredStreamLanguages.contains(language.code)
    }

    func toggleStreamLanguage(_ language: StreamLanguage) {
        if prefs.preferredStreamLanguages.contains(language.code) {
            prefs.preferredStreamLanguages.remove(language.code)
        } else {
            prefs.preferredStreamLanguages.insert(language.code)
        }
        persist()
    }

    func setDefaultStreamLanguage(_ language: StreamLanguage) {
        prefs.preferredStreamLanguages = [language.code]
        persist()
    }

    // MARK: Spoiler-Free Mode

    var spoilerFreeMode: Bool { prefs.spoilerFreeMode }

    func setSpoilerFreeMode(_ enabled: Bool) {
        prefs.spoilerFreeMode = enabled
        persist()
    }

    // MARK: Live Score Badge

    var showLiveScoreBadge: Bool { prefs.showLiveScoreBadge }

    func setShowLiveScoreBadge(_ enabled: Bool) {
        prefs.showLiveScoreBadge = enabled
        persist()
    }

    // MARK: Live Score Bar

    var showLiveScoreBar: Bool { prefs.showLiveScoreBar }

    func setShowLiveScoreBar(_ enabled: Bool) {
        prefs.showLiveScoreBar = enabled
        persist()
    }

    // MARK: Live TV display preferences

    var showChannelNumbers: Bool { prefs.showChannelNumbers }
    func setShowChannelNumbers(_ v: Bool) { prefs.showChannelNumbers = v; persist() }

    var guideProgrammeTitleLines: Int { prefs.guideProgrammeTitleLines }
    func setGuideProgrammeTitleLines(_ v: Int) { prefs.guideProgrammeTitleLines = max(1, min(2, v)); persist() }

    var epgHighlightCurrentProgramme: Bool { prefs.epgHighlightCurrentProgramme }
    func setEPGHighlightCurrentProgramme(_ v: Bool) { prefs.epgHighlightCurrentProgramme = v; persist() }

    var playerPanelTimeoutSeconds: Int { prefs.playerPanelTimeoutSeconds }
    func setPlayerPanelTimeoutSeconds(_ v: Int) { prefs.playerPanelTimeoutSeconds = max(2, min(30, v)); persist() }

    var guideTimeScaleMinutes: Int { prefs.guideTimeScaleMinutes }
    func setGuideTimeScaleMinutes(_ v: Int) { prefs.guideTimeScaleMinutes = v; persist() }

    var playerBarActions: [String] { prefs.playerBarActions }
    var playerActionConfiguration: PlayerActionConfiguration {
        PlayerActionConfiguration(rawIDs: prefs.playerBarActions)
    }
    func setPlayerBarActions(_ ids: [String]) { prefs.playerBarActions = ids; persist() }

    // MARK: Leagues

    /// The leagues the user explicitly follows, in the catalog's canonical order.
    var explicitlyFollowedLeagues: [League] {
        League.all.filter { prefs.selectedLeagueIDs.contains($0.path) }
    }

    /// The leagues the user follows, in the catalog's canonical order.
    /// Falls back to the full catalog when nothing has been chosen yet.
    var followedLeagues: [League] {
        let selected = explicitlyFollowedLeagues
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
